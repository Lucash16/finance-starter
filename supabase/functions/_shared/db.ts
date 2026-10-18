import postgres from "npm:postgres@3.4.7";
export type Sql = ReturnType<typeof postgres>;
let singleton: Sql | undefined;
export function db(): Sql {
  const url = Deno.env.get("SUPABASE_DB_URL");
  if (!url) throw new Error("SUPABASE_DB_URL ausente");
  return singleton ??= postgres(url, {
    prepare: false,
    max: 2,
    idle_timeout: 10,
  });
}
