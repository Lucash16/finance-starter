import postgres from "npm:postgres@3.4.7";
import { PluggyClient } from "../_shared/pluggy-client.ts";
import { SyncService } from "../_shared/sync.ts";

const databaseUrl = Deno.env.get("FINANCE_TEST_DB");
const itemId = "fixture-2411";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test({
  name: "refreshItem persiste JSON real e é idempotente com postgres.js",
  ignore: !databaseUrl,
  fn: async () => {
    const sql = postgres(databaseUrl!, { prepare: false, max: 1 });
    const bankId = "integration-bank";
    const creditId = "integration-credit";
    const now = "2026-10-07T12:00:00Z";
    const item = {
      id: itemId,
      status: "UPDATED",
      executionStatus: "SUCCESS",
      lastUpdatedAt: now,
      nextAutoSyncAt: "2026-10-08T12:00:00Z",
      consentExpiresAt: "2027-10-07T12:00:00Z",
      error: null,
      statusDetail: { message: "ok" },
    };
    const accounts = [
      { id: bankId, itemId, type: "BANK", subtype: "CHECKING_ACCOUNT", name: "Conta integração", number: "1234", balance: 900, currencyCode: "BRL" },
      { id: creditId, itemId, type: "CREDIT", subtype: "CREDIT_CARD", name: "Cartão integração", balance: 130, currencyCode: "BRL", creditData: { brand: "VISA", creditLimit: 5000, availableCreditLimit: 4870, additionalCards: [{ number: "1111" }, { number: "2222" }] } },
    ];
    const transactions: Record<string, unknown[]> = {
      [bankId]: [{ id: "integration-payment", accountId: bankId, description: "Pagamento fatura", currencyCode: "BRL", amount: -130, date: "2026-10-06T00:00:00Z", categoryId: "05100000", status: "POSTED", type: "DEBIT", createdAt: now, updatedAt: now }],
      [creditId]: [
        { id: "integration-installment", accountId: creditId, description: "Compra parcelada", currencyCode: "BRL", amount: 100, date: "2026-10-05T00:00:00Z", categoryId: "08010000", status: "POSTED", type: "DEBIT", createdAt: now, updatedAt: now, creditCardMetadata: { cardNumber: "1111", billId: "integration-bill", billForecastDate: "2026-11", purchaseDate: "2026-09-20T00:00:00Z", transactionDateTime: "2026-09-20T15:00:00-03:00", installmentNumber: 2, totalInstallments: 3, totalAmount: 300 } },
        { id: "integration-pending", accountId: creditId, description: "Compra pendente", currencyCode: "BRL", amount: 30, date: "2026-10-07T00:00:00Z", categoryId: "11020000", status: "PENDING", type: "DEBIT", createdAt: now, updatedAt: now, creditCardMetadata: { cardNumber: "2222", billForecastDate: "2026-11", purchaseDate: "2026-10-07T00:00:00Z" } },
      ],
    };
    const bills = [{ id: "integration-bill", dueDate: "2026-11-10", billClosingDate: "2026-11-03", totalAmount: 100, totalAmountCurrencyCode: "BRL", minimumPaymentAmount: 15, allowsInstallments: false, financeCharges: [], payments: [], createdAt: now, updatedAt: now }];
    const fetchMock: typeof fetch = async (input) => {
      const url = new URL(String(input));
      if (url.pathname === "/auth") return Response.json({ apiKey: "integration-key" });
      if (url.pathname === `/items/${itemId}`) return Response.json(item);
      if (url.pathname === "/accounts") return Response.json({ results: accounts });
      if (url.pathname === "/bills") return Response.json({ results: bills });
      if (url.pathname === "/v2/transactions") return Response.json({ results: transactions[url.searchParams.get("accountId") ?? ""] ?? [], next: null });
      return new Response("not found", { status: 404 });
    };
    const db = { query: <T>(text: string, params: unknown[] = []) => sql.unsafe<T[]>(text, params as never[]) };
    const service = new SyncService(db, new PluggyClient({ clientId: "integration", clientSecret: "not-a-secret", fetch: fetchMock }));
    try {
      await sql`DELETE FROM finance.transactions WHERE pluggy_id LIKE 'integration-%'`;
      await sql`DELETE FROM finance.credit_card_bills WHERE pluggy_id='integration-bill'`;
      await sql`DELETE FROM finance.accounts WHERE pluggy_id IN (${bankId},${creditId})`;
      await service.refreshItem(itemId, 365, "full");

      const [state] = await sql<{ raw_type: string; account_objects: number; transaction_objects: number; transaction_count: number; revision_count: number; done_runs: number }[]>`
        SELECT jsonb_typeof(i.raw) raw_type,
          (SELECT count(*)::int FROM finance.accounts WHERE pluggy_id IN (${bankId},${creditId}) AND jsonb_typeof(raw)='object') account_objects,
          (SELECT count(*)::int FROM finance.transactions WHERE pluggy_id LIKE 'integration-%' AND jsonb_typeof(raw)='object') transaction_objects,
          (SELECT count(*)::int FROM finance.transactions WHERE pluggy_id LIKE 'integration-%') transaction_count,
          (SELECT count(*)::int FROM finance.transaction_revisions r JOIN finance.transactions t ON t.id=r.transaction_id WHERE t.pluggy_id LIKE 'integration-%') revision_count,
          (SELECT count(*)::int FROM finance.sync_runs WHERE mode='full' AND status='done') done_runs
        FROM finance.items i WHERE i.pluggy_id=${itemId}`;
      assert(state.raw_type === "object", "items.raw deve ser objeto JSON");
      assert(state.account_objects === 2, "accounts.raw deve preservar objetos JSON");
      assert(state.transaction_objects === 3, "transactions.raw deve preservar objetos JSON");
      assert(state.transaction_count === 3, `esperava 3 transações, recebeu ${state.transaction_count}`);
      assert(state.revision_count === 3, `esperava 3 revisões iniciais, recebeu ${state.revision_count}`);
      assert(state.done_runs >= 1, "sync_run full deveria terminar como done");
      const cards = await sql<{ last4: string }[]>`SELECT c.last4 FROM finance.cards c JOIN finance.accounts a ON a.id=c.account_id WHERE a.pluggy_id=${creditId} ORDER BY c.last4`;
      assert(cards.map((x) => x.last4).join(",") === "1111,2222", "cartões 1111 e 2222 deveriam existir");

      const [manual] = await sql<{ id: string }[]>`
        INSERT INTO finance.transactions(source,source_key,account_id,booking_date,description,merchant_normalized,
          original_amount,signed_amount,normalization_status,status,economic_type,payload_hash)
        VALUES ('manual','integration-late-manual',(SELECT id FROM finance.accounts WHERE pluggy_id=${creditId}),
          '2026-10-05','Late purchase','late purchase',37.96,-37.96,'ready','posted','expense','integration-late-manual')
        RETURNING id`;
      transactions[creditId].push({ id: "integration-late-purchase", accountId: creditId, description: "Late purchase",
        currencyCode: "BRL", amount: 37.96, date: "2026-10-07T00:00:00Z", categoryId: "11020000",
        status: "POSTED", type: "DEBIT", createdAt: now, updatedAt: now });
      await service.refreshItem(itemId, 365, "full");
      const [reconciled] = await sql<{ is_effective: boolean; deleted_at: string | null; status: string }[]>`
        SELECT t.is_effective,t.deleted_at,r.status FROM finance.transactions_enriched t
        JOIN finance.reconciliations r ON r.manual_tx_id=t.id WHERE t.id=${manual.id}`;
      assert(reconciled?.status === "active" && !reconciled.is_effective && reconciled.deleted_at === null,
        "refreshItem must automatically reconcile a manual with a later Pluggy transaction without deleting it");
      await service.refreshItem(itemId, 365, "full");
      const [{ revisions, done_runs: doneRuns }] = await sql<{ revisions: number; done_runs: number }[]>`
        SELECT (SELECT count(*)::int FROM finance.transaction_revisions r JOIN finance.transactions t ON t.id=r.transaction_id WHERE t.pluggy_id LIKE 'integration-%') revisions,
          (SELECT count(*)::int FROM finance.sync_runs WHERE mode='full' AND status='done') done_runs`;
      assert(revisions === 4, `expected only four initial Pluggy revisions after repeated refreshes, got ${revisions}`);
      assert(doneRuns >= 2, "as duas execuções deveriam terminar como done");
    } finally {
      await sql.end();
    }
  },
});
