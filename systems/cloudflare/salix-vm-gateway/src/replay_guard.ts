export class ReplayGuard implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const body = (await request.json().catch(() => ({}))) as {
      nonce?: string;
      timestamp?: string;
    };
    if (
      request.method !== "POST" ||
      new URL(request.url).pathname !== "/internal/claim"
    ) {
      return new Response("not found", { status: 404 });
    }
    if (!body.nonce || !body.timestamp) {
      return new Response("bad request", { status: 400 });
    }

    const existing = await this.state.storage.get<string>("nonce");
    if (existing) return new Response("replay", { status: 409 });

    await this.state.storage.put("nonce", body.nonce);
    await this.state.storage.setAlarm(Date.now() + 10 * 60 * 1000);
    return new Response("ok");
  }

  async alarm(): Promise<void> {
    await this.state.storage.deleteAll();
  }
}
