import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

import { CONFIG_PATH, MUSIC_PATH, ROOT_PATH } from "../../constants";

export function initializeFiles(): string {
  const output: string[] = [];
  const SETTINGS_URL = join(ROOT_PATH, "settings");
  const PUBLIC_URL = join(ROOT_PATH, "app", "build");
  const DEV_PUBLIC_URL = join(ROOT_PATH, "app", "public");
  const SHARED_URL = CONFIG_PATH;

  output.push("🕖 [TIDARR] Application loading ... ");

  // Ensure shared and music dirs exist
  mkdirSync(SHARED_URL, { recursive: true });
  mkdirSync(MUSIC_PATH, { recursive: true });

  try {
    // Create .tiddl directory
    const tiddlDir = join(SHARED_URL, ".tiddl");
    if (!existsSync(tiddlDir)) {
      mkdirSync(tiddlDir, { recursive: true });
    }

    // Copy config.toml if it doesn't exist
    const configTomlPath = join(tiddlDir, "config.toml");
    if (!existsSync(configTomlPath)) {
      try {
        let tomlContent = readFileSync(join(SETTINGS_URL, "config.toml"), "utf-8");
        // On Windows replace Linux /music paths with actual userfiles\music path
        if (process.platform === "win32") {
          // Normalize to forward slashes for TOML (tiddl accepts both)
          const musicPath = MUSIC_PATH.replace(/\\/g, "/");
          tomlContent = tomlContent.replace(
            /^download_path\s*=\s*".*"/m,
            `download_path = "${musicPath}"`,
          );
          tomlContent = tomlContent.replace(
            /^scan_path\s*=\s*".*"/m,
            `scan_path = "${musicPath}"`,
          );
        }
        writeFileSync(configTomlPath, tomlContent, "utf-8");
        output.push("✅ [TIDDL] Created config.toml from template");
      } catch (error) {
        output.push(
          "❌ [TIDDL] Failed to copy config.toml - check volume permissions",
        );
        throw error;
      }
    } else {
      output.push("✅ [TIDDL] Config.toml already exists");
    }

    // Copy beets-config.yml if it doesn't exist
    const beetsConfigPath = join(SHARED_URL, "beets-config.yml");
    if (!existsSync(beetsConfigPath)) {
      copyFileSync(join(SETTINGS_URL, "beets-config.yml"), beetsConfigPath);
      output.push("✅ [BEETS] Load config from template");
    }

    // Create beets directory and files
    const beetsDir = join(SHARED_URL, "beets");
    if (!existsSync(beetsDir)) {
      mkdirSync(beetsDir, { recursive: true });
    }

    const beetsLibPath = join(beetsDir, "beets-library.blb");
    if (!existsSync(beetsLibPath)) {
      writeFileSync(beetsLibPath, "");
      output.push("✅ [BEETS] DB file created");
    }

    const beetsLogPath = join(beetsDir, "beet.log");
    if (!existsSync(beetsLogPath)) {
      writeFileSync(beetsLogPath, "");
      output.push("✅ [BEETS] Log file created");
    }

    // Resolve the correct public dir depending on environment.
    // In dev (tsx --watch) app\build doesn't exist yet — fall back to app\public.
    // In prod (node dist/index.js) app\build exists after vite build.
    const isDev = process.env.ENVIRONMENT === "development"
      || !existsSync(PUBLIC_URL);
    const publicCssSource = isDev
      ? join(DEV_PUBLIC_URL, "custom.css")
      : join(PUBLIC_URL, "custom.css");

    const customCssPath = join(SHARED_URL, "custom.css");

    // Ensure the parent dir and source CSS file exist
    mkdirSync(isDev ? DEV_PUBLIC_URL : PUBLIC_URL, { recursive: true });
    if (!existsSync(publicCssSource)) {
      writeFileSync(publicCssSource, "");
    }

    if (!existsSync(customCssPath)) {
      copyFileSync(publicCssSource, customCssPath);
      output.push("✅ [CSS] Custom style file created");
    }

    // Sync shared custom.css back to the public dir (non-fatal)
    try {
      copyFileSync(customCssPath, publicCssSource);
      output.push("✅ [CSS] Load custom styles");
    } catch {
      output.push("⚠️ [CSS] Could not load custom styles");
    }
  } catch (error) {
    output.push(`❌ [TIDARR] Failed to initialize files: ${error}`);
    throw error;
  }

  return output.join("\n");
}
