import { Express, Request, Response, Router } from "express";

import { ensureAccessIsGranted } from "../helpers/auth";
import {
  broadcastQueueEvent,
  buildQueueEvent,
} from "../processing/core/processing-manager";

const router = Router();

// In addition to the change-driven updates, every open stream gets a full
// snapshot on a timer. It keeps idle connections alive through the dev proxy
// and re-syncs a client that missed an event, so the page can never stay stale
// until a manual reload.
const SNAPSHOT_INTERVAL_MS = 10_000;

let snapshotTimer: NodeJS.Timeout | null = null;

function ensureSnapshotTimer(app: Express) {
  if (snapshotTimer) return;

  snapshotTimer = setInterval(() => {
    if (!app.locals.activeListConnections?.length) return;
    broadcastQueueEvent(app, buildQueueEvent(app));
  }, SNAPSHOT_INTERVAL_MS);

  // Never keep the process alive just for the timer.
  snapshotTimer.unref();
}

/**
 * GET /api/stream-processing
 * Server-Sent Events endpoint for processing queue updates
 */
router.get(
  "/stream-processing",
  ensureAccessIsGranted,
  (req: Request, res: Response) => {
    // `req.app` is typed as Application; the queue helpers work on the Express
    // app instance and only touch `app.locals`.
    const app = req.app as unknown as Express;

    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache");
    res.setHeader("Connection", "keep-alive");
    // Keep reverse proxies (nginx, when HOST=0.0.0.0) from buffering the stream
    res.setHeader("X-Accel-Buffering", "no");
    res.flushHeaders();

    // Add the new connection to the list
    app.locals.activeListConnections.push(res);
    ensureSnapshotTimer(app);

    // Remove the connection from the list when it closes
    req.on("close", () => {
      app.locals.activeListConnections = app.locals.activeListConnections.filter(
        (conn: Response) => conn !== res,
      );
    });

    // Send initial state to the new client
    res.write(`data: ${buildQueueEvent(app)}\n\n`);
  },
);

/**
 * GET /api/stream-item-output/:id
 * Server-Sent Events endpoint for individual item output logs
 */
router.get(
  "/stream-item-output/:id",
  ensureAccessIsGranted,
  (req: Request, res: Response) => {
    const itemId = String(req.params.id);

    res.setHeader("Content-Type", "text/event-stream");
    res.setHeader("Cache-Control", "no-cache");
    res.setHeader("Connection", "keep-alive");
    res.setHeader("X-Accel-Buffering", "no");
    res.flushHeaders();

    // Get or create the connections array for this item
    const connections: Map<string, Response[]> =
      req.app.locals.activeItemOutputConnections;
    if (!connections.has(itemId)) {
      connections.set(itemId, []);
    }
    connections.get(itemId)?.push(res);

    // Remove the connection when it closes
    req.on("close", () => {
      const itemConnections = connections.get(itemId);
      if (itemConnections) {
        const filtered = itemConnections.filter((conn) => conn !== res);
        if (filtered.length === 0) {
          connections.delete(itemId);
        } else {
          connections.set(itemId, filtered);
        }
      }
    });

    // Send initial output for this item
    const output =
      req.app.locals.processingStack.actions.getItemOutput(itemId) || "";
    res.write(`data: ${JSON.stringify({ id: itemId, output })}\n\n`);
  },
);

export default router;
