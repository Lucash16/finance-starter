import { db, Sql } from "../_shared/db.ts";
import { PluggyClient } from "../_shared/pluggy-client.ts";
import { SyncDb } from "../_shared/sync.ts";
import { createHandler } from "./handler.ts";
import { getSecret } from "../_shared/secrets.ts";
function adapter(sql: Sql): SyncDb {
  return {
    query: async <T = unknown>(text: string, params: unknown[] = []) =>
      await sql.unsafe(text, params as never[]) as unknown as T[],
  };
}
const sql = db();
const client = new PluggyClient({
  clientId: await getSecret("PLUGGY_CLIENT_ID"),
  clientSecret: () => getSecret("PLUGGY_CLIENT_SECRET"),
});
const runtime = globalThis as typeof globalThis & {
  EdgeRuntime?: { waitUntil(p: Promise<unknown>): void };
};
globalThis.addEventListener("unhandledrejection", (event) => {
  console.error("pluggy-sync unhandled rejection", event.reason instanceof Error ? event.reason.message : String(event.reason));
  event.preventDefault();
});
Deno.serve(
  createHandler({
    env: (key) => Deno.env.get(key),
    secret: getSecret,
    sql: adapter(sql),
    client,
    waitUntil: (p) => runtime.EdgeRuntime?.waitUntil(p),
  }),
);
