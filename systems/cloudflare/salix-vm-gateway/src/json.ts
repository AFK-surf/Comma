export type JsonObject = Record<string, unknown>;

export async function readJsonObject(request: Pick<Request, "method" | "text">): Promise<JsonObject> {
  if (request.method === "GET" || request.method === "HEAD") return {};
  const text = await request.text();
  if (text.trim() === "") return {};
  const parsed = JSON.parse(text) as unknown;
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("request body must be a JSON object");
  }
  return parsed as JsonObject;
}

export function json(
  value: unknown,
  status = 200,
  headers?: HeadersInit,
): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: {
      "content-type": "application/json",
      ...headers,
    },
  });
}

export function errorJson(
  code: string,
  status: number,
  message = code,
  requestId?: string,
  headers?: HeadersInit,
): Response {
  return json(
    { ok: false, error: { code, message, request_id: requestId } },
    status,
    headers,
  );
}
