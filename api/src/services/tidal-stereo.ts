import { spawn } from "child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "fs";
import { basename, dirname, join } from "path";

import { PROCESSING_PATH, TIDAL_API_URL } from "../../constants";
import {
  fetchAllTidalPages,
  fetchTidalWithRefresh,
} from "../helpers/fetch-tidal";
import { get_tiddl_config } from "../helpers/get_tiddl_config";
import { ProcessingItemType } from "../types";
import { logs } from "../processing/utils/logs";

/**
 * Dolby Atmos and stereo are two presentations of the same Tidal track, and a
 * playback request only returns one of them. tiddl always asks without the
 * `immersiveaudio` flag, so Tidal answers with the Atmos stream when the track
 * has one, and tiddl can only skip it (`none`) or download it (`allow`/`only`).
 *
 * This service adds the missing half of the pair, so the three filters in the
 * UI behave as advertised:
 *
 * - `none`  – tiddl downloads the stereo tracks and skips the Atmos ones; the
 *             stereo downmix of those is fetched here. When Tidal has no stereo
 *             version at all, the Atmos file is kept instead of losing the
 *             track (better eac3 than nothing).
 * - `allow` – tiddl downloads the Atmos tracks, their stereo FLAC is fetched
 *             here, so both files end up side by side.
 * - `only`  – nothing to do, stereo is not wanted.
 *
 * Albums, single tracks and playlists (including mixes, which are downloaded as
 * a temporary playlist) are supported. The Atmos file keeps tiddl's plain name,
 * so tiddl's `skip_existing` still recognises it on a re-download, while the
 * stereo companion gets a ` (Stereo)` suffix before the extension. Both files
 * are therefore distinguishable and can never collide.
 */

const STEREO_SUFFIX = " (Stereo)";
const ATMOS_SUFFIX = " (Atmos)";

// Small pause between tracks so a long playlist does not burst the API
const COMPANION_DELAY_MS = 250;

const QUALITY_MAP: Record<string, string> = {
  low: "LOW",
  normal: "HIGH",
  high: "LOSSLESS",
  max: "HI_RES_LOSSLESS",
};

type AlbumJson = {
  id: number;
  title: string;
  releaseDate?: string;
  artist?: { name?: string };
};

type TrackJson = {
  id: number;
  title: string;
  version?: string | null;
  trackNumber?: number;
  artist?: { name?: string };
  album?: { id?: number };
  audioModes?: string[];
  // Tidal returns a single tag or a list, depending on the endpoint
  mediaMetadata?: { tags?: string | string[] };
};

type TrackStreamJson = {
  audioMode?: string;
  audioQuality?: string;
  manifestMimeType?: string;
  manifest?: string;
};

type AlbumEntry = { track: TrackJson; album: AlbumJson };

/** Path segment cleanup, mirroring tiddl's `_clean_segment`. */
function cleanSegment(text: string): string {
  const cleaned = text
    .replace(/[\\/:"*?<>|]+/g, "")
    .replace(/\.{2,}/g, ".")
    .replace(/[ .]+$/, "")
    .replace(/\s{2,}/g, " ")
    .trim();

  return cleaned || "_";
}

/** `{item.number:02d}. {item.artist} - {item.title_version}` from tiddl's template. */
function trackSegment(track: TrackJson): string {
  const number = String(track.trackNumber ?? 0).padStart(2, "0");
  const artist = track.artist?.name ?? "";
  const title = track.version
    ? `${track.title} (${track.version})`
    : track.title;

  return cleanSegment(`${number}. ${artist} - ${title}`);
}

function albumDirectory(itemId: string, album: AlbumJson): string {
  const year = (album.releaseDate ?? "").slice(0, 4);

  return join(
    PROCESSING_PATH,
    String(itemId),
    cleanSegment(album.artist?.name ?? ""),
    cleanSegment(`${year} - ${album.title}`),
  );
}

function hasAtmos(track: TrackJson): boolean {
  const tags = track.mediaMetadata?.tags;
  const tagText = Array.isArray(tags) ? tags.join(",") : (tags ?? "");

  return (
    tagText.includes("DOLBY_ATMOS") ||
    (track.audioModes ?? []).includes("DOLBY_ATMOS")
  );
}

function extensionFor(stream: TrackStreamJson, codecs: string): string {
  if (codecs === "flac") {
    // Hi-Res FLAC is delivered as FLAC inside an MP4 container
    return stream.audioQuality === "HI_RES_LOSSLESS" ? ".m4a" : ".flac";
  }
  return ".m4a";
}

/** Segment list from the stream manifest (`application/vnd.tidal.bts` or DASH). */
function parseManifest(stream: TrackStreamJson): {
  urls: string[];
  codecs: string;
} {
  const decoded = Buffer.from(stream.manifest ?? "", "base64").toString("utf-8");

  if (stream.manifestMimeType === "application/dash+xml") {
    const media = decoded.match(/<SegmentTemplate[^>]*\bmedia="([^"]+)"/)?.[1];
    if (!media) throw new Error("DASH manifest without media template");

    let total = 0;
    for (const element of decoded.match(/<S\b[^>]*\/>/g) ?? []) {
      total += 1;
      const repeat = element.match(/\br="(\d+)"/)?.[1];
      if (repeat) total += parseInt(repeat, 10);
    }

    const codecs =
      decoded.match(/<Representation[^>]*\bcodecs="([^"]*)"/)?.[1] ?? "";
    return {
      urls: Array.from({ length: total + 1 }, (_, index) =>
        media.replace("$Number$", String(index)),
      ),
      codecs,
    };
  }

  const manifest = JSON.parse(decoded) as { urls?: string[]; codecs?: string };
  return { urls: manifest.urls ?? [], codecs: manifest.codecs ?? "" };
}

async function downloadUrls(urls: string[]): Promise<Buffer> {
  if (urls.length === 0) throw new Error("empty stream manifest");

  const chunks: Buffer[] = [];
  for (const url of urls) {
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`segment download failed (${response.status})`);
    }
    chunks.push(Buffer.from(await response.arrayBuffer()));
  }

  return Buffer.concat(chunks);
}

async function getTrackStream(
  trackId: number,
  quality: string,
  immersive: boolean,
): Promise<TrackStreamJson | null> {
  const response = await fetchTidalWithRefresh(
    `${TIDAL_API_URL}/v1/tracks/${trackId}/playbackinfopostpaywall` +
      `?audioquality=${quality}&playbackmode=STREAM&assetpresentation=FULL` +
      `&immersiveaudio=${immersive ? "true" : "false"}`,
  );

  // Stop the pass instead of adding more requests to an exhausted quota
  if (response.status === 429) throw new RateLimitError();

  if (!response.ok) return null;

  return (await response.json()) as TrackStreamJson;
}

/** Tidal answered 429 — the whole pass has to stop, not just this track. */
class RateLimitError extends Error {
  constructor() {
    super("Tidal rate limit (429)");
    this.name = "RateLimitError";
  }
}

/** Writes basic tags with ffmpeg; a failure leaves the untagged file in place. */
function writeTags(file: string, tags: Record<string, string>): Promise<void> {
  return new Promise((resolve) => {
    const temp = `${file}.tagged${file.slice(file.lastIndexOf("."))}`;
    const args = ["-y", "-loglevel", "error", "-i", file, "-c", "copy"];

    for (const [key, value] of Object.entries(tags)) {
      if (!value) continue;
      args.push("-metadata", `${key}=${value}`);
    }

    args.push(temp);

    const child = spawn("ffmpeg", args, { stdio: "ignore" });

    child.on("error", () => resolve());
    child.on("close", (code) => {
      if (code === 0 && existsSync(temp)) {
        try {
          renameSync(temp, file);
        } catch {
          rmSync(temp, { force: true });
        }
      } else {
        rmSync(temp, { force: true });
      }
      resolve();
    });
  });
}

async function writeAudioFile(
  file: string,
  buffer: Buffer,
  tags: Record<string, string>,
): Promise<void> {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, buffer);
  await writeTags(file, tags);
}

function listFiles(directory: string): string[] {
  if (!existsSync(directory)) return [];

  const files: string[] = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...listFiles(full));
    } else {
      files.push(full);
    }
  }

  return files;
}

/**
 * Finds the file tiddl wrote for a track. The expected path is derived from the
 * default template, but a custom template can place it elsewhere — then the
 * processing folder is scanned for the same file name.
 */
function findTiddlFile(
  expected: string,
  itemId: string,
  suffix = "",
): string | undefined {
  if (existsSync(expected)) return expected;

  const name = `${basename(expected)}${suffix}`;
  const directory = join(PROCESSING_PATH, String(itemId));

  return listFiles(directory).find((file) => basename(file) === name);
}

/**
 * Locates the file tiddl downloaded for a track. The Atmos file keeps tiddl's
 * plain name — that is what makes `skip_existing` work on a re-download — and
 * the stereo companion is written next to it, even when a custom template put
 * the files somewhere else.
 */
function findAtmosFile(base: string, itemId: string): string | undefined {
  return findTiddlFile(`${base}.m4a`, itemId);
}

function trackTags(track: TrackJson, album: AlbumJson): Record<string, string> {
  return {
    title: track.version ? `${track.title} (${track.version})` : track.title,
    artist: track.artist?.name ?? "",
    album: album.title,
    album_artist: album.artist?.name ?? "",
    track: String(track.trackNumber ?? ""),
    date: (album.releaseDate ?? "").slice(0, 4),
  };
}

function parseItemUrl(
  url?: string,
): { type: "album" | "track" | "playlist"; id: string } | null {
  const albumOrTrack = url?.match(/\/(album|track)\/(\d+)/);
  if (albumOrTrack) {
    return {
      type: albumOrTrack[1] as "album" | "track",
      id: albumOrTrack[2],
    };
  }

  const playlist = url?.match(/\/playlist\/([\w-]{8,})/);
  if (playlist) return { type: "playlist", id: playlist[1] };

  return null;
}

async function getAlbum(
  albumId: string | number,
  countryCode: string,
): Promise<AlbumJson | null> {
  const response = await fetchTidalWithRefresh(
    `${TIDAL_API_URL}/v1/albums/${albumId}?countryCode=${countryCode}`,
  );

  if (!response.ok) return null;

  return (await response.json()) as AlbumJson;
}

async function getAlbumTracks(
  albumId: string,
  countryCode: string,
): Promise<TrackJson[]> {
  const pages = await fetchAllTidalPages<{ item?: TrackJson }>(
    `${TIDAL_API_URL}/v1/albums/${albumId}/items?countryCode=${countryCode}`,
    "album items",
  );

  return pages
    .map((entry) => entry.item)
    .filter((track): track is TrackJson => Boolean(track?.id));
}

async function getPlaylistTracks(
  playlistId: string,
  countryCode: string,
): Promise<TrackJson[]> {
  const pages = await fetchAllTidalPages<{ item?: TrackJson }>(
    `${TIDAL_API_URL}/v1/playlists/${playlistId}/items?countryCode=${countryCode}`,
    "playlist items",
  );

  return pages
    .map((entry) => entry.item)
    .filter((track): track is TrackJson => Boolean(track?.id));
}

/** Every track of the item together with the album it belongs to. */
async function resolveEntries(
  parsed: { type: "album" | "track" | "playlist"; id: string },
  countryCode: string,
): Promise<AlbumEntry[]> {
  if (parsed.type === "track") {
    const trackResponse = await fetchTidalWithRefresh(
      `${TIDAL_API_URL}/v1/tracks/${parsed.id}?countryCode=${countryCode}`,
    );
    if (!trackResponse.ok) {
      throw new Error(`track ${parsed.id}: HTTP ${trackResponse.status}`);
    }

    const track = (await trackResponse.json()) as TrackJson;
    const albumId = track.album?.id;
    if (!albumId) throw new Error(`track ${parsed.id} has no album`);

    const album = await getAlbum(albumId, countryCode);
    if (!album) throw new Error(`album ${albumId}: not found`);

    return [{ track, album }];
  }

  if (parsed.type === "album") {
    const album = await getAlbum(parsed.id, countryCode);
    if (!album) throw new Error(`album ${parsed.id}: not found`);

    const tracks = await getAlbumTracks(parsed.id, countryCode);
    return tracks.map((track) => ({ track, album }));
  }

  // Playlist / mix: every track can come from a different album
  const tracks = await getPlaylistTracks(parsed.id, countryCode);
  const albums = new Map<number, AlbumJson | null>();
  const entries: AlbumEntry[] = [];

  for (const track of tracks) {
    const albumId = track.album?.id;
    if (!albumId) continue;

    if (!albums.has(albumId)) {
      albums.set(albumId, await getAlbum(albumId, countryCode));
    }

    const album = albums.get(albumId);
    if (album) entries.push({ track, album });
  }

  return entries;
}

/**
 * Adds the stereo version of every Atmos track of the item, when Tidal has one.
 * With the `none` filter the Atmos file is kept for tracks that have no stereo
 * version at all, so a download never ends up empty.
 *
 * Runs inside post-processing, so the files are moved to the library together
 * with the ones tiddl downloaded.
 */
export async function ensureStereoCompanions(
  item: ProcessingItemType,
): Promise<void> {
  const filter = item.atmosFilter ?? "allow";
  if (filter === "only") return;

  const parsed = parseItemUrl(item.url);
  if (!parsed) return;

  const { config } = get_tiddl_config();
  const countryCode = config?.auth?.country_code || "US";
  const quality = QUALITY_MAP[item.quality ?? "max"] ?? QUALITY_MAP.max;

  const entries = await resolveEntries(parsed, countryCode);
  const atmosEntries = entries.filter(({ track }) => hasAtmos(track));
  if (atmosEntries.length === 0) return;

  logs(
    item.id,
    `ℹ️ [ATMOS] ${atmosEntries.length}/${entries.length} track(s) have a Dolby Atmos version`,
  );

  let added = 0;

  for (const [index, { track, album }] of atmosEntries.entries()) {
    if (index > 0) {
      await new Promise((resolve) => setTimeout(resolve, COMPANION_DELAY_MS));
    }

    const base = join(albumDirectory(item.id, album), trackSegment(track));

    try {
      // Where tiddl actually put the Atmos file (custom templates may move it)
      const atmosFile = findAtmosFile(base, item.id);
      const fileBase = atmosFile
        ? join(dirname(atmosFile), basename(atmosFile).replace(/\.m4a$/i, ""))
        : base;

      const stereo = await getTrackStream(track.id, quality, false);

      if (stereo?.audioMode === "STEREO") {
        const { urls, codecs } = parseManifest(stereo);
        const extension = extensionFor(stereo, codecs);
        const file = `${fileBase}${STEREO_SUFFIX}${extension}`;

        if (existsSync(file)) {
          logs(item.id, `✅ [ATMOS] ${track.title}: stereo already present`);
          continue;
        }

        // Companion written by 1.1.7/1.1.8 with the plain name
        const plain = `${fileBase}${extension}`;
        if (existsSync(plain)) {
          renameSync(plain, file);
          logs(
            item.id,
            `✅ [ATMOS] ${track.title}: stereo file renamed to "${basename(file)}"`,
          );
          continue;
        }

        const buffer = await downloadUrls(urls);
        await writeAudioFile(file, buffer, trackTags(track, album));
        added += 1;
        logs(
          item.id,
          `✅ [ATMOS] ${track.title}: stereo companion saved (${extension}, ${stereo.audioQuality ?? "?"})`,
        );
        continue;
      }

      // No stereo version exists for this track
      if (filter !== "none") {
        logs(item.id, `⚠️ [ATMOS] ${track.title}: no stereo version available`);
        continue;
      }

      if (
        existsSync(`${fileBase}.flac`) ||
        existsSync(`${fileBase}.m4a`) ||
        Boolean(findTiddlFile(`${fileBase}${ATMOS_SUFFIX}.m4a`, item.id))
      ) {
        logs(item.id, `✅ [ATMOS] ${track.title}: already downloaded`);
        continue;
      }

      const atmos = await getTrackStream(track.id, quality, true);
      if (!atmos) {
        logs(item.id, `⚠️ [ATMOS] ${track.title}: no playable stream`);
        continue;
      }

      const { urls, codecs } = parseManifest(atmos);
      const buffer = await downloadUrls(urls);
      const extension = extensionFor(atmos, codecs);
      const file = `${fileBase}${extension}`;
      await writeAudioFile(file, buffer, trackTags(track, album));

      added += 1;
      logs(
        item.id,
        `✅ [ATMOS] ${track.title}: no stereo version, kept Dolby Atmos (${extension}, ${atmos.audioQuality ?? "?"})`,
      );
    } catch (error) {
      if (error instanceof RateLimitError) {
        logs(
          item.id,
          "⏳ [ATMOS] Tidal rate limit (429) reached — stopping the stereo pass. Re-run the item later to fetch the remaining companions.",
        );
        break;
      }

      const message = error instanceof Error ? error.message : String(error);
      logs(item.id, `⚠️ [ATMOS] ${track.title}: ${message}`);
    }
  }

  if (added > 0) {
    logs(item.id, `✅ [ATMOS] ${added} file(s) added`);
  }
}
