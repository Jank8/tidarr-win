import { spawn } from "child_process";
import fs from "fs";
import path from "path";

import { CONFIG_PATH, PROCESSING_PATH } from "../../constants";
import { getAppInstance } from "../helpers/app-instance";
import { logs } from "../processing/utils/logs";
import { ProcessingItemType } from "../types";

interface ScriptRunner {
  file: string;
  command: string;
  args: string[];
}

interface ScriptConfig {
  runner: ScriptRunner;
  cwd: string;
  env: Record<string, string>;
  logPrefix: string;
  scriptName: string;
}

/**
 * Finds the hook to run and how to run it.
 * Windows gets native hooks first (.ps1, .cmd/.bat) and falls back to .sh via
 * Git for Windows; everywhere else .sh is the only option.
 */
function resolveScript(baseName: string): ScriptRunner | null {
  const candidates =
    process.platform === "win32"
      ? [
          {
            ext: ".ps1",
            command: "powershell.exe",
            args: (file: string) => [
              "-NoProfile",
              "-ExecutionPolicy",
              "Bypass",
              "-File",
              file,
            ],
          },
          {
            ext: ".cmd",
            command: "cmd.exe",
            args: (file: string) => ["/c", file],
          },
          {
            ext: ".bat",
            command: "cmd.exe",
            args: (file: string) => ["/c", file],
          },
          {
            ext: ".sh",
            command: "sh",
            args: (file: string) => [file],
          },
        ]
      : [
          { ext: ".sh", command: "sh", args: (file: string) => [file] },
        ];

  for (const candidate of candidates) {
    const file = path.join(CONFIG_PATH, baseName + candidate.ext);
    if (fs.existsSync(file)) {
      return { file, command: candidate.command, args: candidate.args(file) };
    }
  }

  return null;
}

/**
 * Generic script runner that handles spawn, logging and error handling.
 */
async function runScript(
  item: ProcessingItemType,
  config: ScriptConfig,
): Promise<void> {
  const { runner, cwd, env, logPrefix, scriptName } = config;

  logs(
    item.id,
    `🕖 [TIDARR] Executing ${scriptName} (${path.basename(runner.file)})...`,
  );

  return new Promise((resolve) => {
    const scriptProcess = spawn(runner.command, runner.args, {
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

    scriptProcess.on("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") {
        logs(
          item.id,
          `❌ [TIDARR] ${scriptName} not started: "${runner.command}" not found. ` +
            `On Windows use a .ps1 or .cmd hook, or install Git for Windows to run .sh files.`,
        );
      } else {
        logs(item.id, `❌ [TIDARR] ${scriptName} error: ${error.message}`);
      }
      resolve();
    });
  });
}

export async function executeCustomScript(
  item: ProcessingItemType,
): Promise<void> {
  const runner = resolveScript("custom-script");
  if (!runner) return;

  const itemProcessingPath = path.join(PROCESSING_PATH, String(item.id));

  return runScript(item, {
    runner,
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
  const runner = resolveScript("custom-post-script");
  if (!runner) return;

  const app = getAppInstance();
  const libraryPath = app.locals.tiddlConfig?.download?.download_path;

  if (!libraryPath) {
    logs(
      item.id,
      "❌ [TIDARR] No library path configured, skipping post-script",
    );
    return;
  }

  return runScript(item, {
    runner,
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
