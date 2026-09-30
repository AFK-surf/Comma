import { isHttpMiss, type SalixClient } from "../client";
import { salixEnvironmentSchema, salixEnvironmentsSchema } from "../protocol";
import type { Salix } from "../types";

export class SalixConnectorEnvironmentsService {
  constructor(private readonly client: SalixClient) {}

  async list(input: Salix.EnvironmentListInput = {}): Promise<Salix.Environment[]> {
    const environments = await this.client.request("/v1/runtime/environments", {
      schema: salixEnvironmentsSchema,
    });
    return input.groupId
      ? environments.filter((environment) => environment.groupId === input.groupId)
      : environments;
  }

  async get(input: {
    groupId: string;
    deviceId: string;
  }): Promise<Salix.Environment | undefined> {
    const result = await this.client.request(
      `/v1/runtime/groups/${encodeURIComponent(input.groupId)}/environments/${encodeURIComponent(input.deviceId)}`,
      { schema: salixEnvironmentSchema, allowStatuses: [404] }
    );
    return isHttpMiss(result) ? undefined : result;
  }

  async waitForConnected(
    input: Salix.EnvironmentWaitInput
  ): Promise<Salix.Environment> {
    const timeoutMs = input.timeoutMs ?? 30_000;
    const pollMs = input.pollMs ?? 250;
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
      throw new Error("Salix environment timeoutMs must be positive");
    }
    if (!Number.isFinite(pollMs) || pollMs <= 0) {
      throw new Error("Salix environment pollMs must be positive");
    }

    const deadline = Date.now() + timeoutMs;
    let lastSeen: Salix.Environment | undefined;
    while (true) {
      lastSeen = await this.get(input);
      if (
        lastSeen?.status === "connected" &&
        (input.alias === undefined || lastSeen.alias === input.alias)
      ) {
        return lastSeen;
      }

      const remainingMs = deadline - Date.now();
      if (remainingMs <= 0) break;
      await Bun.sleep(Math.min(pollMs, remainingMs));
    }

    throw new Error(
      `Salix environment did not connect within ${timeoutMs}ms: ${JSON.stringify({
        groupId: input.groupId,
        deviceId: input.deviceId,
        alias: input.alias,
        lastStatus: lastSeen?.status,
      })}`
    );
  }

  async remove(input: { groupId: string; deviceId: string }): Promise<void> {
    await this.client.requestVoid(
      `/v1/runtime/groups/${encodeURIComponent(input.groupId)}/environments/${encodeURIComponent(input.deviceId)}`,
      { method: "DELETE", allowStatuses: [404] }
    );
  }
}
