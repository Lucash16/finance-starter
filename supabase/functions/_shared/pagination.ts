import { PluggyClient } from "./pluggy-client.ts";
export interface Page<T> {
  results?: T[];
  next?: unknown;
}
export function nextPage(
  client: PluggyClient,
  current: string,
  next: string,
): string {
  if (!next.includes("/") && !next.includes("?")) {
    const u = client.resolveApiUrl(current);
    u.searchParams.set("cursor", next);
    return `${u.pathname}${u.search}`;
  }
  return client.resolveApiUrl(next, client.resolveApiUrl(current).toString())
    .toString();
}
export async function* paginate<T>(
  client: PluggyClient,
  initial: string,
  maxPages = 50,
): AsyncGenerator<T[]> {
  let url = initial;
  const seen = new Set<string>();
  for (let n = 0; n < maxPages; n++) {
    if (seen.has(url)) throw new Error("Loop na paginação Pluggy");
    seen.add(url);
    const page = await client.request<Page<T>>("GET", url);
    yield Array.isArray(page.results) ? page.results : [];
    if (typeof page.next !== "string" || !page.next) return;
    url = nextPage(client, url, page.next);
  }
  throw new Error(`Limite de ${maxPages} páginas atingido`);
}
