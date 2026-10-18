import { PluggyClient } from "../_shared/pluggy-client.ts";
import { nextPage, paginate } from "../_shared/pagination.ts";
const assertEquals = (a: unknown, b: unknown) => {
  if (a !== b) throw new Error(`expected ${String(b)}, got ${String(a)}`);
};
const assertThrows = (fn: () => unknown) => {
  try {
    fn();
  } catch {
    return;
  }
  throw new Error("expected throw");
};
const assertRejects = async (fn: () => Promise<unknown>, part: string) => {
  try {
    await fn();
  } catch (e) {
    if (String(e).includes(part)) return;
    throw e;
  }
  throw new Error("expected rejection");
};
const client = new PluggyClient({
  clientId: "public",
  clientSecret: "test",
  fetch: () => Promise.reject(new Error("unused")),
});
Deno.test("next relativo à página atual", () =>
  assertEquals(
    nextPage(
      client,
      "/v2/transactions?accountId=a&after=one",
      "?accountId=a&after=two",
    ),
    "https://api.pluggy.ai/v2/transactions?accountId=a&after=two",
  ));
Deno.test("rejeita host externo e porta", () => {
  assertThrows(() =>
    nextPage(client, "/v2/transactions", "https://evil.example/x")
  );
  assertThrows(() =>
    nextPage(client, "/v2/transactions", "https://api.pluggy.ai:444/x")
  );
});
Deno.test("limite de páginas falha explicitamente", async () => {
  const fake = {
    request: () => Promise.resolve({ results: [], next: "cursor" }),
    resolveApiUrl: client.resolveApiUrl.bind(client),
  } as unknown as PluggyClient;
  await assertRejects(async () => {
    for await (const _ of paginate(fake, "/v2/transactions", 2)) {
      /* consume */
    }
  }, "Limite de 2");
});
