import { join } from "path";

// Native Windows layout: everything lives inside the project folder.
export const ROOT_PATH = join(__dirname, "..");

// Config, auth tokens and queue
export const CONFIG_PATH = join(ROOT_PATH, "userfiles", "shared");

// Music library folder
export const MUSIC_PATH = join(ROOT_PATH, "userfiles", "music");

export const PROCESSING_PATH = join(CONFIG_PATH, ".processing");
export const NZB_DOWNLOAD_PATH = join(CONFIG_PATH, "nzb_downloads");

export const TIDAL_API_URL = "https://api.tidal.com";
export const SYNC_DEFAULT_CRON = "0 3 * * *";
