import { bearer } from "../_shared/auth.ts";
import { db, Sql } from "../_shared/db.ts";
import { getSecret } from "../_shared/secrets.ts";
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), {
    status: s,
    headers: { "content-type": "application/json" },
  });
export interface ManualDeps { sql: Sql; secret: () => Promise<string> }
export function createManualHandler(deps: ManualDeps) {
  return async (req: Request) => {
    if (req.method !== "POST") {
      return json({ error: "method not allowed" }, 405);
    }
    if (!bearer(req, await deps.secret())) {
      return json({ error: "unauthorized" }, 401);
    }
    let body: Record<string, unknown>;
    try {
      body = await req.json();
      if (body === null || typeof body !== "object" || Array.isArray(body)) return json({ error: "object required" }, 400);
    } catch {
      return json({ error: "invalid json" }, 400);
    }
    const payload = body.payload && typeof body.payload === "object" ? body.payload :
      Object.fromEntries(Object.entries(body).filter(([key]) => key !== "request_id"));
    if (typeof body.request_id !== "string" || typeof payload !== "object" || payload === null)
      return json({ error: "request_id and entry required" }, 400);
    try {
      const rows =
        await deps.sql`SELECT finance.create_manual_entry(${body.request_id},${
          JSON.stringify(payload)
        }::text::jsonb) result`;
      const result = rows[0]?.result as Record<string, unknown> | undefined;
      return json(result && { id: result.id, reconciliation_status: result.reconciliation_status, available_balance: result.available_balance }, 201);
    } catch (e) {
      const message = e instanceof Error ? e.message : "database error";
      return json({
        error: message.includes("conflict")
          ? "request_id conflict"
          : "invalid entry",
      }, message.includes("conflict") ? 409 : 400);
    }
  };
}
if (import.meta.main) Deno.serve(createManualHandler({ sql: db(), secret: () => getSecret("MANUAL_ENTRY_TOKEN") }));
