import { spawn } from "child_process";
import { existsSync, mkdirSync, renameSync, rmSync, statSync, writeFileSync } from "fs";
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
 * Stereo companions keep tiddl's plain file name (they are the copy a library
 * scanner should treat as the track), while the Atmos file tiddl downloaded is
 * renamed with an ` (Atmos)` suffix before the extension. Both presentations
 * are therefore recognisable and can never collide — the only case that would
 * need a marker on the stereo copy is a library with further presentations
 * (5.1, 7.1), which Tidal does not expose here.
 */

const STEREO_SUFFIX = " (Stereo)";
const ATMOS_SUFFIX = " (Atmos)";

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

  if (!response.ok) return null;

  return (await response.json()) as TrackStreamJson;
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

function existingAudioFile(base: string): string | undefined {
  return [`${base}.flac`, `${base}.m4a`, `${base}${ATMOS_SUFFIX}.m4a`].find(
    existsSync,
  );
}

/**
 * Marks the file tiddl downloaded as the Atmos one, so both presentations are
 * recognisable in the library (`... (Atmos).m4a` / `... (Stereo).flac`).
 */
function markAtmosFile(base: string, itemId: string, title: string): void {
  const source = `${base}.m4a`;
  const target = `${base}${ATMOS_SUFFIX}.m4a`;

  if (!existsSync(source)) return;

  if (existsSync(target)) {
    // A previous run already marked the file: tiddl downloaded the same track
    // again because it looks for the unmarked name. Same size = same stream.
    try {
      if (statSync(source).size === statSync(target).size) {
        rmSync(source, { force: true });
        logs(itemId, `✅ [ATMOS] ${title}: duplicate Atmos file removed`);
      } else {
        logs(
          itemId,
          `⚠️ [ATMOS] ${title}: ${ATMOS_SUFFIX} file exists and differs, both kept`,
        );
      }
    } catch {
      // Leave the file alone when it cannot be inspected
    }
    return;
  }

  try {
    renameSync(source, target);
    logs(itemId, `✅ [ATMOS] ${title}: Atmos file marked${ATMOS_SUFFIX}`);
  } catch (error) {
    logs(
      itemId,
      `⚠️ [ATMOS] ${title}: cannot rename Atmos file: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
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

function parseItemUrl(url?: string): { type: string; id: string } | null {
  const match = url?.match(/\/(album|track)\/(\d+)/);
  return match ? { type: match[1], id: match[2] } : null;
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

async function resolveAlbumAndTracks(
  parsed: { type: string; id: string },
  countryCode: string,
): Promise<{ album: AlbumJson; tracks: TrackJson[] }> {
  if (parsed.type === "track") {
    const trackResponse = await fetchTidalWithRefresh(
      `${TIDAL_API_URL}/v1/tracks/${parsed.id}?countryCode=${countryCode}`,
    );
    if (!trackResponse.ok) {
      throw new Error(`track ${parsed.id}: HTTP ${trackResponse.status}`);
    }

    const track = (await trackResponse.json()) as TrackJson & {
      album?: { id: number };
    };
    const albumId = track.album?.id;
    if (!albumId) throw new Error(`track ${parsed.id} has no album`);

    const albumResponse = await fetchTidalWithRefresh(
      `${TIDAL_API_URL}/v1/albums/${albumId}?countryCode=${countryCode}`,
    );
    if (!albumResponse.ok) {
      throw new Error(`album ${albumId}: HTTP ${albumResponse.status}`);
    }

    return { album: (await albumResponse.json()) as AlbumJson, tracks: [track] };
  }

  const albumResponse = await fetchTidalWithRefresh(
    `${TIDAL_API_URL}/v1/albums/${parsed.id}?countryCode=${countryCode}`,
  );
  if (!albumResponse.ok) {
    throw new Error(`album ${parsed.id}: HTTP ${albumResponse.status}`);
  }

  return {
    album: (await albumResponse.json()) as AlbumJson,
    tracks: await getAlbumTracks(parsed.id, countryCode),
  };
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

  if (parsed.type !== "album" && parsed.type !== "track") {
    logs(item.id, `ℹ️ [ATMOS] Stereo companion skipped for "${item.url}"`);
    return;
  }

  const { config } = get_tiddl_config();
  const countryCode = config?.auth?.country_code || "US";
  const quality = QUALITY_MAP[item.quality ?? "max"] ?? QUALITY_MAP.max;

  const { album, tracks } = await resolveAlbumAndTracks(parsed, countryCode);
  const atmosTracks = tracks.filter(hasAtmos);
  if (atmosTracks.length === 0) return;

  const year = (album.releaseDate ?? "").slice(0, 4);
  const albumDirectory = join(
    PROCESSING_PATH,
    String(item.id),
    cleanSegment(album.artist?.name ?? ""),
    cleanSegment(`${year} - ${album.title}`),
  );

  logs(
    item.id,
    `ℹ️ [ATMOS] ${atmosTracks.length}/${tracks.length} track(s) have a Dolby Atmos version`,
  );

  let added = 0;

  for (const track of atmosTracks) {
    const base = join(albumDirectory, trackSegment(track));

    try {
      // tiddl saved the Atmos stream under the regular track name; mark it so
      // the two presentations are distinguishable in the library
      markAtmosFile(base, item.id, track.title);

      const stereo = await getTrackStream(track.id, quality, false);

      if (stereo?.audioMode === "STEREO") {
        const { urls, codecs } = parseManifest(stereo);
        const extension = extensionFor(stereo, codecs);
        // The stereo copy keeps the plain track name: it is the one a library
        // scanner should treat as the track, the Atmos file carries the marker
        const file = `${base}${extension}`;

        if (existsSync(file)) {
          logs(item.id, `✅ [ATMOS] ${track.title}: stereo already present`);
          continue;
        }

        // Files written by 1.1.6 and older had a ` (Stereo)` suffix
        const legacy = `${base}${STEREO_SUFFIX}${extension}`;
        if (existsSync(legacy)) {
          renameSync(legacy, file);
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

      const existing = existingAudioFile(base);
      if (existing) {
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
      const file = `${base}${ATMOS_SUFFIX}${extension}`;
      await writeAudioFile(file, buffer, trackTags(track, album));

      added += 1;
      logs(
        item.id,
        `✅ [ATMOS] ${track.title}: no stereo version, kept Dolby Atmos (${extension}, ${atmos.audioQuality ?? "?"})`,
      );
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      logs(item.id, `⚠️ [ATMOS] ${track.title}: ${message}`);
    }
  }

  if (added > 0) {
    logs(item.id, `✅ [ATMOS] ${added} file(s) added`);
  }
}
