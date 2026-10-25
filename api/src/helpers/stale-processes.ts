import { execFileSync } from "child_process";

import { PROCESSING_PATH } from "../../constants";

/**
 * tiddl children outlive the API when it is killed without a graceful shutdown
 * (a crashed or `tsx watch` killed process, `taskkill`): on Windows a child is
 * not terminated with its parent. Such an orphan keeps downloading into
 * `.processing`, locks the folder — the startup cleanup then fails with EPERM —
 * and doubles the requests Tidal sees, which is exactly what the rate limit
 * punishes.
 *
 * Kills the tiddl processes whose command line points at our processing folder.
 * Returns the PIDs that were stopped.
 */
export function killStaleTiddlProcesses(): number[] {
  if (process.platform !== "win32") return [];

  const path = PROCESSING_PATH.replace(/'/g, "''");
  const script =
    `Get-CimInstance Win32_Process -Filter "Name='tiddl.exe'" | ` +
    `Where-Object { $_.CommandLine -like '*${path}*' } | ` +
    `ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $_.ProcessId }`;

  try {
    const output = execFileSync(
      "powershell",
      ["-NoProfile", "-NonInteractive", "-Command", script],
      { encoding: "utf-8", windowsHide: true, timeout: 15_000 },
    );

    return output
      .split(/\r?\n/)
      .map((line) => parseInt(line.trim(), 10))
      .filter((pid) => Number.isFinite(pid) && pid > 0);
  } catch {
    return [];
  }
}
