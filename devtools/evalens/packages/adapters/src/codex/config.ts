import { z } from "zod";

import { CodexAdapterConfigSchema } from "../config";

export const CodexSandbox = z.enum([
  "read-only",
  "workspace-write",
  "danger-full-access",
]);
export const CodexApprovalPolicy = z.enum([
  "never",
  "on-request",
  "on-failure",
  "untrusted",
]);
export const CodexCliAdapterConfig = CodexAdapterConfigSchema.extend({
  model: z.string().min(1).optional(),
  ephemeral: z.boolean().default(true),
  configOverrides: z.array(z.string().min(1)).default([]),
  extraArgs: z.array(z.string().min(1)).default([]),
}).strict();

export type CodexSandbox = z.infer<typeof CodexSandbox>;
export type CodexApprovalPolicy = z.infer<typeof CodexApprovalPolicy>;
export type CodexCliAdapterConfig = z.infer<typeof CodexCliAdapterConfig>;
export type CodexCliAdapterConfigInput = z.input<typeof CodexCliAdapterConfig>;
