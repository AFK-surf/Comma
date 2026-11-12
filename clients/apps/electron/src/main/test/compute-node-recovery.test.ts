import { expect, it, vi } from "vitest";
import { signedInSessionSnapshotSchema } from "@comma/session-contract";
import { AgentVMMCommandAdapter } from "../modules/compute-node/runtime-adapter";
import {
  ComputeNodeInstallAuthorization,
  ComputeNodeTicketNotRetryableError,
} from "../modules/compute-node/install-authorization";
import type { MainSessionHost } from "../modules/session";

it("binds recovery to the authorized workspace route and sends its Session bearer only through native stdin", async () => {
  const snapshot = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account-a", email: "account-a@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session-1",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  const acquire = vi.fn(() => ({
    token: "current-session-secret",
    audience: "https://example.test",
  }));
  const owner = new ComputeNodeInstallAuthorization(
    {
      state: () => snapshot,
      acquireProductCredential: acquire,
    } as unknown as MainSessionHost,
    () => undefined
  );
  const descriptor = owner.recoveryDescriptor({
    registrationId: "reg-1",
    workspaceId: "workspace-1",
  });
  expect(JSON.parse(descriptor)).toMatchObject({
    recovery_url:
      "https://example.test/v1/comma/workspaces/workspace-1/compute-nodes/agent-vmm/registrations/reg-1/recovery",
    registration_id: "reg-1",
  });
  expect(acquire).toHaveBeenCalledWith({
    authorityInstanceId: "main",
    generation: 1,
    expectedAudience: "https://example.test",
    expectedSessionId: "session-1",
  });
  const run = vi.fn(async () =>
    JSON.stringify({
      requestId: "original-native-request",
      correlationRequestId: "recovery-request",
      targetRegistrationId: "reg-1",
      kind: "registration-recover",
      outcome: "succeeded",
    })
  );
  const adapter = new AgentVMMCommandAdapter("/host/helper", run);
  expect(await adapter.recover("recovery-request", descriptor)).toMatchObject({
    requestId: "original-native-request",
    correlationRequestId: "recovery-request",
    targetRegistrationId: "reg-1",
  });
  const call = run.mock.calls[0] as unknown as [string, string[], string];
  expect(call[1]).toEqual([
    "registration-recover",
    "--service-type",
    "agent",
    "--request-id",
    "recovery-request",
    "--descriptor-stdin",
  ]);
  expect(JSON.parse(call[2])).toMatchObject({
    registration_id: "reg-1",
    authorization: "current-session-secret",
  });
});

it("rejects a canonical mutation receipt from another Registration", async () => {
  const adapter = new AgentVMMCommandAdapter("/host/helper", async () =>
    JSON.stringify({
      requestId: "another-request",
      targetRegistrationId: "reg-other",
      kind: "registration-recover",
      outcome: "succeeded",
    })
  );
  await expect(
    adapter.recover("request-1", '{"registration_id":"reg-1"}')
  ).rejects.toThrow("another Registration");
});

it("preserves the server's specific ticket refusal at the authorization owner boundary", async () => {
  const snapshot = signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation: 1,
    revision: 1,
    phase: "signed_in",
    principal: { userId: "account-a", email: "account-a@example.test" },
    session: {
      audience: "https://example.test",
      sessionId: "session-1",
      expiresAtEpochSeconds: 1900000000,
    },
  });
  let code = "registration_not_retryable";
  const call = vi.fn(async () => {
    throw { code, status: 409 };
  });
  const owner = new ComputeNodeInstallAuthorization(
    { state: () => snapshot } as unknown as MainSessionHost,
    () => ({ call }) as unknown as import("@comma/core-kernel/client").CoreClient
  );
  const target = { workspaceId: "workspace", registrationId: "reg-1" };
  await expect(owner.retry(target)).rejects.toBeInstanceOf(
    ComputeNodeTicketNotRetryableError
  );
  await expect(owner.inspect(target)).rejects.not.toBeInstanceOf(
    ComputeNodeTicketNotRetryableError
  );
  code = "registration_revoked";
  await expect(owner.retry(target)).rejects.not.toBeInstanceOf(
    ComputeNodeTicketNotRetryableError
  );
  expect(call).toHaveBeenCalledWith(
    "computeNode.retry",
    expect.objectContaining(target)
  );
});
