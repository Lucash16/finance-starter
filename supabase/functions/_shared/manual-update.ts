import { PluggyClient, PluggyError } from "./pluggy-client.ts";
import { ALLOWED_ITEMS, SyncDb, SyncService } from "./sync.ts";

export interface UpdateItem {
  itemId: string;
  institution: string;
  pluggyStatus: string;
  syncStatus: "pending" | "running" | "done" | "skipped" | "failed";
  message?: string;
}
export interface UpdateTiming {
  responseMs?: number;
  totalMs?: number;
  pollMs?: number;
}

export async function manualUpdate(
  client: PluggyClient,
  sql: SyncDb,
  waitUntil: (task: Promise<unknown>) => void,
  timing: UpdateTiming = {},
): Promise<{ status: number; body: unknown }> {
  const items: UpdateItem[] = [...ALLOWED_ITEMS].map((itemId, i) => ({
    itemId,
    institution: `Conexão ${i + 1}`,
    pluggyStatus: "PENDING",
    syncStatus: "pending",
  }));
  const deadline = Date.now() + (timing.totalMs ?? 180_000);
  const service = new SyncService(sql, client);
  const work = Promise.all(items.map(async (result) => {
    try {
      let syncAvailable = false;
      try {
        await client.request("PATCH", `/items/${result.itemId}`, {});
      } catch (error) {
        if (!(error instanceof PluggyError) || error.status !== 400) {
          throw error;
        }
        const detail = error.message.replace(/[_-]/g, " ");
        if (
          /MFA|required\s*param|param.*required|waiting.*user|user\s*action|LOGIN ERROR/i
            .test(detail)
        ) {
          result.syncStatus = "skipped";
          result.message = /LOGIN ERROR/i.test(detail)
            ? "Confira suas credenciais e reconecte o banco."
            : "É necessária sua confirmação no app do banco.";
          return;
        }
        if (
          !/MeuPluggy|(?:can(?:not|'t|t)|could not).*be updated|(?:update|updating).*(?:not allowed|not supported)/i
            .test(detail)
        ) throw error;
        syncAvailable = true;
        result.message =
          "Pluggy não permite forçar atualização deste conector; sincronizando os dados já disponíveis.";
      }
      while (Date.now() < deadline) {
        const item = await client.request<Record<string, unknown>>(
          "GET",
          `/items/${result.itemId}`,
        );
        result.institution = String((item.connector as { name?: string } | undefined)?.name ?? result.institution);
        const status = String(item.status ?? "UNKNOWN");
        const execution = String(item.executionStatus ?? "");
        result.pluggyStatus = status;
        await sql.query(
          "UPDATE finance.items SET status=$2,execution_status=$3,last_updated_at=$4,error=$5::text::jsonb,status_detail=$6::text::jsonb WHERE pluggy_id=$1",
          [
            result.itemId,
            status,
            item.executionStatus ?? null,
            item.lastUpdatedAt ?? null,
            JSON.stringify(item.error ?? null),
            JSON.stringify(item.statusDetail ?? null),
          ],
        );
        if (
          ["WAITING_USER_INPUT", "WAITING_USER_ACTION", "LOGIN_ERROR"].includes(
            status,
          )
        ) {
          result.syncStatus = "skipped";
          result.message = status === "LOGIN_ERROR"
            ? "Confira suas credenciais e reconecte o banco."
            : "É necessária sua confirmação no app do banco.";
          return;
        }
        if (syncAvailable) {
          result.syncStatus = "running";
          await service.refreshItem(result.itemId, 7, "backfill");
          result.syncStatus = "done";
          return;
        }
        if (
          status === "ERROR" || (status === "OUTDATED" && item.error) ||
          execution === "ERROR"
        ) {
          result.syncStatus = "skipped";
          result.message =
            "O banco não conseguiu atualizar os dados. Tente novamente mais tarde.";
          return;
        }
        const inProgress = ["UPDATING", "CREATED"].includes(status) ||
          ["CREATED", "PENDING", "RUNNING", "IN_PROGRESS", "UPDATING"].includes(
            execution,
          );
        if (
          !inProgress &&
          (status === "UPDATED" ||
            ["SUCCESS", "PARTIAL_SUCCESS"].includes(execution))
        ) {
          result.syncStatus = "running";
          await service.refreshItem(result.itemId, 7, "backfill");
          result.syncStatus = "done";
          return;
        }
        await new Promise((resolve) =>
          setTimeout(
            resolve,
            Math.min(timing.pollMs ?? 4000, Math.max(0, deadline - Date.now())),
          )
        );
      }
      result.syncStatus = "skipped";
      result.message =
        "A atualização demorou além do limite. Consulte o estado da conexão antes de tentar novamente.";
    } catch (error) {
      result.syncStatus = "failed";
      result.message =
        "Não foi possível concluir a atualização. Tente novamente mais tarde.";
      if (error instanceof PluggyError) result.message += ` ${error.message}`;
    }
  }));
  // Register immediately so a disconnected HTTP client does not cancel the work.
  waitUntil(work);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const finished = await Promise.race([
    work.then(() => true),
    new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), timing.responseMs ?? 150_000);
    }),
  ]);
  clearTimeout(timer);
  return finished
    ? {
      status: 200,
      body: {
        ok: items.every((item) => item.syncStatus === "done"),
        mode: "update",
        items,
        finishedAt: new Date().toISOString(),
      },
    }
    : { status: 202, body: { accepted: true, mode: "update", items } };
}
