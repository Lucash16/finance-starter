import { manualUpdate, UpdateTiming } from "../_shared/manual-update.ts";
import { bearer, timingSafeEqual } from "../_shared/auth.ts";
import { PluggyClient } from "../_shared/pluggy-client.ts";
import { ALLOWED_ITEMS, SyncDb, SyncService } from "../_shared/sync.ts";
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
export interface HandlerDeps {
  updateTiming?: UpdateTiming;
  env: (key: string) => string | undefined;
  secret?: (key: string) => Promise<string>;
  sql: SyncDb;
  client: PluggyClient;
  waitUntil: (p: Promise<unknown>) => void;
}
const logBackgroundError = (error: unknown) =>
  console.error("pluggy-sync background task failed", error instanceof Error ? error.message : String(error));
async function finishEvent(
  deps: HandlerDeps,
  id: string,
  payload: Record<string, unknown>,
) {
  try {
    await deps.sql.query(
      "UPDATE finance.webhook_events SET status='processing',attempts=attempts+1,updated_at=now() WHERE event_id=$1",
      [id],
    );
    const status = await new SyncService(deps.sql, deps.client).processEvent(
      payload,
    );
    await deps.sql.query(
      "UPDATE finance.webhook_events SET status=$2,processed_at=now(),updated_at=now(),last_error=NULL WHERE event_id=$1",
      [id, status],
    );
  } catch (e) {
    await deps.sql.query(
      "UPDATE finance.webhook_events SET status='failed',updated_at=now(),last_error=$2 WHERE event_id=$1",
      [id, e instanceof Error ? e.message.slice(0, 1000) : "erro desconhecido"],
    );
    throw e;
  }
}
export function createHandler(deps: HandlerDeps) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }
    const url = new URL(request.url);
    const mode = url.searchParams.get("mode");
    if (mode) {
      const token = deps.secret ? await deps.secret("FINANCE_SYNC_TOKEN") : deps.env("FINANCE_SYNC_TOKEN");
      if (!bearer(request, token)) {
        return json({ error: "unauthorized" }, 401);
      }
      if (mode === "update") {
        const result = await manualUpdate(deps.client, deps.sql, deps.waitUntil, deps.updateTiming);
        return json(result.body, result.status);
      }
      if (!["backfill", "full", "drain"].includes(mode)) {
        return json({ error: "invalid mode" }, 400);
      }
      if (mode === "full" && deps.env("FINANCE_HISTORY_START") && !Number.isFinite(Date.parse(deps.env("FINANCE_HISTORY_START")!))) return json({ error: "invalid FINANCE_HISTORY_START" }, 400);
      const acceptedMode = mode as "backfill" | "full" | "drain";
      const task = (async () => {
        const service = new SyncService(deps.sql, deps.client);
        if (mode === "drain") {
          const events = await deps.sql.query<Record<string, unknown>>(
            "UPDATE finance.webhook_events SET status='processing',updated_at=now() WHERE id IN (SELECT id FROM finance.webhook_events WHERE attempts<5 AND (status IN ('received','failed') OR (status='processing' AND updated_at<now()-interval '10 minutes')) ORDER BY received_at LIMIT 20 FOR UPDATE SKIP LOCKED) RETURNING event_id,payload",
          );
          for (const e of events) {
            try {
              await finishEvent(deps, String(e.event_id), e.payload as Record<string, unknown>);
            } catch (error) {
              logBackgroundError(error);
            }
          }
        } else {
          const days = mode === "full"
            ? Math.ceil((Date.now() - Date.parse(deps.env("FINANCE_HISTORY_START") ?? new Date(Date.now() - 365 * 86400000).toISOString())) / 86400000)
            : Math.min(
              Math.max(Number(url.searchParams.get("days") ?? 35), 1),
              180,
            );
          for (const item of ALLOWED_ITEMS) {
            await service.refreshItem(item, days, acceptedMode === "full" ? "full" : "backfill");
          }
        }
      })();
      deps.waitUntil(task.catch(logBackgroundError));
      return json({ accepted: true, mode }, 202);
    }
    const webhookSecret = deps.secret ? await deps.secret("PLUGGY_WEBHOOK_SECRET") : deps.env("PLUGGY_WEBHOOK_SECRET");
    if (
      !timingSafeEqual(
        request.headers.get("X-Webhook-Secret"),
        webhookSecret,
      )
    ) return json({ error: "unauthorized" }, 401);
    let payload: Record<string, unknown>;
    try {
      payload = await request.json();
    } catch {
      return json({ error: "invalid json" }, 400);
    }
    const eventId = payload.eventId, event = payload.event;
    if (
      typeof eventId !== "string" || !eventId || typeof event !== "string" ||
      !event
    ) return json({ error: "eventId and event required" }, 400);
    const itemId = typeof payload.itemId === "string" ? payload.itemId : null;
    const allowed = event === "item/updated"
      ? itemId !== null && ALLOWED_ITEMS.has(itemId)
      : !itemId || ALLOWED_ITEMS.has(itemId);
    let rows: unknown[];
    try {
      rows = await deps.sql.query(
        "INSERT INTO finance.webhook_events(event_id,event,item_pluggy_id,account_pluggy_id,payload,status) VALUES($1,$2,$3,$4,$5::text::jsonb,$6) ON CONFLICT(event_id) DO NOTHING RETURNING id",
        [
          eventId,
          event,
          itemId,
          typeof payload.accountId === "string" ? payload.accountId : null,
          JSON.stringify(payload),
          allowed ? "received" : "ignored",
        ],
      );
    } catch {
      return json({ error: "temporary persistence failure" }, 503);
    }
    if (!allowed) return json({ accepted: true, status: "ignored" }, 202);
    // Item updates can arrive after a sync finishes; leave them queued for the drain.
    if (rows.length && event !== "item/updated") deps.waitUntil(finishEvent(deps, eventId, payload).catch(logBackgroundError));
    return json({ accepted: true, duplicate: rows.length === 0 }, 202);
  };
}
