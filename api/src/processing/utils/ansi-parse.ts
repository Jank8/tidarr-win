/**
 * Strip problematic ANSI escape sequences while keeping colors:
 * - Keep: Color codes (ESC[...m)
 * - Remove: OSC 8 hyperlinks (ESC]8;...;...ESC\)
 * - Remove: Cursor movements (ESC[...A, ESC[...B, ESC[2K, etc.)
 * - Remove: Other control characters
 */
export function stripAnsiCodes(text: string): string {
  const ESC = "\x1b";

  return (
    text
      // Remove every OSC 8 hyperlink command (open AND close) atomically.
      // Rich emits a separate open/close pair around each styled segment
      // (ESC]8;<params>;<uri>ESC\ ... ESC]8;;ESC\).
      // oxlint-disable-next-line no-control-regex
      .replace(/\x1b\]8;[^\x1b\x07]*(?:\x1b\\|\x07)/g, "")
      // Remove cursor movements: ESC[nA, ESC[nB, ESC[nC, ESC[nD, ESC[2K, ESC[1A, etc.
      .replace(new RegExp(`${ESC}\\[[0-9]*[ABCDEFGJKST]`, "g"), "")
      // Remove other OSC sequences (but keep CSI color codes)
      .replace(new RegExp(`${ESC}\\][^\x07]*\x07`, "g"), "")
      // Remove remaining control characters except newlines, carriage returns, and ESC (for colors)
      // eslint-disable-next-line no-control-regex
      .replace(/[\x00-\x09\x0B-\x0C\x0E-\x1A\x1C-\x1F\x7F]/g, "")
  );
}

/**
 * tiddl prints the item folder as a hyperlink after the title, e.g.
 * `Downloaded Song C:\music\Artist\2020 - Album`. The hyperlink escapes are
 * removed by `stripAnsiCodes`, this drops the leftover path column so the
 * console shows just `Downloaded Song`.
 */
export function stripItemPath(text: string): string {
  return text.replace(/\s+[A-Za-z]:\\[^\r\n]*$/, "").trim();
}
