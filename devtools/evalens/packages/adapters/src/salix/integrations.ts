import type { DeepReadonly } from "@evalens/core/adapter";
import type { SalixClient } from "./client";
import { salixIntegrationMaterializationReceiptSchema } from "./protocol";
import type { Salix } from "./types";

type IntegrationSelector = {
  id?: string;
  provider?: string;
};
type ConfiguredIntegration = DeepReadonly<Salix.IntegrationConfig>;

export class SalixIntegrationsService {
  constructor(
    private readonly client: SalixClient,
    private readonly configuredIntegrations: readonly ConfiguredIntegration[] = []
  ) {}

  requireFixture(selector: IntegrationSelector): ConfiguredIntegration {
    const matches = this.configuredIntegrations.filter(
      (integration) =>
        (selector.id === undefined || integration.id === selector.id) &&
        (selector.provider === undefined ||
          integration.provider === selector.provider.toLowerCase())
    );
    if (matches.length === 0) {
      throw new Error(`missing Salix integration config: ${selectorLabel(selector)}`);
    }
    if (matches.length > 1) {
      throw new Error(
        `ambiguous Salix integration config: ${selectorLabel(selector)} matched ${matches
          .map((integration) => integration.id)
          .join(", ")}`
      );
    }
    return matches[0]!;
  }

  async materializeFixture(input: {
    run: Salix.PreparedRun;
    integration: ConfiguredIntegration;
    inboundAgentId?: string;
  }): Promise<Salix.IntegrationMaterializationReceipt> {
    const body = materializationBody(input.integration, input.inboundAgentId);
    if (input.integration.credentials.type === "app") {
      input.run.cleanupPlan.imConnectDiscoveryGroupIds ??= [];
      if (
        !input.run.cleanupPlan.imConnectDiscoveryGroupIds.includes(input.run.groupId)
      ) {
        input.run.cleanupPlan.imConnectDiscoveryGroupIds.push(input.run.groupId);
      }
    }
    const materialized = await this.client.request(
      `/v1/runtime/agent-groups/${encodeURIComponent(input.run.groupId)}/eval/integration-materializations`,
      {
        method: "POST",
        schema: salixIntegrationMaterializationReceiptSchema,
        body,
      }
    );

    if (materialized.materializationKind === "im_connect") {
      input.run.cleanupPlan.imConnects ??= [];
      if (
        !input.run.cleanupPlan.imConnects.some(
          (candidate) => candidate.connectId === materialized.imConnect.connectId
        )
      ) {
        input.run.cleanupPlan.imConnects.push({
          groupId: input.run.groupId,
          connectId: materialized.imConnect.connectId,
        });
      }
    }
    return materialized;
  }
}

function materializationBody(
  integration: ConfiguredIntegration,
  inboundAgentId?: string
) {
  const common = {
    integration_id: integration.id,
    provider: integration.provider,
  };
  if (isAppIntegration(integration)) {
    if (!inboundAgentId) {
      throw new Error(
        `inboundAgentId is required for IM integration ${integration.id}`
      );
    }
    return {
      ...common,
      inbound_agent_id: inboundAgentId,
      credentials: {
        type: "app",
        app_id: integration.credentials.appId,
        client_id: integration.credentials.clientId,
        client_secret: integration.credentials.clientSecret,
        signing_secret: integration.credentials.signingSecret,
        bot_token: integration.credentials.botToken,
        app_name: integration.credentials.appName,
      },
    };
  }

  return {
    ...common,
    alias: integration.alias,
    scopes: integration.scopes,
    credentials: {
      type: "oauth",
      access_token: integration.credentials.accessToken,
      refresh_token: integration.credentials.refreshToken,
      expires_at: integration.credentials.expiresAt,
      refresh_expires_at: integration.credentials.refreshExpiresAt,
      token_type: integration.credentials.tokenType,
    },
    account: integration.account
      ? {
          provider_account_id: integration.account.id,
          provider_account_name: integration.account.name,
        }
      : undefined,
    plugin: integration.plugin
      ? {
          plugin_id: integration.plugin.pluginId,
          connection_id: integration.plugin.connectionId,
        }
      : undefined,
    ...(integration.providerKey ? { provider_key: integration.providerKey } : {}),
  };
}

function isAppIntegration(
  integration: ConfiguredIntegration
): integration is DeepReadonly<Salix.AppIntegrationConfig> {
  return integration.credentials.type === "app";
}

function selectorLabel(selector: IntegrationSelector): string {
  return [selector.id, selector.provider]
    .filter((value): value is string => Boolean(value))
    .join("/");
}
