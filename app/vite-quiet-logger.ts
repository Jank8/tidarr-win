import { createLogger } from "vite";

/**
 * True for the lines Vite logs when a request cannot be forwarded at all while
 * the API restarts (`http proxy error: /api/stream-processing` followed by
 * ECONNREFUSED or ECONNRESET). The page reconnects on its own, so those stack
 * traces only add noise — every other proxy error is still reported.
 */
export function isTransientProxyError(message: unknown): boolean {
  return (
    typeof message === "string" &&
    message.includes("http proxy error") &&
    /ECONNREFUSED|ECONNRESET/.test(message)
  );
}

/** Vite logger that drops just those lines. */
export function createQuietLogger() {
  const logger = createLogger();
  const logError = logger.error.bind(logger);

  logger.error = (message, options) => {
    if (isTransientProxyError(message)) return;
    logError(message, options);
  };

  return logger;
}
