// One Durable Object per signature nonce (same as salix-vm-gateway). The first
// claim wins; the record expires after 10 minutes, longer than the 5-minute
// timestamp window, so a replayed request fails either here or on its timestamp.
export class ReplayGuard implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    if (request.method !== "POST" || new URL(request.url).pathname !== "/internal/claim") {
      return new Response("not found", { status: 404 });
    }
    const body = (await request.json().catch(() => ({}))) as { nonce?: string; timestamp?: string };
    if (!body.nonce || !body.timestamp) return new Response("bad request", { status: 400 });

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
