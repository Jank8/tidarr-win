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

- Web UI: `3000`
- API: `8484`

Both must be free; if a previous instance is still running, close its console
window first.

## Cleanup and uninstall

```
cleanup.cmd     → removes generated state, keeps dependencies
uninstall.cmd   → removes Node.js, Python, tiddl, ffmpeg (music is kept)
```

## Notes

- Run from a folder where your user has write permissions — `C:\tidarr`, not a
  protected location such as `C:\Program Files`
- tiddl stores auth tokens in `userfiles\shared\.tiddl\`
- The download path can be changed in Settings → Config
- `userfiles\` is gitignored, so your credentials and music are never committed

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
