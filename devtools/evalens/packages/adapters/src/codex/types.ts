import type { JSONType } from "zod";
import type {
  CodexApprovalPolicy as CodexApprovalPolicyType,
  CodexCliAdapterConfigInput as CodexCliAdapterConfigInputType,
  CodexSandbox as CodexSandboxType,
} from "./config";

type JsonObject = Record<string, JSONType>;

export namespace Codex {
  export type InlineFileContent = string | Uint8Array | ArrayBuffer;

  export type InlineFile = {
    path: string;
    content: InlineFileContent;
  };

  export type TaskInput = {
    task: string;
    workspaceDir?: string;
    fixtureDir?: string;
    files?: InlineFile[];
    model?: string;
    verifyCommand?: string;
    metadata?: JsonObject;
  };

  export type CliEvent = JSONType;

  export type VerifyResult = {
    command: string;
    exitCode: number | null;
    signal: string | null;
    stdout: string;
    stderr: string;
    durationMs: number;
  };

  export type RunResult = {
    task: string;
    workspaceDir: string;
    finalAnswer: string;
    stdout: string;
    stderr: string;
    events: CliEvent[];
    threadId?: string;
    codexErrorMessage?: string;
    codexSessionLogPath?: string;
    exitCode: number | null;
    signal: string | null;
    durationMs: number;
    verifyResult?: VerifyResult;
    metadata?: JsonObject;
  };

  export type CliAdapterOptions = CodexCliAdapterConfigInputType;
  export type ApprovalPolicy = CodexApprovalPolicyType;
  export type Sandbox = CodexSandboxType;
  export type CliAdapterConfigInput = CodexCliAdapterConfigInputType;
}
