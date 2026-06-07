import { spawn } from "child_process";
import fs from "fs";
import path from "path";

import { CONFIG_PATH, PROCESSING_PATH } from "../../constants";
import { getAppInstance } from "../helpers/app-instance";
import { logs } from "../processing/utils/logs";
import { ProcessingItemType } from "../types";

interface ScriptConfig {
  scriptPath: string;
  cwd: string;
  env: Record<string, string>;
  logPrefix: string;
  scriptName: string;
}

/**
 * Generic script runner.
 * On Linux/Mac: executes .sh via sh.
 * On Windows: silently skipped (shell scripts not supported natively).
 */
async function runScript(
  item: ProcessingItemType,
  config: ScriptConfig,
): Promise<void> {
  const { scriptPath, cwd, env, logPrefix, scriptName } = config;

  if (!fs.existsSync(scriptPath)) return;

  // Shell scripts (.sh) are not natively executable on Windows
  if (process.platform === "win32") {
    logs(item.id, `⚠️ [TIDARR] Skipping ${scriptName} on Windows (shell scripts not supported)`);
    return;
  }

  logs(item.id, `🕖 [TIDARR] Executing ${scriptName}...`);

  return new Promise((resolve) => {
    const scriptProcess = spawn("sh", [scriptPath], {
      cwd,
      env: { ...process.env, ...env },
    });

    const handleOutput = (data: Buffer) => {
      const output = data.toString().trim();
      if (output) {
        logs(item.id, `🤖 [${logPrefix}] ${output}`);
      }
    };

    scriptProcess.stdout?.on("data", handleOutput);
    scriptProcess.stderr?.on("data", handleOutput);

    scriptProcess.on("close", (code) => {
      if (code === 0) {
        logs(item.id, `✅ [TIDARR] ${scriptName} executed successfully`);
      } else {
        logs(item.id, `⚠️ [TIDARR] ${scriptName} exited with code ${code}`);
      }
      resolve();
    });

    scriptProcess.on("error", (error) => {
      logs(item.id, `❌ [TIDARR] ${scriptName} error: ${error.message}`);
      resolve();
    });
  });
}

export async function executeCustomScript(
  item: ProcessingItemType,
): Promise<void> {
  const itemProcessingPath = path.join(PROCESSING_PATH, String(item.id));

  return runScript(item, {
    scriptPath: path.join(CONFIG_PATH, "custom-script.sh"),
    cwd: itemProcessingPath,
    env: {
      PROCESSING_PATH: itemProcessingPath,
      ITEM_TYPE: item.type,
      ITEM_URL: item.url,
      ITEM_NAME: item.title,
    },
    logPrefix: "CUSTOM SCRIPT",
    scriptName: "custom script",
  });
}

export async function executePostScript(
  item: ProcessingItemType,
  foldersToScan: string[],
): Promise<void> {
  const app = getAppInstance();
  const libraryPath = app.locals.tiddlConfig.download.download_path;

  return runScript(item, {
    scriptPath: path.join(CONFIG_PATH, "custom-post-script.sh"),
    cwd: libraryPath,
    env: {
      DESTINATION_PATH: libraryPath,
      FOLDERS_MOVED: foldersToScan.join(","),
      ITEM_TYPE: item.type,
      ITEM_URL: item.url,
      ITEM_NAME: item.title,
    },
    logPrefix: "POST SCRIPT",
    scriptName: "custom post-script",
  });
}
