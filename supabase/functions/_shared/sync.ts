import { PluggyClient } from "./pluggy-client.ts";
import { paginate } from "./pagination.ts";
import { configuredItemIds } from "./config.ts";
export const ALLOWED_ITEMS = configuredItemIds(Deno.env.get("PLUGGY_ITEM_IDS"));
export interface SyncDb {
  query<T = unknown>(text: string, params?: unknown[]): Promise<T[]>;
}
export class SyncService {
  constructor(private sql: SyncDb, private client: PluggyClient) {}
  private async startRun(mode: "backfill" | "full" | "webhook" | "drain", itemId: string, accountId?: string, dateFrom?: string) {
    const rows = await this.sql.query<{ id: string }>(
      "INSERT INTO finance.sync_runs(mode,item_id,account_id,date_from) VALUES($1,coalesce((SELECT id FROM finance.items WHERE pluggy_id=$2),(SELECT item_id FROM finance.accounts WHERE pluggy_id=$3)),(SELECT id FROM finance.accounts WHERE pluggy_id=$3),$4::date) RETURNING id",
      [mode, itemId, accountId ?? null, dateFrom ?? null],
    );
    return rows[0]?.id;
  }
  private async finishRun(id: string | undefined, status: "done" | "failed", accounts: number, transactions: number, error?: unknown) {
    if (!id) return;
    const safeError = error instanceof Error ? error.message.slice(0, 1000) : String(error ?? "").slice(0, 1000);
    await this.sql.query(
      "UPDATE finance.sync_runs SET status=$2,accounts_count=accounts_count+$3,transactions_count=transactions_count+$4,finished_at=now(),error=$5::text::jsonb WHERE id=$1::uuid",
      [id, status, accounts, transactions, error ? JSON.stringify({ message: safeError }) : null],
    );
  }
  async refreshItem(itemId: string, days = 7, mode: "backfill" | "full" | "webhook" = "backfill") {
    if (!ALLOWED_ITEMS.has(itemId)) return;
    const dateFrom = this.dateDaysAgo(days);
    const runId = await this.startRun(mode, itemId, undefined, dateFrom);
    let accountCount = 0, transactionCount = 0;
    try {
    const item = await this.client.request<Record<string, unknown>>(
      "GET",
      `/items/${itemId}`,
    );
    await this.sql.query(
      "UPDATE finance.items SET status=$2,execution_status=$3,last_updated_at=$4,next_auto_sync_at=$5,consent_expires_at=$6,error=$7::text::jsonb,status_detail=$8::text::jsonb,raw=$9::text::jsonb WHERE pluggy_id=$1",
      [
        itemId,
        item.status,
        item.executionStatus,
        item.lastUpdatedAt,
        item.nextAutoSyncAt,
        item.consentExpiresAt,
        JSON.stringify(item.error ?? null),
        JSON.stringify(item.statusDetail ?? null),
        JSON.stringify(item),
      ],
    );
    const accounts = await this.client.request<
      { results?: Record<string, unknown>[] }
    >("GET", `/accounts?itemId=${encodeURIComponent(itemId)}`);
    await this.sql.query("SELECT finance.upsert_accounts($1,$2::text::jsonb)", [
      itemId,
      JSON.stringify(accounts.results ?? []),
    ]);
    for (const a of accounts.results ?? []) {
      const id = String(a.id ?? "");
      if (!id) continue;
      accountCount++;
      if (a.type === "CREDIT") {
        const bills = await this.client.request<{ results?: unknown[] }>(
          "GET",
          `/bills?accountId=${encodeURIComponent(id)}`,
        );
        await this.sql.query("SELECT finance.upsert_bills($1,$2::text::jsonb)", [
          id,
          JSON.stringify(bills.results ?? []),
        ]);
      }
      transactionCount += await this.syncAccount(id, dateFrom, undefined, runId);
    }
    await this.sql.query("SELECT finance.reconcile_pending()", []);
    await this.finishRun(runId, "done", accountCount, transactionCount);
    } catch (error) {
      await this.finishRun(runId, "failed", accountCount, transactionCount, error);
      throw error;
    }
  }
  async syncAccount(accountId: string, dateFrom?: string, path?: string, runId?: string) {
    const initial = path ??
      `/v2/transactions?accountId=${encodeURIComponent(accountId)}${
        dateFrom ? `&dateFrom=${dateFrom}` : ""
      }`;
    let count = 0;
    for await (
      const page of paginate<Record<string, unknown>>(this.client, initial)
    ) {
      const result = await this.sql.query<{ result: Record<string, number> }>(
        "SELECT finance.upsert_pluggy_transactions($1,$2::text::jsonb,$3::uuid) AS result",
        [accountId, JSON.stringify(page), runId ?? null],
      );
      const counters = result[0]?.result;
      count += counters ? Number(counters.inserted ?? 0) + Number(counters.updated ?? 0) + Number(counters.unchanged ?? 0) : page.length;
    }
    await this.sql.query("SELECT finance.reconcile_pending()", []);
    return count;
  }
  async processEvent(payload: Record<string, unknown>) {
    const event = String(payload.event ?? "");
    const itemId = String(payload.itemId ?? "");
    const accountId = String(payload.accountId ?? "");
    if (itemId && !ALLOWED_ITEMS.has(itemId)) return "ignored";
    const fallbackDate = String(payload.transactionsMinDate ?? this.dateDaysAgo(7)).slice(0, 10);
    const runId = await this.startRun("webhook", itemId, accountId || undefined, fallbackDate);
    let transactionCount = 0;
    try {
    if (event === "transactions/created") {
      const rawCreated = payload.transactionsCreatedAtFrom;
      const created = typeof rawCreated === "string" && rawCreated ? encodeURIComponent(rawCreated) : null;
      transactionCount += await this.syncAccount(
        accountId,
        created ? undefined : fallbackDate,
        created ? `/v2/transactions?accountId=${
          encodeURIComponent(accountId)
        }&createdAtFrom=${created}` : undefined,
        runId,
      );
    } else if (event === "transactions/updated") {
      const ids = Array.isArray(payload.transactionIds)
        ? payload.transactionIds.map(String)
        : [];
      for (let i = 0; i < ids.length; i += 500) {
        transactionCount += await this.syncAccount(
          accountId,
          undefined,
          `/v2/transactions?accountId=${encodeURIComponent(accountId)}&ids=${
            encodeURIComponent(ids.slice(i, i + 500).join(","))
          }`,
          runId,
        );
      }
    } else if (event === "transactions/deleted") {
      await this.sql.query(
        "SELECT finance.soft_delete_pluggy_transactions($1,$2::text[])",
        [
          accountId,
          Array.isArray(payload.transactionIds) ? payload.transactionIds : [],
        ],
      );
      await this.sql.query("SELECT finance.reconcile_pending()", []);
    } else if (event === "item/updated" || event === "item/login_succeeded") {
      await this.refreshItem(itemId, 7, "webhook");
    } else if (
      ["item/error", "item/waiting_user_input", "item/waiting_user_action"]
        .includes(event)
    ) {
      const item = await this.client.request<Record<string, unknown>>(
        "GET",
        `/items/${itemId}`,
      );
      await this.sql.query(
        "UPDATE finance.items SET status=$2,execution_status=$3,error=$4::text::jsonb,status_detail=$5::text::jsonb,raw=$6::text::jsonb WHERE pluggy_id=$1",
        [
          itemId,
          item.status,
          item.executionStatus,
          JSON.stringify(item.error ?? null),
          JSON.stringify(item.statusDetail ?? null),
          JSON.stringify(item),
        ],
      );
    } else {
      await this.finishRun(runId, "done", 0, 0);
      return "ignored";
    }
    await this.finishRun(runId, "done", accountId ? 1 : 0, transactionCount);
    return "done";
    } catch (error) {
      await this.finishRun(runId, "failed", accountId ? 1 : 0, transactionCount, error);
      throw error;
    }
  }
  private dateDaysAgo(days: number) {
    const d = new Date();
    d.setUTCDate(d.getUTCDate() - days);
    return d.toISOString().slice(0, 10);
  }
}
