import { decode } from "cborg";
import { createHash, createPublicKey, verify } from "node:crypto";
import { afterEach, describe, expect, it } from "vitest";
import {
  HybridPasskeys,
  type CableScanListener,
  type CableScanner,
  type PageCredentialRequest,
} from "../modules/browser-sidebar/hybrid";
import { startCablePhone, type CablePhone } from "../../test-support/cable-phone";

const origin = "https://login.example.com";
const fromBase64Url = (value: string) => Buffer.from(value, "base64url");

/** The adverts nearby phones broadcast; a stranger's phone is always there. */
class Airwaves implements CableScanner {
  readonly adverts: Uint8Array[] = [Buffer.alloc(20, 0x5a)];
  readonly scanning = new Set<CableScanListener>();

  scan(listener: CableScanListener, signal: AbortSignal) {
    this.scanning.add(listener);
    signal.addEventListener("abort", () => this.scanning.delete(listener), {
      once: true,
    });
    queueMicrotask(() => {
      listener.state("on");
      for (const advert of this.adverts) listener.advert(advert);
    });
  }
}

const phones: CablePhone[] = [];
afterEach(async () => {
  await Promise.all(phones.splice(0).map((phone) => phone.close()));
});

async function setUp() {
  const phone = await startCablePhone();
  phones.push(phone);
  const air = new Airwaves();
  const passkeys = new HybridPasskeys({
    scanner: air,
    tunnelOrigin: phone.tunnelOrigin,
  });
  const states: string[] = [];
  let scanned: string | undefined;
  /** Runs a request while the user scans each QR code with the phone. */
  const run = (request: PageCredentialRequest, signal = new AbortController().signal) =>
    passkeys.run({
      origin,
      request,
      signal,
      onState: (state) => {
        states.push(state.phase === "scan" ? `scan:${state.bluetooth}` : state.phase);
        if (state.phase === "scan" && state.qr !== scanned) {
          scanned = state.qr;
          air.adverts.push(phone.scan(state.qr));
        }
      },
    });
  return { phone, air, passkeys, states, run };
}

const creation: PageCredentialRequest = {
  kind: "create",
  options: {
    challenge: "Y3JlYXRl",
    rp: { id: "example.com", name: "Example" },
    user: { id: "dXNlci0x", name: "ada@example.com" },
    pubKeyCredParams: [{ alg: -7, type: "public-key" }],
    authenticatorSelection: { residentKey: "required" },
    extensions: { credProps: true },
  },
};

describe("hybrid passkeys", () => {
  it("creates a passkey on the phone and signs in with it", async () => {
    const { phone, states, run } = await setUp();

    const created = await run(creation);
    expect(states).toEqual(["scan:pending", "scan:on", "connecting", "phone"]);
    expect(
      JSON.parse(fromBase64Url(created.response.clientDataJSON).toString())
    ).toEqual({
      type: "webauthn.create",
      challenge: "Y3JlYXRl",
      origin,
      crossOrigin: false,
    });
    const attestation = decode(fromBase64Url(created.response.attestationObject!), {
      useMaps: true,
    }) as Map<string, unknown>;
    expect(attestation.get("fmt")).toBe("none");
    expect(created.response.transports).toEqual(["hybrid", "internal"]);
    expect(created.clientExtensionResults).toEqual({ credProps: { rk: true } });
    // iPhones refuse a request without a display name.
    expect(
      (phone.commands[0]!.request.get(3) as Map<string, unknown>).get("displayName")
    ).toBe("");

    const assertion = await run({
      kind: "get",
      options: { challenge: "Z2V0", rpId: "example.com" },
    });
    expect(assertion.id).toBe(created.id);
    expect(assertion.response.userHandle).toBe("dXNlci0x");
    // The check the site's server runs with the key it stored at creation.
    const publicKey = createPublicKey({
      key: fromBase64Url(created.response.publicKey!),
      format: "der",
      type: "spki",
    });
    const signedData = Buffer.concat([
      fromBase64Url(assertion.response.authenticatorData),
      createHash("sha256")
        .update(fromBase64Url(assertion.response.clientDataJSON))
        .digest(),
    ]);
    expect(
      verify(
        "sha256",
        signedData,
        publicKey,
        fromBase64Url(assertion.response.signature!)
      )
    ).toBe(true);
  });

  it("gives the page the error a browser gives when the phone refuses", async () => {
    const { phone, run } = await setUp();

    phone.deny = 0x19;
    await expect(run(creation)).rejects.toMatchObject({ name: "InvalidStateError" });
    phone.deny = 0x27;
    await expect(run(creation)).rejects.toMatchObject({ name: "NotAllowedError" });
    // A phone that hangs up after connecting ends the request without a
    // connection failure for the dialog to show.
    phone.deny = undefined;
    phone.hangUp = true;
    await expect(run(creation)).rejects.toMatchObject({
      name: "NotAllowedError",
      reason: undefined,
    });
  });

  it("refuses a relying party that is not the page's site", async () => {
    const { states, passkeys } = await setUp();
    const run = (pageOrigin: string, rpId: string) =>
      passkeys.run({
        origin: pageOrigin,
        request: { kind: "get", options: { challenge: "Z2V0", rpId } },
        signal: new AbortController().signal,
        onState: () => {},
      });

    await expect(run(origin, "google.com")).rejects.toMatchObject({
      name: "SecurityError",
    });
    await expect(run("https://someone.github.io", "github.io")).rejects.toMatchObject({
      name: "SecurityError",
    });
    await expect(run("http://example.com", "example.com")).rejects.toMatchObject({
      name: "SecurityError",
    });
    expect(states).toEqual([]);
  });

  it("stops scanning when the page cancels while the QR code shows", async () => {
    const { air, passkeys } = await setUp();
    const cancel = new AbortController();
    const reason = new DOMException("The page cancelled the request.", "AbortError");

    const result = passkeys.run({
      origin,
      request: creation,
      signal: cancel.signal,
      onState: () => {},
    });
    await Promise.resolve();
    expect(air.scanning.size).toBe(1);
    cancel.abort(reason);

    await expect(result).rejects.toBe(reason);
    expect(air.scanning.size).toBe(0);
  });
});
