export interface PluggyClientOptions {
  clientId: string;
  clientSecret: string | (() => Promise<string>);
  fetch?: typeof fetch;
  baseUrl?: string;
  timeoutMs?: number;
  now?: () => number;
}
export class PluggyError extends Error {
  constructor(message: string, readonly status?: number) {
    super(message);
    this.name = "PluggyError";
  }
}
export class PluggyClient {
  private fetchImpl: typeof fetch;
  private baseUrl: URL;
  private timeoutMs: number;
  private now: () => number;
  private apiKey?: string;
  private clientSecret?: string;
  private expires = 0;
  private authPromise?: Promise<string>;
  constructor(private options: PluggyClientOptions) {
    this.fetchImpl = options.fetch ?? fetch;
    this.baseUrl = new URL(options.baseUrl ?? "https://api.pluggy.ai/");
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.now = options.now ?? Date.now;
  }
  resolveApiUrl(path: string, current?: string): URL {
    const base = current ? new URL(current, this.baseUrl) : this.baseUrl;
    const u = new URL(path, base);
    if (
      u.protocol !== "https:" || u.hostname !== "api.pluggy.ai" || u.port ||
      u.username || u.password
    ) throw new PluggyError("URL Pluggy não permitida");
    return u;
  }
  async request<T>(
    method: string,
    path: string,
    body?: unknown,
    retried = false,
  ): Promise<T> {
    const url = this.resolveApiUrl(path);
    const key = await this.getKey(false);
    let response: Response;
    try {
      response = await this.fetchImpl(url, {
        method,
        redirect: "manual",
        headers: {
          "X-API-KEY": key,
          "Accept": "application/json",
          ...(body === undefined ? {} : { "Content-Type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      throw this.safe("Falha ao conectar à API Pluggy", e);
    }
    if (response.status === 401 && !retried) {
      await this.getKey(true);
      return this.request(method, path, body, true);
    }
    if ([429, 500, 502, 503, 504].includes(response.status)) {
      const retry = Math.min(
        Number(response.headers.get("retry-after") ?? 0) * 1000 || 500,
        5000,
      );
      await new Promise((r) => setTimeout(r, retry + Math.random() * 200));
      if (!retried) return this.request(method, path, body, true);
    }
    if (!response.ok) {
      const detail = await response.json().catch(() => null);
      const message = [detail?.message, detail?.code, detail?.codeDescription]
        .filter((value) => typeof value === "string").join("; ");
      throw new PluggyError(
        this.safe(`API Pluggy retornou HTTP ${response.status}`, message)
          .message,
        response.status,
      );
    }
    if (response.status === 204) return undefined as T;
    try {
      return await response.json() as T;
    } catch {
      throw new PluggyError(
        "Resposta JSON inválida da API Pluggy",
        response.status,
      );
    }
  }
  private async getKey(force: boolean) {
    if (!force && this.apiKey && this.now() < this.expires - 300_000) {
      return this.apiKey;
    }
    if (this.authPromise) return this.authPromise;
    this.authPromise = this.authenticate();
    try {
      return await this.authPromise;
    } finally {
      this.authPromise = undefined;
    }
  }
  private async authenticate() {
    const clientSecret = typeof this.options.clientSecret === "function"
      ? await this.options.clientSecret()
      : this.options.clientSecret;
    this.clientSecret = clientSecret;
    let r: Response;
    try {
      r = await this.fetchImpl(this.resolveApiUrl("/auth"), {
        method: "POST",
        redirect: "manual",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({
          clientId: this.options.clientId,
          clientSecret,
        }),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      throw this.safe("Falha ao autenticar", e);
    }
    if (!r.ok) {
      throw new PluggyError(
        `Autenticação Pluggy retornou HTTP ${r.status}`,
        r.status,
      );
    }
    const d = await r.json() as { apiKey?: unknown };
    if (typeof d.apiKey !== "string" || !d.apiKey) {
      throw new PluggyError("Autenticação sem apiKey");
    }
    this.apiKey = d.apiKey;
    this.expires = this.now() + 7_200_000;
    return d.apiKey;
  }
  private safe(prefix: string, e: unknown) {
    let raw = e instanceof Error ? e.message : String(e);
    for (
      const secret of [
        this.apiKey,
        this.clientSecret ??
          (typeof this.options.clientSecret === "string"
            ? this.options.clientSecret
            : undefined),
      ]
    ) {
      if (secret) raw = raw.split(secret).join("[REDACTED]");
    }
    raw = raw.replace(/[\r\n\t]+/g, " ").slice(0, 240);
    return new PluggyError(
      raw ? `${prefix}: ${raw}` : prefix,
    );
  }
}
