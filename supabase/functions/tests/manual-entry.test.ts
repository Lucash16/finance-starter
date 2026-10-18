import { createManualHandler } from "../manual-entry/index.ts";
import type { Sql } from "../_shared/db.ts";
const assert = (value: unknown) => { if (!value) throw new Error("assertion failed"); };
Deno.test("manual entry rejects unauthenticated and malformed requests before SQL", async () => {
  let calls = 0;
  const sql = (async () => { calls++; return [{ result: { id: "synthetic-entry", reconciliation_status: "unmatched" } }]; }) as unknown as Sql;
  const handler = createManualHandler({ sql, secret: async () => "synthetic-auth" });
  assert((await handler(new Request("http://local", {method:"GET"}))).status === 405);
  assert((await handler(new Request("http://local", {method:"POST"}))).status === 401);
  const headers = {Authorization:"Bearer synthetic-auth", "Content-Type":"application/json"};
  assert((await handler(new Request("http://local", {method:"POST",headers,body:"invalid"}))).status === 400);
  assert((await handler(new Request("http://local", {method:"POST",headers,body:"{}"}))).status === 400);
  for (const body of ["null", "[]", "42"]) assert((await handler(new Request("http://local", {method:"POST",headers,body}))).status === 400);
  assert(calls === 0);
  const response = await handler(new Request("http://local", {method:"POST",headers,body:JSON.stringify({request_id:"synthetic-request",payload:{kind:"expense",amount:10,description:"Compra exemplo"}})}));
  assert(response.status === 201 && calls === 1);
  assert(!(await response.text()).includes("synthetic-auth"));
});
