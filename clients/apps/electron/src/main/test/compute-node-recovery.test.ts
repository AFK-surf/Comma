import { createHash } from "node:crypto";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { signedInSessionSnapshotSchema } from "@comma/session-contract";
import { describe, expect, it, vi } from "vitest";
import { AccountComputeNodeService } from "../modules/compute-node/account-service";
import { ComputeNodeInstallAuthorization } from "../modules/compute-node/install-authorization";
import { LocalComputeOperator } from "../modules/compute-node/local-operator";

const snapshot = (userId: string, generation: number) =>
  signedInSessionSnapshotSchema.parse({
    contractVersion: 1,
    authority: { authorityInstanceId: "main", kind: "electron_main" },
    cleanup: { revocation: "idle" },
    generation,
    revision: generation,
    phase: "signed_in",
    principal: { userId, email: `${userId}@example.test` },
    session: {
      audience: "https://api.example.test",
      sessionId: `session-${generation}`,
      expiresAtEpochSeconds: 1900000000,
    },
  });
async function fixture() {
  const dir = await mkdtemp(join(tmpdir(), "comma-recovery-"));
  let sessionState = snapshot("A", 1);
  const credential = () => ({
    audience: sessionState.session.audience,
    sessionId: sessionState.session.sessionId,
    authorityInstanceId: "main",
    generation: sessionState.generation,
    signal: new AbortController().signal,
    token: `token-${sessionState.principal.userId}`,
  });
  const session = {
    state: () => sessionState,
    acquireProductCredential: credential,
    isCurrentProductCredential: (value: ReturnType<typeof credential>) =>
      value.generation === sessionState.generation,
    reportUnauthorized: async () => undefined,
  };
  const binding = {
    id: "original-operation",
    registration_id: "original-registration",
    environment_id: "original-environment",
    scope_key: "workspace",
    authorization_status: "handed_off",
    status: "ready",
    work_activity: "active",
  };
  const challenge = {
    purpose: "agent-vmm/comma-recovery/1",
    audience: "https://api.example.test",
    subject: "A",
    session_id: "session-1",
    tenant_id: "tenant",
    group_id: "group",
    scope_key: "workspace",
    environment_id: binding.environment_id,
    operation_id: binding.id,
    registration_id: binding.registration_id,
    nonce: "original-nonce",
    revision: 9,
    expires_at: Math.floor(Date.now() / 1000) + 120,
  };
  let verified = true;
  let mapped = true;
  let accepted: (() => Promise<void>) | undefined;
  const fetcher = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const path = new URL(String(input)).pathname;
    const body = init?.body
      ? (JSON.parse(String(init.body)) as { registration_ids?: string[] })
      : undefined;
    if (path.endsWith("/local-mappings"))
      return Response.json({
        mappings: [
          {
            registration_id: binding.registration_id,
            allocation_id: "allocation",
            generation: mapped ? "1" : "2",
            can_read: true,
            can_operate: false,
          },
        ],
      });
    if (path.endsWith("/local-workloads"))
      return Response.json({
        workloads: [
          { id: "private-workload-id", kind: "shell", observed_state: "ready" },
        ],
      });
    if (path.endsWith("/candidates")) {
      expect(body?.registration_ids).toEqual([binding.registration_id]);
      return Response.json({
        candidates:
          sessionState.principal.userId === "A"
            ? [
                {
                  operation_id: binding.id,
                  registration_id: binding.registration_id,
                  challenge,
                },
              ]
            : [],
      });
    }
    if (path.endsWith("/preview"))
      return Response.json(
        verified ? { operation: binding } : { error: "invalid_recovery_proof" },
        { status: verified ? 200 : 409 }
      );
    if (path.endsWith("/consume")) {
      await accepted?.();
      return Response.json({ operation: binding });
    }
    return Response.json({ operation: binding });
  });
  const run = vi.fn(async (_path: string, args: readonly string[]) => {
    if (args[0] === "local-environments")
      return JSON.stringify({
        bootId: "boot",
        collectedAt: new Date().toISOString(),
        environments: [
          {
            id: "native-environment",
            registrationId: binding.registration_id,
            allocationId: "allocation",
            allocationGeneration: "1",
            revision: "1",
            origin: "remote",
            state: "unknown",
          },
        ],
      });
    if (args[0] === "local-disk")
      return JSON.stringify({ bootId: "boot", collectedAt: new Date().toISOString() });
    if (args[0] === "local-registrations")
      return JSON.stringify({
        registrations: [{ id: binding.registration_id, revision: "8" }],
      });
    return JSON.stringify({
      identity: { deviceId: "host-root", rootPublicKey: "a2V5", rootKeyRevision: "1" },
      signature: "c2lnbmF0dXJl",
    });
  });
  const local = new LocalComputeOperator({
    lifecyclePath: "fixture-helper",
    journalDirectory: join(dir, "local"),
    run: run as never,
  });
  const runtime = {
    observe: async () => ({
      host: "ready",
      connector: "ready",
      readability: "readable",
      salix: "ready",
      registration: "present",
      registrationState: "enabled",
    }),
    install: vi.fn(),
    resume: vi.fn(),
    enable: vi.fn(),
    drain: vi.fn(),
    remove: vi.fn(),
    repair: vi.fn(),
  };
  const filePath = join(dir, "intent.json");
  const reopen = () =>
    new AccountComputeNodeService(
      {
        adapter: runtime as never,
        filePath,
        platform: "darwin",
        arch: "arm64",
        installAuthorization: new ComputeNodeInstallAuthorization(
          session as never,
          fetcher as never
        ),
      },
      sessionState,
      local
    );
  const service = reopen();
  const change = (userId: string, generation: number) => {
    sessionState = snapshot(userId, generation);
    service.sessionChanged(sessionState);
  };
  const accountFile = (subject: string) =>
    join(
      `${filePath}.accounts`,
      `${createHash("sha256")
        .update(JSON.stringify(["https://api.example.test", subject]))
        .digest("hex")}.json`
    );
  return {
    service,
    reopen,
    runtime,
    fetcher,
    filePath,
    binding,
    accountFile,
    change,
    setMapped: (value: boolean) => {
      mapped = value;
    },
    setVerified: (value: boolean) => {
      verified = value;
    },
    onAccepted: (value: () => Promise<void>) => {
      accepted = value;
    },
  };
}

describe("original compute connection recovery", () => {
  it("requires current cloud read authority and the exact registration/allocation/generation, then withdraws access on login change", async () => {
    const f = await fixture();
    const local = await f.service.localOverview({});
    expect(local.environments[0]!.canReadWorkloads).toBe(false);
    f.setMapped(false);
    const mismatch = await f.service.localOverview({ workspaceId: "workspace" });
    expect(mismatch.environments[0]!.canReadWorkloads).toBe(false);
    await expect(
      f.service.localWorkloads({ key: mismatch.environments[0]!.key })
    ).rejects.toThrow("session changed");
    f.setMapped(true);
    const matched = await f.service.localOverview({ workspaceId: "workspace" });
    expect(matched.environments[0]).toMatchObject({
      canReadWorkloads: true,
      canOperate: false,
    });
    const contents = await f.service.localWorkloads({
      key: matched.environments[0]!.key,
    });
    expect(contents.workloads).toHaveLength(1);
    expect(JSON.stringify(contents)).not.toContain("private-workload-id");
    f.change("B", 2);
    await expect(
      f.service.localWorkloads({ key: matched.environments[0]!.key })
    ).rejects.toThrow("session changed");
  });

  it("exposes only proved candidates and migrates only the matching unowned record", async () => {
    const f = await fixture();
    await writeFile(
      f.filePath,
      JSON.stringify({
        version: 3,
        workspaceId: "workspace",
        installOperationId: f.binding.id,
        registrationId: f.binding.registration_id,
      })
    );
    f.setVerified(false);
    expect(
      (await f.service.recoveryCandidates({ workspaceId: "workspace" })).candidates
    ).toEqual([]);
    f.setVerified(true);
    const page = await f.service.recoveryCandidates({ workspaceId: "workspace" });
    expect(page.candidates).toHaveLength(1);
    expect(JSON.stringify(page)).not.toMatch(
      /original-registration|rootPublicKey|signature|original-nonce/
    );
    const recovered = await f.service.recover({
      key: page.candidates[0]!.key,
      confirmationId: page.confirmationId,
    });
    expect(recovered).toMatchObject({
      status: "ready",
      bindingInstallationId: f.binding.id,
    });
    expect(JSON.parse(await readFile(f.accountFile("A"), "utf8"))).toMatchObject({
      accountOwner: { audience: "https://api.example.test", subject: "A" },
      registrationId: f.binding.registration_id,
      installAppliedOperationId: f.binding.id,
    });
    expect(await readFile(`${f.filePath}.migrated`, "utf8")).toContain(f.binding.id);
    expect(f.runtime.install).not.toHaveBeenCalled();
    expect(f.runtime.resume).not.toHaveBeenCalled();
    f.change("B", 2);
    expect(f.service.state().bindingInstallationId).toBeUndefined();
    expect(
      (await f.service.recoveryCandidates({ workspaceId: "workspace" })).candidates
    ).toEqual([]);
    await expect(
      f.service.recover({
        key: page.candidates[0]!.key,
        confirmationId: page.confirmationId,
      })
    ).rejects.toThrow("session changed");
  });

  it("queries the original accepted binding after a lost consume response and a Main restart", async () => {
    const f = await fixture();
    const page = await f.service.recoveryCandidates({ workspaceId: "workspace" });
    f.onAccepted(async () => {
      throw new TypeError("Network response lost after commit");
    });
    await expect(
      f.service.recover({
        key: page.candidates[0]!.key,
        confirmationId: page.confirmationId,
      })
    ).rejects.toThrow("Network response lost");
    expect(JSON.parse(await readFile(f.accountFile("A"), "utf8"))).toMatchObject({
      recoveryPending: {
        operationId: f.binding.id,
        registrationId: f.binding.registration_id,
      },
    });
    const consumeCalls = f.fetcher.mock.calls.filter(([url]) =>
      String(url).endsWith("/consume")
    ).length;
    const reopened = f.reopen();
    const state = await reopened.refresh();
    expect(state).toMatchObject({
      bindingInstallationId: f.binding.id,
      status: "ready",
    });
    expect(JSON.parse(await readFile(f.accountFile("A"), "utf8"))).toMatchObject({
      registrationId: f.binding.registration_id,
      installAppliedOperationId: f.binding.id,
    });
    expect(JSON.parse(await readFile(f.accountFile("A"), "utf8"))).not.toHaveProperty(
      "recoveryPending"
    );
    expect(
      f.fetcher.mock.calls.filter(([url]) => String(url).endsWith("/consume"))
    ).toHaveLength(consumeCalls);
    expect(f.runtime.install).not.toHaveBeenCalled();
    expect(f.runtime.resume).not.toHaveBeenCalled();
    expect(f.runtime.enable).not.toHaveBeenCalled();
  });

  it("saves an accepted late transfer only to its original account, without publishing or continuing under a new login", async () => {
    const f = await fixture();
    const page = await f.service.recoveryCandidates({ workspaceId: "workspace" });
    let release!: () => void, enter!: () => void;
    const entered = new Promise<void>((resolve) => {
      enter = resolve;
    });
    const paused = new Promise<void>((resolve) => {
      release = resolve;
    });
    f.onAccepted(async () => {
      enter();
      await paused;
    });
    const pending = f.service.recover({
      key: page.candidates[0]!.key,
      confirmationId: page.confirmationId,
    });
    const rejection = expect(pending).rejects.toThrow("session changed");
    await entered;
    f.change("B", 2);
    release();
    await rejection;
    expect(f.service.state().bindingInstallationId).toBeUndefined();
    expect(JSON.parse(await readFile(f.accountFile("A"), "utf8"))).toMatchObject({
      registrationId: f.binding.registration_id,
    });
    expect(f.runtime.enable).not.toHaveBeenCalled();
    f.change("A", 3);
    await f.service.refresh();
    expect(f.service.state().bindingInstallationId).toBe(f.binding.id);
    await expect(
      f.service.recover({
        key: page.candidates[0]!.key,
        confirmationId: page.confirmationId,
      })
    ).rejects.toThrow("session changed");
  });
});
