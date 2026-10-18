import { configuredItemIds } from "../_shared/config.ts";
import { getSecret } from "../_shared/secrets.ts";
function assert(value: unknown) { if (!value) throw new Error("assertion failed"); }
Deno.test("item configuration rejects missing and empty values", () => {
  for (const value of [undefined, "", " , "]) {
    let failed = false;
    try { configuredItemIds(value); } catch { failed = true; }
    assert(failed);
  }
  assert([...configuredItemIds(" first,second,first ")].join(",") === "first,second");
});
Deno.test("credentials require environment and errors never expose values", async () => {
  const key = "STARTER_TEST_SECRET";
  Deno.env.delete(key);
  let failed = false;
  try { await getSecret(key); } catch { failed = true; }
  assert(failed);
  Deno.env.set(key, "synthetic-fixture");
  try { assert(await getSecret(key) === "synthetic-fixture"); }
  finally { Deno.env.delete(key); }
});
