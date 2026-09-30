import { z } from "zod";
import type { SalixHttpAdapterConfigInput } from "./config";
export type SalixHttpAdapterOptions = SalixHttpAdapterConfigInput & {
  fetch?: typeof fetch;
};
export type HttpMiss = { status: "allowed-error"; httpStatus: number };
export class SalixHttpError extends Error {
  constructor(
    readonly status: number,
    method: string,
    path: string,
    body: string
  ) {
    super(`Salix HTTP ${status} ${method} ${path}: ${body}`);
  }
}
type RequestOptions = {
  method?: "GET" | "POST" | "PATCH" | "PUT" | "DELETE";
  body?: unknown;
  query?: Record<string, string | number | boolean | undefined>;
};
type ParsedRequestOptions<T> = RequestOptions & { schema: z.ZodType<T> };
type AllowedRequestOptions<T> = ParsedRequestOptions<T> & {
  allowStatuses: readonly number[];
};
type VoidRequestOptions = RequestOptions & { allowStatuses?: readonly number[] };
export class SalixClient {
  readonly tenantId?: string;
  readonly fetchImpl: typeof fetch;
  private readonly baseUrl: string;
  private readonly token?: string;
  constructor(o: SalixHttpAdapterOptions) {
    this.baseUrl = o.baseUrl.replace(/\/+$/u, "");
    this.token = o.token;
    this.tenantId = o.tenantId;
    this.fetchImpl = o.fetch ?? fetch;
  }
  async request<TValue>(
    path: string,
    options: ParsedRequestOptions<TValue>
  ): Promise<TValue>;
  async request<TValue>(
    path: string,
    options: AllowedRequestOptions<TValue>
  ): Promise<TValue | HttpMiss>;
  async request<TValue>(
    path: string,
    options: ParsedRequestOptions<TValue> | AllowedRequestOptions<TValue>
  ): Promise<TValue | HttpMiss> {
    const url = this.urlFor(path);
    for (const [key, value] of Object.entries(options.query ?? {})) {
      if (value !== undefined) {
        url.searchParams.set(key, String(value));
      }
    }

    const headers = this.headers({
      accept: "application/json",
      contentType: options.body !== undefined ? "application/json" : undefined,
    });

    const response = await this.fetchImpl(url, {
      method: options.method ?? "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });

    if ("allowStatuses" in options && options.allowStatuses.includes(response.status)) {
      return { status: "allowed-error", httpStatus: response.status };
    }

    if (!response.ok) {
      const body = await response.text();
      throw new SalixHttpError(response.status, options.method ?? "GET", path, body);
    }

    if (response.status === 204) {
      throw new Error(
        `Salix HTTP ${options.method ?? "GET"} ${path} unexpectedly returned 204`
      );
    }

    const json = await response.json();
    const parsed = options.schema.safeParse(json);
    if (!parsed.success) {
      throw new Error(
        `Salix HTTP ${options.method ?? "GET"} ${path} returned an unexpected response: ${parsed.error.message}`
      );
    }
    return parsed.data;
  }

  async requestVoid(
    path: string,
    options: VoidRequestOptions = {}
  ): Promise<void | HttpMiss> {
    const url = this.urlFor(path);
    for (const [key, value] of Object.entries(options.query ?? {})) {
      if (value !== undefined) url.searchParams.set(key, String(value));
    }
    const response = await this.fetchImpl(url, {
      method: options.method ?? "GET",
      headers: this.headers({
        accept: "application/json",
        contentType: options.body === undefined ? undefined : "application/json",
      }),
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    });
    if (options.allowStatuses?.includes(response.status)) {
      return { status: "allowed-error", httpStatus: response.status };
    }
    if (!response.ok) {
      const body = await response.text();
      throw new SalixHttpError(response.status, options.method ?? "GET", path, body);
    }
  }

  urlFor(path: string): URL {
    if (/^\/v1\/admin(?:\/|$)/u.test(path)) {
      throw new Error(`Salix Evalens adapter cannot access admin routes: ${path}`);
    }
    return new URL(`${this.baseUrl}${path}`);
  }

  headers(input: { accept?: string; contentType?: string }): Record<string, string> {
    const headers: Record<string, string> = {};
    if (input.accept) {
      headers.accept = input.accept;
    }
    if (input.contentType) {
      headers["content-type"] = input.contentType;
    }
    if (this.token) {
      headers.authorization = `Bearer ${this.token}`;
    }
    if (this.tenantId) {
      headers["x-salix-tenant-id"] = this.tenantId;
    }
    return headers;
  }
}
export function isHttpMiss(v: unknown): v is HttpMiss {
  return (
    v !== null &&
    typeof v === "object" &&
    "status" in v &&
    v.status === "allowed-error" &&
    "httpStatus" in v &&
    typeof v.httpStatus === "number"
  );
}
