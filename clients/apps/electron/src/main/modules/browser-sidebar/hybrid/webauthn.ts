/**
 * The WebAuthn client steps that Chromium runs for a hybrid request: check the
 * relying party against the page origin, build clientDataJSON, translate the
 * options into one CTAP command, and turn the phone's reply into the result
 * the page receives. Main runs them; the page supplies only its options.
 */
import { createHash, createPublicKey } from "node:crypto";
import { getDomain } from "tldts";
import { z } from "zod";
import { decodeCbor, decodeFirstCbor, encodeCbor } from "./cable";

type Base64Url = string;

// The page sends its options as JSON with every buffer as base64url. The
// bounds keep a hostile page from making Main hold or encode large values.
const base64Url = (maxBytes: number, minBytes = 0) =>
  z
    .string()
    .regex(/^[A-Za-z0-9_-]*$/u)
    .min(Math.ceil((minBytes * 4) / 3))
    .max(Math.ceil((maxBytes * 4) / 3));
const entityName = z.string().max(1024);
const descriptorSchema = z.object({
  id: base64Url(1023, 1),
  transports: z.array(z.string().max(32)).max(8).optional(),
});

export const pageCredentialRequestSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("create"),
    options: z.object({
      challenge: base64Url(1024, 1),
      rp: z.object({ id: z.string().max(253).optional(), name: entityName }),
      user: z.object({
        id: base64Url(64, 1),
        name: entityName,
        displayName: entityName.optional(),
      }),
      pubKeyCredParams: z
        .array(z.object({ alg: z.number().int(), type: z.string().max(32) }))
        .max(32),
      excludeCredentials: z.array(descriptorSchema).max(64).optional(),
      authenticatorSelection: z
        .object({
          residentKey: z.string().max(32).optional(),
          requireResidentKey: z.boolean().optional(),
          userVerification: z.string().max(32).optional(),
        })
        .optional(),
      attestation: z.string().max(32).optional(),
      extensions: z.object({ credProps: z.boolean().optional() }).optional(),
    }),
  }),
  z.object({
    kind: z.literal("get"),
    options: z.object({
      challenge: base64Url(1024, 1),
      rpId: z.string().max(253).optional(),
      allowCredentials: z.array(descriptorSchema).max(64).optional(),
      userVerification: z.string().max(32).optional(),
    }),
  }),
]);

export type PageCredentialRequest = z.infer<typeof pageCredentialRequestSchema>;
export type PageCredentialDescriptor = z.infer<typeof descriptorSchema>;

/** What the page shim turns back into a `PublicKeyCredential`. */
export interface PageCredential {
  id: Base64Url;
  authenticatorAttachment: "cross-platform";
  response: {
    clientDataJSON: Base64Url;
    authenticatorData: Base64Url;
    attestationObject?: Base64Url | undefined;
    transports?: string[] | undefined;
    publicKey?: Base64Url | undefined;
    publicKeyAlgorithm?: number | undefined;
    signature?: Base64Url | undefined;
    userHandle?: Base64Url | null | undefined;
  };
  clientExtensionResults: { credProps?: { rk: boolean } | undefined };
}

/**
 * A failure the page receives as a `DOMException` of this name. `connection`
 * marks a failure to reach or talk to the phone, which the user sees.
 */
export class WebAuthnError extends Error {
  constructor(
    readonly domName: "NotAllowedError" | "InvalidStateError" | "SecurityError",
    message: string,
    readonly reason?: "connection"
  ) {
    super(message);
    this.name = domName;
  }
}

const fromBase64Url = (value: string) => Buffer.from(value, "base64url");
const toBase64Url = (value: Uint8Array) => Buffer.from(value).toString("base64url");
const sha256 = (value: Uint8Array | string) =>
  createHash("sha256").update(value).digest();

/**
 * The relying party id the request uses, after the checks Chromium applies:
 * the id is the page's host or a parent domain of it, and not a public suffix.
 */
export function relyingPartyId(origin: string, requested: string | undefined) {
  const url = new URL(origin);
  const secure =
    url.protocol === "https:" ||
    (url.protocol === "http:" && url.hostname === "localhost");
  if (!secure) throw new WebAuthnError("SecurityError", "The page is not secure.");
  const host = url.hostname.toLowerCase();
  const rpId = (requested ?? host).toLowerCase();
  if (rpId === host) return rpId;
  const registrable = getDomain(host, { allowPrivateDomains: true });
  if (
    registrable &&
    host.endsWith(`.${rpId}`) &&
    (rpId === registrable || rpId.endsWith(`.${registrable}`))
  ) {
    return rpId;
  }
  throw new WebAuthnError(
    "SecurityError",
    "The relying party id is invalid for this page."
  );
}

/** Chromium's member order and escaping (`client_data_json.cc`). */
export function clientDataJson(
  type: "webauthn.create" | "webauthn.get",
  challenge: Base64Url,
  origin: string
) {
  return Buffer.from(
    `{"type":${JSON.stringify(type)},"challenge":${JSON.stringify(
      toBase64Url(fromBase64Url(challenge))
    )},"origin":${JSON.stringify(origin)},"crossOrigin":false}`,
    "utf8"
  );
}

const descriptors = (list: PageCredentialDescriptor[] | undefined) =>
  (list ?? []).map(
    (credential) =>
      new Map<string, unknown>([
        ["id", fromBase64Url(credential.id)],
        ["type", "public-key"],
      ])
  );

const supportsOption = (getInfo: Map<number, unknown>, option: string) => {
  const options = getInfo.get(4);
  return options instanceof Map && options.get(option) === true;
};

/** `cmd ‖ CBOR` for authenticatorMakeCredential or authenticatorGetAssertion. */
export function ctapCommand(
  request: PageCredentialRequest,
  rpId: string,
  clientData: Buffer,
  getInfo: Map<number, unknown>
) {
  const clientDataHash = sha256(clientData);
  const uv = supportsOption(getInfo, "uv");
  if (request.kind === "create") {
    const { options } = request;
    const selection = options.authenticatorSelection;
    const residentKey =
      selection?.residentKey ??
      (selection?.requireResidentKey ? "required" : "discouraged");
    const rk =
      residentKey === "required" ||
      (residentKey === "preferred" && supportsOption(getInfo, "rk"));
    const exclude = descriptors(options.excludeCredentials);
    const body = new Map<number, unknown>([
      [1, clientDataHash],
      [
        2,
        new Map([
          ["id", rpId],
          ["name", options.rp.name],
        ]),
      ],
      [
        3,
        new Map<string, unknown>([
          ["id", fromBase64Url(options.user.id)],
          ["name", options.user.name],
          // iPhones refuse a hybrid passkey without a display name, even "".
          ["displayName", options.user.displayName ?? ""],
        ]),
      ],
      [
        4,
        // An empty list means ES256 and RS256 (WebAuthn §5.1.3, step 10).
        (options.pubKeyCredParams.length > 0
          ? options.pubKeyCredParams
          : [
              { alg: -7, type: "public-key" },
              { alg: -257, type: "public-key" },
            ]
        ).map(
          ({ alg, type }) =>
            new Map<string, unknown>([
              ["alg", alg],
              ["type", type],
            ])
        ),
      ],
      ...(exclude.length > 0 ? [[5, exclude] as [number, unknown]] : []),
      [
        7,
        new Map<string, boolean>([
          ...(rk ? [["rk", true] as [string, boolean]] : []),
          ...(uv ? [["uv", true] as [string, boolean]] : []),
        ]),
      ],
    ]);
    return { command: Buffer.concat([Buffer.from([0x01]), encodeCbor(body)]), rk };
  }
  const { options } = request;
  const allow = descriptors(options.allowCredentials);
  const requireUv = allow.length === 0 || options.userVerification !== "discouraged";
  const body = new Map<number, unknown>([
    [1, rpId],
    [2, clientDataHash],
    ...(allow.length > 0 ? [[3, allow] as [number, unknown]] : []),
    [5, new Map<string, boolean>(uv && requireUv ? [["uv", true]] : [])],
  ]);
  return { command: Buffer.concat([Buffer.from([0x02]), encodeCbor(body)]), rk: false };
}

const ctapStatus = { ok: 0x00, credentialExcluded: 0x19 } as const;

function statusError(status: number) {
  return status === ctapStatus.credentialExcluded
    ? new WebAuthnError(
        "InvalidStateError",
        "The phone already has a passkey for this site."
      )
    : new WebAuthnError(
        "NotAllowedError",
        `The phone ended the request (0x${status.toString(16)}).`
      );
}

interface ParsedAuthenticatorData {
  credentialId?: Buffer;
  publicKey?: Map<number, unknown>;
}

function parseAuthenticatorData(
  authData: Buffer,
  rpId: string
): ParsedAuthenticatorData {
  if (authData.length < 37 || !authData.subarray(0, 32).equals(sha256(rpId))) {
    throw new WebAuthnError("NotAllowedError", "The phone answered for another site.");
  }
  const flags = authData[32]!;
  if ((flags & 0x40) === 0) return {};
  const idLength = authData.readUInt16BE(53);
  const credentialId = authData.subarray(55, 55 + idLength);
  try {
    // The COSE key is the first CBOR item after the credential id.
    const [publicKey] = decodeFirstCbor(authData.subarray(55 + idLength));
    if (publicKey instanceof Map) return { credentialId, publicKey };
  } catch {
    // Reported below.
  }
  throw new WebAuthnError("NotAllowedError", "The phone sent an invalid public key.");
}

/** The SubjectPublicKeyInfo `getPublicKey()` returns, for EC2 and RSA keys. */
function subjectPublicKeyInfo(coseKey: Map<number, unknown>) {
  const bytes = (label: number) =>
    Buffer.from(coseKey.get(label) as Uint8Array).toString("base64url");
  try {
    if (coseKey.get(1) === 2 && coseKey.get(-1) === 1) {
      return createPublicKey({
        key: { kty: "EC", crv: "P-256", x: bytes(-2), y: bytes(-3) },
        format: "jwk",
      }).export({ type: "spki", format: "der" });
    }
    if (coseKey.get(1) === 3) {
      return createPublicKey({
        key: { kty: "RSA", n: bytes(-1), e: bytes(-2) },
        format: "jwk",
      }).export({ type: "spki", format: "der" });
    }
  } catch {
    return undefined;
  }
  return undefined;
}

/** Turns the phone's CTAP reply into the credential the page receives. */
export function pageCredential({
  request,
  rpId,
  clientData,
  status,
  body,
  rk,
  getInfo,
}: {
  request: PageCredentialRequest;
  rpId: string;
  clientData: Buffer;
  status: number;
  body: Uint8Array;
  rk: boolean;
  getInfo: Map<number, unknown>;
}): PageCredential {
  if (status !== ctapStatus.ok) throw statusError(status);
  const reply = decodeCbor(body);
  if (!(reply instanceof Map)) {
    throw new WebAuthnError("NotAllowedError", "The phone sent an invalid reply.");
  }
  const authData = Buffer.from((reply.get(2) ?? []) as Uint8Array);
  const parsed = parseAuthenticatorData(authData, rpId);

  if (request.kind === "create") {
    const fmt = reply.get(1);
    const attStmt = reply.get(3);
    if (typeof fmt !== "string" || !(attStmt instanceof Map) || !parsed.credentialId) {
      throw new WebAuthnError("NotAllowedError", "The phone sent an invalid passkey.");
    }
    const keepAttestation =
      request.options.attestation !== undefined &&
      request.options.attestation !== "none";
    // Like Chromium, "none" removes the statement but keeps the AAGUID.
    const attestationObject = encodeCbor(
      new Map<string, unknown>([
        ["fmt", keepAttestation ? fmt : "none"],
        ["attStmt", keepAttestation ? attStmt : new Map()],
        ["authData", authData],
      ])
    );
    const advertised = Array.isArray(getInfo.get(9))
      ? (getInfo.get(9) as unknown[]).filter(
          (transport): transport is string =>
            transport === "internal" || transport === "hybrid" || transport === "usb"
        )
      : ["internal"];
    const publicKey = parsed.publicKey
      ? subjectPublicKeyInfo(parsed.publicKey)
      : undefined;
    const algorithm = parsed.publicKey?.get(3);
    return {
      id: toBase64Url(parsed.credentialId),
      authenticatorAttachment: "cross-platform",
      response: {
        clientDataJSON: toBase64Url(clientData),
        attestationObject: toBase64Url(attestationObject),
        authenticatorData: toBase64Url(authData),
        transports: [...new Set(["hybrid", ...advertised])].toSorted(),
        ...(publicKey ? { publicKey: toBase64Url(publicKey) } : {}),
        ...(typeof algorithm === "number" ? { publicKeyAlgorithm: algorithm } : {}),
      },
      clientExtensionResults: request.options.extensions?.credProps
        ? { credProps: { rk } }
        : {},
    };
  }

  const allowed = request.options.allowCredentials ?? [];
  const credential = reply.get(1);
  const credentialId =
    credential instanceof Map && credential.get("id") instanceof Uint8Array
      ? Buffer.from(credential.get("id") as Uint8Array)
      : allowed.length === 1
        ? fromBase64Url(allowed[0]!.id)
        : undefined;
  if (
    !credentialId ||
    (allowed.length > 0 &&
      !allowed.some((entry) => fromBase64Url(entry.id).equals(credentialId)))
  ) {
    throw new WebAuthnError("NotAllowedError", "The phone used an unexpected passkey.");
  }
  const signature = reply.get(3);
  const user = reply.get(4);
  const userId =
    user instanceof Map && user.get("id") instanceof Uint8Array
      ? Buffer.from(user.get("id") as Uint8Array)
      : undefined;
  if (!(signature instanceof Uint8Array) || (allowed.length === 0 && !userId)) {
    throw new WebAuthnError("NotAllowedError", "The phone sent an invalid assertion.");
  }
  return {
    id: toBase64Url(credentialId),
    authenticatorAttachment: "cross-platform",
    response: {
      clientDataJSON: toBase64Url(clientData),
      authenticatorData: toBase64Url(authData),
      signature: toBase64Url(signature),
      userHandle: userId && userId.length > 0 ? toBase64Url(userId) : null,
    },
    clientExtensionResults: {},
  };
}
