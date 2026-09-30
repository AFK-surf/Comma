import type { SalixClient } from "../client";
import { salixConnectorTokenSchema } from "../protocol";
import type { Salix } from "../types";

export class SalixConnectorCredentialsService {
  constructor(private readonly client: SalixClient) {}

  create(input: Salix.ConnectorTokenCreateInput): Promise<Salix.ConnectorToken> {
    return this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(input.groupId)}/connector-tokens`,
      {
        method: "POST",
        schema: salixConnectorTokenSchema,
        body: {
          ...(input.name ? { name: input.name } : {}),
          ...(input.alias ? { alias: input.alias } : {}),
          ...(input.expiresInSeconds
            ? { expires_in_seconds: input.expiresInSeconds }
            : {}),
        },
      }
    );
  }
}
