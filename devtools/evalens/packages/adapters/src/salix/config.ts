import { z } from "zod";

import type { DeepReadonly } from "@evalens/core/adapter";

import {
  SalixAdapterConfigSchema,
  type SalixAdapterConfig,
  type SalixIntegrationConfig,
} from "../config";

export const SalixHttpAdapterConfig = SalixAdapterConfigSchema.strict();

export type SalixHttpAdapterConfig = z.infer<typeof SalixHttpAdapterConfig>;
export type SalixHttpAdapterConfigInput = Omit<
  SalixAdapterConfig,
  "integrations" | "tenantId"
> & {
  tenantId?: string;
  integrations?: readonly DeepReadonly<SalixIntegrationConfig>[];
};
