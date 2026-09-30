import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { app } from "electron";
import type { ConnectorConfig } from "@comma/native-bridge";
import { z } from "zod";

export interface SalixConnectorFileConfig {
  comma?: {
    api_base_url: string;
    session_token: string;
    workspace_id: string;
  };
  connector: {
    server?: string;
    connector_token?: string;
    name: string;
    alias?: string;
    root: string;
    env_id?: string;
    reconnect: boolean;
  };
  electron?: {
    connector_binary_sha256?: string | undefined;
    local_file_index_root?: string | undefined;
    runtime_namespace?: string | undefined;
    runtime_root?: string | undefined;
  };
}

const emptyStringToUndefined = (value: unknown) =>
  typeof value === "string" && value.trim() === "" ? undefined : value;

const optionalTrimmedString = z.preprocess(
  emptyStringToUndefined,
  z.string().trim().optional()
);

const absentConnectorField = z.preprocess(
  emptyStringToUndefined,
  z.undefined().optional()
);

const connectorConfigCommonSchema = {
  name: optionalTrimmedString,
  alias: optionalTrimmedString,
  root: optionalTrimmedString,
  envId: optionalTrimmedString,
  reconnect: z.boolean().optional(),
};

const managedConnectorConfigSchema = z.object({
  ...connectorConfigCommonSchema,
  server: optionalTrimmedString,
  token: optionalTrimmedString,
  commaApiBaseUrl: z.string().trim().min(1),
  commaSessionToken: z.string().trim().min(1),
  workspaceId: z.string().trim().min(1),
});

const staticConnectorConfigSchema = z.object({
  ...connectorConfigCommonSchema,
  server: z.string().trim().min(1),
  token: z.string().trim().min(1),
  commaApiBaseUrl: absentConnectorField,
  commaSessionToken: absentConnectorField,
  workspaceId: absentConnectorField,
});

const connectorConfigSchema = z
  .union([managedConnectorConfigSchema, staticConnectorConfigSchema])
  .transform((parsed): SalixConnectorFileConfig => {
    const connector: SalixConnectorFileConfig["connector"] = {
      name: parsed.name || app.getName(),
      root: parsed.root || app.getPath("home"),
      reconnect: parsed.reconnect ?? true,
    };
    if (parsed.server) {
      connector.server = parsed.server;
    }
    if (parsed.token) {
      connector.connector_token = parsed.token;
    }
    if (parsed.alias) {
      connector.alias = parsed.alias;
    }
    if (parsed.envId) {
      connector.env_id = parsed.envId;
    }

    return {
      ...(parsed.commaApiBaseUrl
        ? {
            comma: {
              api_base_url: parsed.commaApiBaseUrl,
              session_token: parsed.commaSessionToken,
              workspace_id: parsed.workspaceId,
            },
          }
        : {}),
      connector,
    };
  });

const connectorFileCommonSchema = {
  connector: z.object({
    name: z.string().trim().min(1, "Connector config name is required."),
    alias: optionalTrimmedString,
    root: z.string().trim().min(1, "Connector config root is required."),
    env_id: optionalTrimmedString,
    reconnect: z.boolean().optional().default(true),
  }),
  electron: z
    .object({
      connector_binary_sha256: z.string().trim().min(1).optional(),
      local_file_index_root: z.string().trim().min(1).optional(),
      runtime_namespace: z.string().trim().min(1).optional(),
      runtime_root: z.string().trim().min(1).optional(),
    })
    .optional(),
};

const managedConnectorFileSchema = z.object({
  ...connectorFileCommonSchema,
  comma: z.object({
    api_base_url: z.string().trim().min(1),
    session_token: z.string().trim().min(1),
    workspace_id: z.string().trim().min(1),
  }),
  connector: connectorFileCommonSchema.connector.extend({
    server: optionalTrimmedString,
    connector_token: optionalTrimmedString,
  }),
});

const staticConnectorFileSchema = z.object({
  ...connectorFileCommonSchema,
  comma: z.undefined().optional(),
  connector: connectorFileCommonSchema.connector.extend({
    server: z.string().trim().min(1),
    connector_token: z.string().trim().min(1),
  }),
});

const connectorFileSchema = z.union([
  managedConnectorFileSchema,
  staticConnectorFileSchema,
]);

export function connectorConfigPath() {
  return join(app.getPath("userData"), "connector.json");
}

export function localFileIndexRoot(path = connectorConfigPath()) {
  return join(dirname(path), "local-file-index");
}

function electronRuntimeMetadata() {
  return {
    runtime_root: app.getPath("userData"),
  };
}

export async function readConnectorConfig(path = connectorConfigPath()) {
  const data = await readFile(path, "utf8");
  const parsed = JSON.parse(data) as unknown;
  const config = validateConnectorFileConfig(parsed);
  if (config.electron?.local_file_index_root) return config;

  const migrated = {
    ...config,
    electron: {
      ...config.electron,
      ...electronRuntimeMetadata(),
      local_file_index_root: localFileIndexRoot(path),
    },
  } satisfies SalixConnectorFileConfig;
  await writeConnectorFileConfig(migrated, path);
  return migrated;
}

export async function writeConnectorConfig(
  config: ConnectorConfig,
  path = connectorConfigPath(),
  metadata?: SalixConnectorFileConfig["electron"]
) {
  const normalized = connectorConfigSchema.parse(config);
  if (metadata) {
    normalized.electron = {
      ...metadata,
      ...electronRuntimeMetadata(),
      local_file_index_root: localFileIndexRoot(path),
    };
  } else {
    normalized.electron = {
      ...electronRuntimeMetadata(),
      local_file_index_root: localFileIndexRoot(path),
    };
  }
  return writeConnectorFileConfig(normalized, path);
}

export async function writeConnectorFileConfig(
  config: SalixConnectorFileConfig,
  path = connectorConfigPath()
) {
  await mkdir(dirname(path), { recursive: true });

  const tmpPath = `${path}.${process.pid}.tmp`;
  await writeFile(`${tmpPath}`, `${JSON.stringify(config, null, 2)}\n`, {
    mode: 0o600,
  });
  await chmod(tmpPath, 0o600).catch(() => {});
  await rename(tmpPath, path);
  await chmod(path, 0o600).catch(() => {});

  return config;
}

function validateConnectorFileConfig(value: unknown): SalixConnectorFileConfig {
  const parsed = connectorFileSchema.parse(value);

  return {
    ...(parsed.comma ? { comma: parsed.comma } : {}),
    connector: {
      ...(parsed.connector.server ? { server: parsed.connector.server } : {}),
      ...(parsed.connector.connector_token
        ? { connector_token: parsed.connector.connector_token }
        : {}),
      name: parsed.connector.name,
      ...(parsed.connector.alias ? { alias: parsed.connector.alias } : {}),
      root: parsed.connector.root,
      ...(parsed.connector.env_id ? { env_id: parsed.connector.env_id } : {}),
      reconnect: parsed.connector.reconnect,
    },
    ...(parsed.electron ? { electron: parsed.electron } : {}),
  };
}
