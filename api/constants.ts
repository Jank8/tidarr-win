import { join } from "path";

// On Windows (native), use paths relative to the project root.
// On Linux/Docker, use the original /tidarr and /shared layout.
export const IS_WINDOWS = process.platform === "win32";

// Root of the tidarr project (one level up from /api)
export const ROOT_PATH = IS_WINDOWS
  ? join(__dirname, "..")
  : "/tidarr";

// Shared config/data folder — mirrors the Docker /shared volume on Windows
export const CONFIG_PATH = IS_WINDOWS
  ? join(ROOT_PATH, "userfiles", "shared")
  : "/shared";

// Music library folder
export const MUSIC_PATH = IS_WINDOWS
  ? join(ROOT_PATH, "userfiles", "music")
  : "/music";

export const PROCESSING_PATH = join(CONFIG_PATH, ".processing");
export const NZB_DOWNLOAD_PATH = join(CONFIG_PATH, "nzb_downloads");

export const TIDAL_API_URL = "https://api.tidal.com";
export const SYNC_DEFAULT_CRON = "0 3 * * *";
