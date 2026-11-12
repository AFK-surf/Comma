import { expect, it, vi } from "vitest";
import { AgentVMMCommandAdapter } from "../modules/compute-node/runtime-adapter";

it("submits typed actions directly and reads any accepted request through the native owner", async () => {
  const run = vi.fn(async (_file: string, args: string[]) =>
    ["operation", "registration-claim"].includes(args[0]!)
      ? JSON.stringify({
          requestId: "request-1",
          targetRegistrationId: "registration-1",
          kind: "registration-claim",
          outcome: "failed",
          retryable: true,
        })
      : "{}"
  );
  const adapter = new AgentVMMCommandAdapter("/host/helper", run);
  await adapter.install("request-1", '{"registration_id":"registration-1"}');
  expect(run.mock.calls[0]?.[1]).toEqual([
    "registration-claim",
    "--service-type",
    "agent",
    "--request-id",
    "request-1",
    "--descriptor-stdin",
  ]);
  expect(await adapter.receipt("request-1")).toMatchObject({
    outcome: "failed",
    retryable: true,
  });
  await adapter.remove("request-2", "registration-1");
  expect(run.mock.calls.at(-1)?.[1]?.[0]).toBe("registration-remove");
});

it("consumes the exact enable receipt and rejects a different accepted action", async () => {
  let kind = "registration-enable";
  const run = vi.fn(async () =>
    JSON.stringify({
      requestId: "enable-request",
      targetRegistrationId: "registration-1",
      kind,
      outcome: "pending",
    })
  );
  const adapter = new AgentVMMCommandAdapter("/host/helper", run);
  expect(await adapter.enable("enable-request", "registration-1")).toMatchObject({
    requestId: "enable-request",
    kind: "registration-enable",
    outcome: "pending",
  });
  kind = "registration-claim";
  await expect(adapter.enable("enable-request", "registration-1")).rejects.toThrow(
    "another action"
  );
});
