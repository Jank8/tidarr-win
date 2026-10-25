import { basename, join } from "path";

// Native Windows layout: everything lives inside the project folder.
// In development this file runs from api/ (tsx), in production from
// api/dist/ (compiled), so the project root is one or two levels up.
const moduleDirectory = __dirname;
export const ROOT_PATH =
  basename(moduleDirectory) === "dist"
    ? join(moduleDirectory, "..", "..")
    : join(moduleDirectory, "..");

// Config, auth tokens and queue
export const CONFIG_PATH = join(ROOT_PATH, "userfiles", "shared");

// Music library folder
export const MUSIC_PATH = join(ROOT_PATH, "userfiles", "music");

export const PROCESSING_PATH = join(CONFIG_PATH, ".processing");
export const NZB_DOWNLOAD_PATH = join(CONFIG_PATH, "nzb_downloads");

export const TIDAL_API_URL = "https://api.tidal.com";
export const SYNC_DEFAULT_CRON = "0 3 * * *";
