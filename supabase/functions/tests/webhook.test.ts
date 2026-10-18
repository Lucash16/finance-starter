import { createHandler } from "../pluggy-sync/handler.ts";
import { PluggyClient } from "../_shared/pluggy-client.ts";
const assertEquals = (a: unknown, b: unknown) => {
  if (a !== b) throw new Error(`expected ${String(b)}, got ${String(a)}`);
};
function setup(queued: Record<string, unknown>[] = []) {
  const calls: Array<{ q: string; p: unknown[] }> = [];
  const waits: Promise<unknown>[] = [];
  const fetchCalls: string[] = [];
  const fetchMock: typeof fetch = async (input) => {
    const u = String(input);
    fetchCalls.push(u);
    if (u.endsWith("/auth")) return Response.json({ apiKey: "key" });
    if (queued.length && u.includes("/accounts?")) {
      return Response.json({
        results: [{ id: "drain-credit", type: "CREDIT", balance: 300.00 }],
      });
    }
    return Response.json({ results: [], next: null });
  };
  const handler = createHandler({
    env: (
      k,
    ) => ({ PLUGGY_WEBHOOK_SECRET: "hook", ["FINANCE_SYNC_TOKEN"]: "job" }[k]),
    client: new PluggyClient({
      clientId: "id",
      clientSecret: "secret",
      fetch: fetchMock,
    }),
    waitUntil: (p) => waits.push(p),
    sql: {
      query: async <T>(q: string, p: unknown[] = []) => {
        calls.push({ q, p });
        return (q.startsWith("INSERT INTO finance.webhook_events")
          ? [{ id: "1" }]
          : q.includes("RETURNING event_id,payload")
          ? queued
          : []) as T[];
      },
    },
  });
  return { handler, calls, waits, fetchCalls };
}
Deno.test("webhook inválido é 401", async () => {
  const s = setup();
  assertEquals(
    (await s.handler(
      new Request("http://local", { method: "POST", body: "{}" }),
    )).status,
    401,
  );
});
Deno.test("JSON inválido é 400", async () => {
  const s = setup();
  assertEquals(
    (await s.handler(
      new Request("http://local", {
        method: "POST",
        headers: { "X-Webhook-Secret": "hook" },
        body: "{",
      }),
    )).status,
    400,
  );
});
Deno.test("created persiste, responde 202 e usa endpoint reconstruído", async () => {
  const s = setup();
  const body = {
    event: "transactions/created",
    eventId: "e1",
    itemId: "fixture-2411",
    accountId: "a1",
    transactionsCreatedAtFrom: "2026-10-07T00:00:00Z",
    createdTransactionsLink: "https://evil.example",
  };
  const r = await s.handler(
    new Request("http://local", {
      method: "POST",
      headers: { "X-Webhook-Secret": "hook" },
      body: JSON.stringify(body),
    }),
  );
  assertEquals(r.status, 202);
  await Promise.allSettled(s.waits);
  assertEquals(
    s.calls[0].q.startsWith("INSERT INTO finance.webhook_events"),
    true,
  );
  assertEquals(
    s.fetchCalls.some((x) =>
      x.includes("api.pluggy.ai/v2/transactions") && x.includes("createdAtFrom")
    ),
    true,
  );
  assertEquals(s.fetchCalls.some((x) => x.includes("evil.example")), false);
});
Deno.test("item fora da allowlist é ignored sem fetch", async () => {
  const s = setup();
  const r = await s.handler(
    new Request("http://local", {
      method: "POST",
      headers: { "X-Webhook-Secret": "hook" },
      body: JSON.stringify({
        event: "item/updated",
        eventId: "e2",
        itemId: "other",
      }),
    }),
  );
  assertEquals(r.status, 202);
  assertEquals(s.waits.length, 0);
});

Deno.test("late item/updated is queued and drain refreshes the last seven days", async () => {
  const itemId = "fixture-2411";
  const payload = { event: "item/updated", eventId: "late-update", itemId };
  const s = setup([{ event_id: payload.eventId, payload }]);
  const response = await s.handler(
    new Request("http://local", {
      method: "POST",
      headers: { "X-Webhook-Secret": "hook" },
      body: JSON.stringify(payload),
    }),
  );
  assertEquals(response.status, 202);
  assertEquals(s.calls[0].p[5], "received");
  assertEquals(s.waits.length, 0);
  assertEquals(s.fetchCalls.length, 0);

  const drain = await s.handler(
    new Request("http://local?mode=drain", {
      method: "POST",
      headers: { Authorization: "Bearer job" },
    }),
  );
  assertEquals(drain.status, 202);
  await Promise.all(s.waits);
  assertEquals(
    s.fetchCalls.some((url) => url.endsWith(`/items/${itemId}`)),
    true,
  );
  assertEquals(
    s.fetchCalls.some((url) => url.endsWith(`/accounts?itemId=${itemId}`)),
    true,
  );
  const expectedDate = new Date();
  expectedDate.setUTCDate(expectedDate.getUTCDate() - 7);
  assertEquals(
    s.fetchCalls.some((url) =>
      url.includes(
        `/v2/transactions?accountId=drain-credit&dateFrom=${
          expectedDate.toISOString().slice(0, 10)
        }`,
      )
    ),
    true,
  );
  assertEquals(
    s.calls.some(({ q }) => q === "SELECT finance.reconcile_pending()"),
    true,
  );
  assertEquals(
    s.calls.some(({ q, p }) =>
      q.startsWith("INSERT INTO finance.sync_runs") &&
      p[0] === "webhook" && p[1] === itemId &&
      p[3] === expectedDate.toISOString().slice(0, 10)
    ),
    true,
  );
  assertEquals(
    s.calls.some(({ q, p }) =>
      q.includes("processed_at=now()") &&
      p[0] === payload.eventId && p[1] === "done"
    ),
    true,
  );
});

Deno.test("item/updated without an allowed item is persisted as ignored", async () => {
  for (const itemId of [undefined, "other"]) {
    const s = setup();
    const response = await s.handler(
      new Request("http://local", {
        method: "POST",
        headers: { "X-Webhook-Secret": "hook" },
        body: JSON.stringify({
          event: "item/updated",
          eventId: "missing-item",
          itemId,
        }),
      }),
    );
    assertEquals(response.status, 202);
    assertEquals(s.calls[0].p[5], "ignored");
    assertEquals(s.waits.length, 0);
    assertEquals(s.fetchCalls.length, 0);
  }
});

function updateSetup(
  statuses: string[],
  responseMs = 1000,
  totalMs = 1000,
  patchError?: { status: number; body: unknown },
) {
  const requests: Array<{ url: string; method: string; body: unknown }> = [];
  const waits: Promise<unknown>[] = [];
  const sqlCalls: unknown[][] = [];
  const polls = new Map<string, number>();
  const handler = createHandler({
    env: (key) => key === "FINANCE_SYNC_TOKEN" ? "job" : undefined,
    updateTiming: { responseMs, totalMs, pollMs: 1 },
    waitUntil: (task) => waits.push(task),
    sql: {
      query: async <T>(_q: string, params: unknown[] = []) => {
        sqlCalls.push(params);
        return [] as T[];
      },
    },
    client: new PluggyClient({
      clientId: "id",
      clientSecret: "secret",
      fetch: async (input, init) => {
        const url = String(input), method = init?.method ?? "GET";
        requests.push({ url, method, body: init?.body });
        if (url.endsWith("/auth")) return Response.json({ apiKey: "key" });
        if (url.includes("/items/")) {
          if (method === "PATCH") {
            return patchError
              ? Response.json(patchError.body, { status: patchError.status })
              : Response.json({ status: "UPDATING" });
          }
          const count = polls.get(url) ?? 0;
          polls.set(url, count + 1);
          return Response.json({
            status: statuses[Math.min(count, statuses.length - 1)],
          });
        }
        if (url.includes("/accounts?")) {
          return Response.json({ results: [{ id: "credit", type: "CREDIT" }] });
        }
        return Response.json({ results: [], next: null });
      },
    }),
  });
  const request = () =>
    handler(
      new Request("http://local?mode=update", {
        method: "POST",
        headers: { Authorization: "Bearer job" },
      }),
    );
  return { handler, request, requests, waits, sqlCalls };
}

Deno.test("manual update requires Bearer auth before any PATCH", async () => {
  const s = updateSetup(["UPDATED"]);
  const response = await s.handler(
    new Request("http://local?mode=update", { method: "POST" }),
  );
  assertEquals(response.status, 401);
  assertEquals(s.requests.length, 0);
});

Deno.test("manual update PATCHes both allowed items then polls and syncs seven days", async () => {
  const s = updateSetup(["UPDATING", "UPDATED"]);
  const response = await s.request();
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.ok, true);
  assertEquals(body.mode, "update");
  assertEquals(typeof body.finishedAt, "string");
  for (const item of body.items) {
    assertEquals(item.syncStatus, "done");
    assertEquals(
      s.requests.some((r) =>
        r.url.endsWith(`/items/${item.itemId}`) && r.method === "PATCH" &&
        r.body === "{}"
      ),
      true,
    );
    assertEquals(
      s.requests.some((r) => r.url.endsWith(`/accounts?itemId=${item.itemId}`)),
      true,
    );
  }
  assertEquals(s.requests.filter((r) => r.method === "PATCH").length, 2);
  assertEquals(
    s.requests.some((r) =>
      r.url.includes("/v2/transactions?") && r.url.includes("dateFrom=")
    ),
    true,
  );
  assertEquals(s.requests.some((r) => r.url.includes("/bills?")), true);
  assertEquals(s.sqlCalls.some((p) => p[0] === "backfill"), true);
});

Deno.test("manual update syncs immediately UPDATED items", async () => {
  const s = updateSetup(["UPDATED"]);
  const body = await (await s.request()).json();
  assertEquals(body.ok, true);
  for (const item of body.items) {
    assertEquals(item.pluggyStatus, "UPDATED");
    assertEquals(item.syncStatus, "done");
  }
});

Deno.test("manual update stops MFA and errors without syncing or exposing payloads", async () => {
  for (
    const status of [
      "WAITING_USER_INPUT",
      "WAITING_USER_ACTION",
      "LOGIN_ERROR",
      "ERROR",
    ]
  ) {
    const s = updateSetup([status]);
    const response = await s.request();
    assertEquals(response.status, 200);
    const body = await response.json();
    assertEquals(body.ok, false);
    assertEquals(body.items[0].syncStatus, "skipped");
    for (const item of body.items) {
      assertEquals(item.message.includes(item.institution), false);
    }
    if (status === "WAITING_USER_INPUT") {
      assertEquals(body.items[0].message.includes("confirmação no app"), true);
    }
    assertEquals(s.requests.some((r) => r.url.includes("/accounts?")), false);
  }
});

Deno.test("manual update syncs available MeuPluggy data after unsupported PATCH", async () => {
  const s = updateSetup(["OUTDATED"], 1000, 1000, {
    status: 400,
    body: { message: "MeuPluggy item cant be updated" },
  });
  const response = await s.request();
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.ok, true);
  for (const item of body.items) {
    assertEquals(item.syncStatus, "done");
    assertEquals(item.pluggyStatus, "OUTDATED");
    assertEquals(
      item.message,
      "Pluggy não permite forçar atualização deste conector; sincronizando os dados já disponíveis.",
    );
    assertEquals(
      s.requests.some((r) => r.url.endsWith(`/accounts?itemId=${item.itemId}`)),
      true,
    );
  }
  assertEquals(
    s.requests.filter((r) =>
      r.url.includes("/v2/transactions?") && r.url.includes("dateFrom=")
    ).length,
    2,
  );
  assertEquals(s.sqlCalls.some((p) => p[0] === "backfill"), true);
});

Deno.test("manual update skips PATCH MFA errors including codeDescription before fallback", async () => {
  for (
    const error of [
      {
        message: "MeuPluggy item cant be updated",
        codeDescription: "MFA required",
      },
      { code: "WAITING_USER_INPUT" },
      { message: "Required parameter missing" },
      { codeDescription: "LOGIN_ERROR" },
    ]
  ) {
    const s = updateSetup(["UPDATED"], 1000, 1000, {
      status: 400,
      body: error,
    });
    const body = await (await s.request()).json();
    for (const item of body.items) {
      assertEquals(item.syncStatus, "skipped");
      assertEquals(item.message.includes(item.institution), false);
      assertEquals(
        item.message.includes(
          error.codeDescription === "LOGIN_ERROR"
            ? "credenciais"
            : "confirmação no app",
        ),
        true,
      );
    }
    assertEquals(s.requests.some((r) => r.method === "GET"), false);
  }
});

Deno.test("manual update recognizes unsupported error codes and respects subsequent MFA status", async () => {
  for (const status of ["UPDATED", "WAITING_USER_ACTION"]) {
    const s = updateSetup([status], 1000, 1000, {
      status: 400,
      body: { code: "ITEM_CANNOT_BE_UPDATED" },
    });
    const body = await (await s.request()).json();
    for (const item of body.items) {
      assertEquals(item.pluggyStatus, status);
      assertEquals(item.syncStatus, status === "UPDATED" ? "done" : "skipped");
    }
    assertEquals(
      s.requests.some((r) => r.url.includes("/accounts?")),
      status === "UPDATED",
    );
  }
});

Deno.test("manual update reports sanitized PATCH errors without syncing", async () => {
  for (const status of [400, 403]) {
    const s = updateSetup(["UPDATED"], 1000, 1000, {
      status,
      body: {
        message: "Invalid request secret key\n",
        code: "INVALID_REQUEST",
      },
    });
    const body = await (await s.request()).json();
    for (const item of body.items) {
      assertEquals(item.syncStatus, "failed");
      assertEquals(item.message.includes(item.institution), false);
      assertEquals(item.message.includes(`HTTP ${status}`), true);
      assertEquals(item.message.includes("Invalid request"), true);
      assertEquals(item.message.includes("secret"), false);
      assertEquals(item.message.includes("key"), false);
      assertEquals(item.message.includes("\n"), false);
    }
    assertEquals(s.requests.some((r) => r.url.includes("/accounts?")), false);
  }
});

Deno.test("manual update reports repeated PATCH HTTP 429 without leaking secrets", async () => {
  const s = updateSetup(["UPDATED"], 5000, 5000, {
    status: 429,
    body: { message: "secret key\n", code: "RATE_LIMIT" },
  });
  const response = await s.request();
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.ok, false);
  for (const item of body.items) {
    assertEquals(item.syncStatus, "failed");
    assertEquals(item.message.includes("HTTP 429"), true);
    assertEquals(item.message.includes(item.institution), false);
    assertEquals(item.message.includes("secret"), false);
    assertEquals(item.message.includes("key"), false);
    assertEquals(item.message.includes("\n"), false);
    assertEquals(
      s.requests.filter((r) =>
        r.method === "PATCH" && r.url.endsWith(`/items/${item.itemId}`)
      ).length,
      2,
    );
  }
  assertEquals(s.requests.some((r) => r.method === "GET"), false);
});

Deno.test("manual update returns 202 and finishes remaining polling via waitUntil", async () => {
  const s = updateSetup(["UPDATING", "UPDATED"], 0);
  const response = await s.request();
  assertEquals(response.status, 202);
  assertEquals((await response.json()).accepted, true);
  await Promise.all(s.waits);
  assertEquals(
    s.requests.filter((r) => r.url.includes("/accounts?")).length,
    2,
  );
});

Deno.test("manual update polling has a finite deadline", async () => {
  const s = updateSetup(["UPDATING"], 1000, 5);
  const response = await s.request();
  assertEquals(response.status, 200);
  const body = await response.json();
  assertEquals(body.items[0].syncStatus, "skipped");
  assertEquals(body.items[0].message.includes("limite"), true);
  for (const item of body.items) {
    assertEquals(item.message.includes(item.institution), false);
  }
  assertEquals(s.requests.some((r) => r.url.includes("/accounts?")), false);
});
