import { ChildProcess, exec } from "child_process";
import fs from "fs";
import path from "path";
import { promisify } from "util";

const execAsync = promisify(exec);

import { NZB_DOWNLOAD_PATH, PROCESSING_PATH } from "../../../constants";
import { getAppInstance } from "../../helpers/app-instance";
import { ProcessingItemType } from "../../types";

import { logs } from "./logs";

// ─── cross-platform helpers ───────────────────────────────────────────────────

/** Recursively copy a directory (replaces `cp -rf src/* dest`). */
function copyDirRecursive(src: string, dest: string): void {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDirRecursive(srcPath, destPath);
    } else {
      fs.copyFileSync(srcPath, destPath);
    }
  }
}

/** Recursively delete a path (replaces `rm -rf`). */
function removeRecursive(targetPath: string): void {
  fs.rmSync(targetPath, { recursive: true, force: true });
}

/** Recursively list all files under a directory (replaces `find dir -type f`). */
function findFilesRecursive(dir: string): string[] {
  const results: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...findFilesRecursive(full));
    } else {
      results.push(full);
    }
  }
  return results;
}

// ─── exported functions ───────────────────────────────────────────────────────

export async function moveAndClean(id: string): Promise<{
  status: "finished" | "error" | undefined;
}> {
  const app = getAppInstance();
  const item: ProcessingItemType =
    app.locals.processingStack.actions.getItem(id);
  let status: "finished" | "error" | undefined;

  if (!item) return { status: "finished" };

  const itemProcessingPath = path.join(PROCESSING_PATH, String(item.id));
  const libraryPath = app.locals.tiddlConfig.download.download_path;

  try {
    logs(item.id, "🕖 [TIDARR] Move processed items ...");

    if (!(await hasFileToMove(itemProcessingPath))) {
      logs(item.id, "⚠️ [TIDARR] No files to move (empty download folder)");
      return { status: "finished" };
    }

    // Copy every entry from the processing dir into the library
    for (const entry of fs.readdirSync(itemProcessingPath, { withFileTypes: true })) {
      const src = path.join(itemProcessingPath, entry.name);
      const dest = path.join(libraryPath, entry.name);
      if (entry.isDirectory()) {
        copyDirRecursive(src, dest);
      } else {
        fs.mkdirSync(libraryPath, { recursive: true });
        fs.copyFileSync(src, dest);
      }
    }

    logs(item.id, `✅ [TIDARR] Move complete (${item.type})`);
    status = "finished";
  } catch (e: unknown) {
    status = "error";
    logs(item.id, `❌ [TIDARR] Error moving files:\r\n${(e as Error).message}`);
  } finally {
    const cleaningStatus = await cleanFolder(item.id);
    if (cleaningStatus === "error") {
      status = "error";
    }
  }

  return { status };
}

export async function cleanFolder(
  itemId?: string,
): Promise<"finished" | "error"> {
  const app = getAppInstance();
  const item: ProcessingItemType | undefined =
    itemId ? app.locals.processingStack.actions.getItem(itemId) : undefined;

  let processingPath = PROCESSING_PATH;
  if (itemId && item && item.source === "lidarr") {
    processingPath = NZB_DOWNLOAD_PATH;
  }

  try {
    if (itemId) {
      const targetPath = path.join(processingPath, String(itemId));
      if (fs.existsSync(targetPath)) {
        removeRecursive(targetPath);
      }
    } else {
      // Wipe all entries inside the processing folder without removing the folder itself
      if (fs.existsSync(processingPath)) {
        for (const entry of fs.readdirSync(processingPath)) {
          removeRecursive(path.join(processingPath, entry));
        }
      }
    }
    console.log(
      `🧹 [TIDARR] Cleaned up processing folder${itemId ? ` (item: ${itemId})` : ""}`,
    );
    return "finished";
  } catch (e) {
    console.log(`❌ [TIDARR] Error cleaning folder:`, e);
    return "error";
  }
}

export async function hasFileToMove(pathArg?: string): Promise<boolean> {
  const targetPath = pathArg || PROCESSING_PATH;

  if (!fs.existsSync(targetPath)) {
    console.log(`ℹ️ [TIDARR] Path does not exist: ${targetPath}`);
    return false;
  }

  try {
    return fs.readdirSync(targetPath).length > 0;
  } catch (error) {
    console.error("❌ [TIDARR] Error checking files to move:", error);
    return false;
  }
}

export async function replacePathInM3U(
  item: ProcessingItemType,
): Promise<void> {
  if (item["type"] !== "playlist" && item["type"] !== "mix") return;

  const basePath = process.env.M3U_BASEPATH_FILE?.replaceAll('"', "") || ".";
  const downloadDir = path.join(PROCESSING_PATH, String(item.id));
  const app = getAppInstance();
  const libraryPath = app.locals.tiddlConfig.download.download_path;

  logs(item.id, `🕖 [TIDARR] Update track path in M3U file ...`);

  try {
    if (!fs.existsSync(downloadDir)) {
      logs(item.id, `⚠️ [TIDARR] No M3U file found`);
      return;
    }

    const allFiles = findFilesRecursive(downloadDir);
    const m3uFilePath = allFiles.find((f) => f.endsWith(".m3u"));

    if (!m3uFilePath) {
      logs(item.id, `⚠️ [TIDARR] No M3U file found`);
      return;
    }

    // Escape backslashes in paths for use in RegExp (important on Windows)
    const escapedDownloadDir = downloadDir.replace(/\\/g, "\\\\").replace(/\//g, "\\/");
    const escapedLibraryPath = libraryPath.replace(/\\/g, "\\\\").replace(/\//g, "\\/");

    let m3uContent = fs.readFileSync(m3uFilePath, "utf-8");
    m3uContent = m3uContent.replace(new RegExp(escapedDownloadDir, "g"), basePath);
    m3uContent = m3uContent.replace(new RegExp(escapedLibraryPath, "g"), basePath);
    fs.writeFileSync(m3uFilePath, m3uContent, "utf-8");

    logs(item.id, `✅ [TIDARR] M3U file updated with base path : ${basePath}`);
  } catch (e) {
    logs(
      item.id,
      `❌ [TIDARR] Error replacing path in m3u file: ${(e as Error).message}`,
    );
  }
}

export async function setPermissions(
  item: ProcessingItemType,
  basePath = PROCESSING_PATH,
) {
  // chmod / chown are Linux-only — skip silently on Windows
  if (process.platform === "win32") return;

  const itemProcessingPath = `${basePath}/${item.id}`;

  if (process.env.PUID && process.env.PGID) {
    try {
      const { stdout } = await execAsync(
        `chown -R ${process.env.PUID}:${process.env.PGID} "${itemProcessingPath}"`,
        { encoding: "utf-8", shell: "/bin/sh" },
      );
      logs(
        item.id,
        `🔑 [TIDARR] Chown PUID:PGID: ${process.env.PUID}:${process.env.PGID} - ${stdout}`,
      );
    } catch {
      logs(item.id, `⚠️ [TIDARR] Chown skipped (no files in download folder)`);
    }
  }

  if (process.env.UMASK) {
    try {
      const umaskValue = parseInt(process.env.UMASK, 8);
      const fileMode = (0o666 & ~umaskValue).toString(8);
      const dirMode = (0o777 & ~umaskValue).toString(8);
      await execAsync(
        `find "${itemProcessingPath}" -type f -exec chmod ${fileMode} {} +`,
        { encoding: "utf-8", shell: "/bin/sh" },
      );
      await execAsync(
        `find "${itemProcessingPath}" -type d -exec chmod ${dirMode} {} +`,
        { encoding: "utf-8", shell: "/bin/sh" },
      );
      logs(
        item.id,
        `🔑 [TIDARR] Chmod applied - Files: ${fileMode}, Directories: ${dirMode} (UMASK: ${process.env.UMASK})`,
      );
    } catch (error) {
      logs(
        item.id,
        `⚠️ [TIDARR] Chmod failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }
}

export async function getFolderToScan(itemId: string): Promise<string[]> {
  const foldersToScan: string[] = [];
  const itemProcessingPath = path.join(PROCESSING_PATH, String(itemId));

  try {
    if (!fs.existsSync(itemProcessingPath)) {
      console.log("📁 [TIDARR] No files found in processing folder");
      return foldersToScan;
    }

    const allFiles = findFilesRecursive(itemProcessingPath);

    if (allFiles.length === 0) {
      console.log("📁 [TIDARR] No files found in processing folder");
      return foldersToScan;
    }

    console.log(`📁 [TIDARR] Found ${allFiles.length} file(s) in processing folder`);

    const uniqueFolders = new Set<string>();
    for (const file of allFiles) {
      const fileDir = path.dirname(file);
      const relativePath = path.relative(itemProcessingPath, fileDir);
      if (relativePath && relativePath !== ".") {
        uniqueFolders.add(relativePath);
      }
    }

    foldersToScan.push(...Array.from(uniqueFolders));
  } catch (e) {
    console.error(
      `❌ [TIDARR] Error scanning processing folder: ${(e as Error).message}`,
    );
  }

  return foldersToScan;
}

export async function killProcess(
  process: ChildProcess | undefined,
  itemId?: string,
): Promise<void> {
  if (!process || process.killed) {
    return;
  }

  const context = itemId ? ` for item ${itemId}` : "";
  console.error(`⏹️ [TIDARR] Kill process ${context}:`);

  try {
    process.removeAllListeners("close");
    process.removeAllListeners("exit");
    process.removeAllListeners("error");
    process.stdout?.removeAllListeners();
    process.stderr?.removeAllListeners();

    process.kill("SIGTERM");

    await new Promise<void>((resolve) => {
      setTimeout(() => {
        if (process && !process.killed) {
          process.kill("SIGKILL");
        }
        resolve();
      }, 1000);
    });
  } catch (error) {
    console.error(`Failed to kill process${context}:`, error);
  }
}
