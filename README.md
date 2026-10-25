# Tidarr for Windows

A Windows-native fork of [tidarr](https://github.com/cstaelen/tidarr) — a web interface for downloading media from Tidal using [tiddl](https://github.com/oskvr37/tiddl).

It runs directly on Windows: no Docker, no container, no prebuilt release. You
download the code, run `start.cmd`, and the launcher sets everything up.

## Requirements

Nothing to install by hand — the launcher checks and installs what is missing:

- [Node.js](https://nodejs.org) (LTS)
- [pnpm](https://pnpm.io) 10
- [tiddl](https://github.com/oskvr37/tiddl) — always the latest release from
  PyPI (currently 3.4.4), plus the Python version that release requires
  (currently Python 3.13+)
- [ffmpeg](https://ffmpeg.org)

At every start the launcher asks PyPI for the current tiddl release, reads the
Python requirement published with it and installs both if needed. If PyPI cannot
be reached, it falls back to a known-good version and keeps working offline.
Set `TIDARR_TIDDL_VERSION` to pin a specific tiddl version.

An internet connection is required on the first run.

## Install

Pick a folder you can write to — `C:\tidarr` works best:

```
git clone -b windows https://github.com/Jank8/tidarr-win.git C:\tidarr
cd C:\tidarr
start.cmd
```

No git? Download the repository ZIP from GitHub (Code → Download ZIP), unpack
it to `C:\tidarr` and run `start.cmd`.

On the first run the launcher installs the dependencies and starts Tidarr
(`http://localhost:3000`). You will then be asked to authorize your Tidal
account.

## Updating

```
git pull
start.cmd
```

The launcher keeps `userfiles\` and only updates the application code. If you
downloaded a ZIP instead, unpack the new version over the old folder — do not
delete `userfiles\`.

## Folder Structure

```
tidarr-win\
  userfiles\
    shared\    ← config, auth tokens, queue, processing
    music\     ← downloaded music (set in Settings)
```

## Ports

- Web UI: `http://localhost:3000`
- API: `http://127.0.0.1:8484`

Both are bound to loopback only — the API has no authentication unless you set
`ADMIN_PASSWORD` in `.env`, so exposing it would hand your Tidal token to the
whole network. To allow another machine (e.g. Lidarr) to reach Tidarr, set
`HOST=0.0.0.0` in `.env` and restart.

The launcher checks both ports before starting: a leftover Tidarr instance from
this folder is stopped automatically, anything else is reported with its PID.

Press **Ctrl+C** in the launcher window to stop Tidarr: the UI, the API and the
background workers are closed and both ports are released.

## Cleanup and uninstall

```
cleanup.cmd     → resets the app to a clean state
                  [1] quick: config, Tidal token, queue, processing, build output
                      (keeps node_modules and tools → fast restart)
                  [2] full:  also node_modules and tools\rsgain
                  music files are never touched
uninstall.cmd   → removes the dependencies
                  Node.js, Python, tiddl + beets, ffmpeg, pnpm/tsx, rsgain,
                  tools\ folder and the PATH entries it added
```

## Custom scripts

Post-processing hooks live in `userfiles\shared\` and run with the matching
native shell:

| file | runtime |
|---|---|
| `custom-script.ps1` / `custom-post-script.ps1` | PowerShell |
| `custom-script.cmd` / `.bat` | cmd.exe |
| `custom-script.sh` / `custom-post-script.sh` | `sh` from Git for Windows |

Put the most specific one there — PowerShell wins over `.cmd`, `.cmd` over
`.sh`. If none exists, the hook is simply skipped.

## Notes

- Run from a folder where your user has write permissions — `C:\tidarr`, not a
  protected location such as `C:\Program Files`
- tiddl stores auth tokens in `userfiles\shared\.tiddl\`
- The download path can be changed in Settings → Config
- `userfiles\` is gitignored, so your credentials and music are never committed

## Dolby Atmos

Tidal serves one presentation per request — stereo or Atmos — so Tidarr fills in
the other one after tiddl finishes. The button in the header picks the mode
(`atmos_filter` in `userfiles\shared\.tiddl\config.toml`):

| mode | what lands in the library |
|---|---|
| **No Atmos** | stereo `.flac` only; tracks Tidal has as Atmos get their stereo downmix, and if no stereo version exists the Atmos `.m4a` is kept instead of skipping the track |
| **Atmos only** | `.m4a` (eac3) only |
| **Atmos allowed** | both — `… (Atmos).m4a` and `… (Stereo).flac` next to it |

Stereo companions are written by Tidarr (tags added with ffmpeg) under tiddl's
naming with a ` (Stereo)` suffix, and the Atmos file tiddl downloaded is renamed
with an ` (Atmos)` suffix. Media servers will list both files as two tracks of
the album.

## Optional features

Two features need an external tool. Turn the flag on in `.env` and run
`start.cmd` again — the launcher installs the tool itself, no manual setup:

| flag in `.env` | tool | what it does |
|---|---|---|
| `ENABLE_BEETS=true` | beets (+ fetchart, lastgenre, lastimport, advancedrewrite plugins) | tags and renames downloads using `userfiles\shared\beets-config.yml` |
| `REPLAY_GAIN=true` | rsgain | writes ReplayGain tags into the downloaded files |

beets is installed with pip into the same Python as tiddl; rsgain is a portable
build downloaded into `tools\rsgain` and added to PATH. Nothing is installed
while the flag is off, so a default install stays small.

## Troubleshooting

**`ERROR: No matching distribution found for tiddl==…`**

The tiddl release selected by the launcher requires a newer Python than the one
`python` on your PATH provides. The launcher resolves the interpreter by version
(reads `requires_python` from PyPI), installs a matching Python alongside the
existing one and runs the tiddl install with that interpreter — no uninstall
required. If it still fails, install Python manually from
https://www.python.org/downloads/ and run `start.cmd` again.

**The page opens but shows "Tidarr API is not reachable"**

The API did not start. Check the launcher console window for the error, and make
sure ports 3000 and 8484 are not used by another program.

## Original Project

https://github.com/cstaelen/tidarr
