/**
 * The caBLE v2 ("hybrid") initiator: the side that shows a QR code, finds the
 * phone's Bluetooth advert, and talks to the phone through a tunnel server.
 * It follows Chromium's `device/fido/cable` (main@0bc4ed30dd6e) and CTAP 2.2
 * §11.5. No maintained JavaScript implementation exists, and the Rust one in
 * webauthn-rs calls itself incomplete and unreviewed, so this ports the
 * Chromium behavior and checks it against the vectors in its tests.
 */
import { decode, decodeFirst, encode } from "cborg";
import {
  createCipheriv,
  createDecipheriv,
  createECDH,
  createHash,
  createHmac,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";

export type CableRequestType = "ga" | "mc";

const qrPrefix = "FIDO:/";
const assignedDomains = ["cable.ua5v.com", "cable.auth.com"] as const;
const handshakeResponseLength = 65 + 16;
const maxSequence = (1 << 24) - 1;

/** HKDF info values from `v2_handshake.h`, written as little-endian uint32. */
const derivedValue = { eidKey: 1, tunnelId: 2, psk: 3 } as const;

function littleEndian32(value: number) {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32LE(value);
  return bytes;
}

export function deriveCableValue(
  length: number,
  secret: Uint8Array,
  salt: Uint8Array,
  type: (typeof derivedValue)[keyof typeof derivedValue]
) {
  return Buffer.from(hkdfSync("sha256", secret, salt, littleEndian32(type), length));
}

// Digit widths for a final chunk of 0..7 bytes (`v2_handshake.cc` kWidths).
const chunkDigits = [0, 3, 5, 8, 10, 13, 15, 17] as const;

/** Writes bytes as `FIDO:/` digits: 7-byte little-endian chunks in decimal. */
export function encodeQrDigits(bytes: Uint8Array) {
  let digits = "";
  for (let offset = 0; offset < bytes.length; offset += 7) {
    const chunk = bytes.subarray(offset, Math.min(offset + 7, bytes.length));
    let value = 0n;
    for (let index = chunk.length - 1; index >= 0; index -= 1) {
      value = (value << 8n) | BigInt(chunk[index]!);
    }
    digits += value.toString().padStart(chunkDigits[chunk.length]!, "0");
  }
  return digits;
}

export function decodeQrDigits(digits: string): Uint8Array | undefined {
  if (!/^\d*$/u.test(digits)) return undefined;
  const bytes: number[] = [];
  for (let offset = 0; offset < digits.length; offset += 17) {
    const part = digits.slice(offset, offset + 17);
    const length = chunkDigits.indexOf(part.length as (typeof chunkDigits)[number]);
    if (length <= 0) return undefined;
    let value = BigInt(part);
    if (value >> BigInt(length * 8) !== 0n) return undefined;
    for (let index = 0; index < length; index += 1) {
      bytes.push(Number(value & 0xffn));
      value >>= 8n;
    }
  }
  return Uint8Array.from(bytes);
}

/**
 * One QR code for one WebAuthn request. The identity key and secret are new
 * for every request and never leave Main.
 */
export interface CableQrSession {
  uri: string;
  identityPrivateKey: Buffer;
  qrSecret: Buffer;
  eidKey: Buffer;
  tunnelId: Buffer;
}

export function createCableQrSession(
  requestType: CableRequestType,
  {
    now = Date.now(),
    identityPrivateKey,
    qrSecret = randomBytes(16),
  }: { now?: number; identityPrivateKey?: Buffer; qrSecret?: Buffer } = {}
): CableQrSession {
  const identity = createECDH("prime256v1");
  if (identityPrivateKey) identity.setPrivateKey(identityPrivateKey);
  else identity.generateKeys();
  const qr = new Map<number, unknown>([
    [0, identity.getPublicKey(null, "compressed")],
    [1, qrSecret],
    [2, assignedDomains.length],
    [3, Math.floor(now / 1000)],
    // Linking is not offered for WebAuthn; Chromium always writes the key.
    [4, false],
    [5, requestType],
  ]);
  return {
    uri: `${qrPrefix}${encodeQrDigits(encode(qr))}`,
    identityPrivateKey: identity.getPrivateKey(),
    qrSecret,
    eidKey: deriveCableValue(64, qrSecret, Buffer.alloc(0), derivedValue.eidKey),
    tunnelId: deriveCableValue(16, qrSecret, Buffer.alloc(0), derivedValue.tunnelId),
  };
}

/** The tunnel server named by a domain id, or undefined for an unknown id. */
export function cableTunnelDomain(id: number) {
  if (id < 256) return assignedDomains[id];
  const input = Buffer.concat([
    Buffer.from("caBLEv2 tunnel server domain", "ascii"),
    Buffer.from([id & 0xff, id >> 8, 0]),
  ]);
  let value = createHash("sha256").update(input).digest().readBigUInt64LE(0);
  const topLevelDomain = ["com", "org", "net", "info"][Number(value & 3n)]!;
  value >>= 2n;
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  let name = "cable.";
  while (value !== 0n) {
    name += alphabet[Number(value & 31n)];
    value >>= 5n;
  }
  return `${name}.${topLevelDomain}`;
}

export interface CableAdvert {
  plaintext: Buffer;
  routingId: Buffer;
  domain: string;
}

/**
 * Trial-decrypts a 20-byte service-data advert with this request's EID key.
 * Adverts of other phones and other requests fail the tag check.
 */
export function decryptCableAdvert(
  advert: Uint8Array,
  eidKey: Buffer
): CableAdvert | undefined {
  if (advert.length !== 20) return undefined;
  const ciphertext = advert.subarray(0, 16);
  const tag = createHmac("sha256", eidKey.subarray(32)).update(ciphertext).digest();
  if (!timingSafeEqual(tag.subarray(0, 4), advert.subarray(16))) return undefined;
  const decipher = createDecipheriv("aes-256-ecb", eidKey.subarray(0, 32), null);
  decipher.setAutoPadding(false);
  const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
  if (plaintext[0] !== 0) return undefined;
  const domain = cableTunnelDomain(plaintext.readUInt16LE(14));
  if (!domain) return undefined;
  return { plaintext, routingId: plaintext.subarray(11, 14), domain };
}

const upperHex = (bytes: Uint8Array) =>
  Buffer.from(bytes).toString("hex").toUpperCase();

export function cableConnectUrl(session: CableQrSession, advert: CableAdvert) {
  return `wss://${advert.domain}/cable/connect/${upperHex(advert.routingId)}/${upperHex(session.tunnelId)}`;
}

const sha256 = (...parts: Uint8Array[]) =>
  parts.reduce((hash, part) => hash.update(part), createHash("sha256")).digest();
const hkdfFromChainingKey = (chainingKey: Buffer, input: Uint8Array, length: number) =>
  Buffer.from(hkdfSync("sha256", input, chainingKey, Buffer.alloc(0), length));

class NoiseState {
  chainingKey: Buffer;
  hash: Buffer;
  key = Buffer.alloc(32);

  constructor(protocolName: string) {
    this.chainingKey = Buffer.alloc(32);
    this.chainingKey.write(protocolName, "ascii");
    this.hash = Buffer.from(this.chainingKey);
  }

  mixHash(data: Uint8Array) {
    this.hash = sha256(this.hash, data);
  }

  mixKey(input: Uint8Array) {
    const output = hkdfFromChainingKey(this.chainingKey, input, 64);
    this.chainingKey = output.subarray(0, 32);
    this.key = output.subarray(32);
  }

  mixKeyAndHash(input: Uint8Array) {
    const output = hkdfFromChainingKey(this.chainingKey, input, 96);
    this.chainingKey = output.subarray(0, 32);
    this.mixHash(output.subarray(32, 64));
    this.key = output.subarray(64);
  }

  // Every handshake encryption follows a MixKey, so its nonce is zero.
  encryptAndHash(plaintext: Uint8Array) {
    const cipher = createCipheriv("aes-256-gcm", this.key, Buffer.alloc(12));
    cipher.setAAD(this.hash);
    const ciphertext = Buffer.concat([
      cipher.update(plaintext),
      cipher.final(),
      cipher.getAuthTag(),
    ]);
    this.mixHash(ciphertext);
    return ciphertext;
  }

  decryptAndHash(ciphertext: Buffer) {
    const decipher = createDecipheriv("aes-256-gcm", this.key, Buffer.alloc(12));
    decipher.setAAD(this.hash);
    decipher.setAuthTag(ciphertext.subarray(-16));
    const plaintext = Buffer.concat([
      decipher.update(ciphertext.subarray(0, -16)),
      decipher.final(),
    ]);
    this.mixHash(ciphertext);
    return plaintext;
  }
}

function ecdh(privateKey: Buffer, publicKey: Uint8Array) {
  const key = createECDH("prime256v1");
  key.setPrivateKey(privateKey);
  return key.computeSecret(publicKey);
}

/**
 * The Noise KNpsk0 handshake of a QR-initiated connection. The phone learned
 * the identity key from the QR code; the PSK binds the handshake to the advert.
 */
export class CableHandshake {
  readonly message: Buffer;
  readonly #noise = new NoiseState("Noise_KNpsk0_P256_AESGCM_SHA256");
  readonly #ephemeralPrivateKey: Buffer;
  readonly #identityPrivateKey: Buffer;

  constructor(
    session: Pick<CableQrSession, "identityPrivateKey" | "qrSecret">,
    advert: Pick<CableAdvert, "plaintext">,
    ephemeralPrivateKey?: Buffer
  ) {
    const identity = createECDH("prime256v1");
    identity.setPrivateKey(session.identityPrivateKey);
    const ephemeral = createECDH("prime256v1");
    if (ephemeralPrivateKey) ephemeral.setPrivateKey(ephemeralPrivateKey);
    else ephemeral.generateKeys();
    this.#identityPrivateKey = session.identityPrivateKey;
    this.#ephemeralPrivateKey = ephemeral.getPrivateKey();
    const psk = deriveCableValue(
      32,
      session.qrSecret,
      advert.plaintext,
      derivedValue.psk
    );
    this.#noise.mixHash(Buffer.from([1]));
    this.#noise.mixHash(identity.getPublicKey());
    this.#noise.mixKeyAndHash(psk);
    const ephemeralPublicKey = ephemeral.getPublicKey();
    this.#noise.mixHash(ephemeralPublicKey);
    this.#noise.mixKey(ephemeralPublicKey);
    this.message = Buffer.concat([
      ephemeralPublicKey,
      this.#noise.encryptAndHash(Buffer.alloc(0)),
    ]);
  }

  /** Processes the phone's reply and returns the transport encryption. */
  finish(response: Buffer) {
    if (response.length !== handshakeResponseLength) {
      throw new Error("The phone sent a handshake reply of the wrong length.");
    }
    const responderEphemeral = response.subarray(0, 65);
    const ee = ecdh(this.#ephemeralPrivateKey, responderEphemeral);
    const se = ecdh(this.#identityPrivateKey, responderEphemeral);
    this.#noise.mixHash(responderEphemeral);
    this.#noise.mixKey(responderEphemeral);
    this.#noise.mixKey(ee);
    this.#noise.mixKey(se);
    if (this.#noise.decryptAndHash(response.subarray(65)).length !== 0) {
      throw new Error("The phone sent an invalid handshake reply.");
    }
    const keys = hkdfFromChainingKey(this.#noise.chainingKey, Buffer.alloc(0), 64);
    return new CableCrypter(keys.subarray(32), keys.subarray(0, 32));
  }
}

/** AES-256-GCM per direction, with Chromium's padding and big-endian counter. */
export class CableCrypter {
  #readSequence = 0;
  #writeSequence = 0;

  constructor(
    private readonly readKey: Buffer,
    private readonly writeKey: Buffer
  ) {}

  static #nonce(sequence: number) {
    if (sequence > maxSequence)
      throw new Error("The caBLE message counter is exhausted.");
    const nonce = Buffer.alloc(12);
    nonce.writeUInt32BE(sequence, 8);
    return nonce;
  }

  encrypt(message: Uint8Array) {
    const padded = Buffer.alloc((message.length + 32) & ~31);
    padded.set(message);
    padded[padded.length - 1] = padded.length - message.length - 1;
    const cipher = createCipheriv(
      "aes-256-gcm",
      this.writeKey,
      CableCrypter.#nonce(this.#writeSequence)
    );
    this.#writeSequence += 1;
    return Buffer.concat([cipher.update(padded), cipher.final(), cipher.getAuthTag()]);
  }

  decrypt(ciphertext: Buffer) {
    if (ciphertext.length < 16) throw new Error("The phone sent a short message.");
    const decipher = createDecipheriv(
      "aes-256-gcm",
      this.readKey,
      CableCrypter.#nonce(this.#readSequence)
    );
    decipher.setAuthTag(ciphertext.subarray(-16));
    const padded = Buffer.concat([
      decipher.update(ciphertext.subarray(0, -16)),
      decipher.final(),
    ]);
    this.#readSequence += 1;
    const padding = padded.at(-1);
    if (padding === undefined || padding + 1 > padded.length) {
      throw new Error("The phone sent a message with invalid padding.");
    }
    return padded.subarray(0, padded.length - padding - 1);
  }
}

export function decodeCbor(bytes: Uint8Array): unknown {
  return decode(bytes, { useMaps: true });
}

/** The first CBOR item of `bytes`, and the bytes after it. */
export function decodeFirstCbor(bytes: Uint8Array): [unknown, Uint8Array] {
  return decodeFirst(bytes, { useMaps: true });
}

export function encodeCbor(value: unknown) {
  return Buffer.from(encode(value));
}

export interface CablePostHandshake {
  /** 1: every later message starts with a type byte. 0: raw CTAP only. */
  revision: 0 | 1;
  getInfo: Map<number, unknown>;
}

/**
 * Reads the first encrypted message from the phone. Plain CBOR means protocol
 * revision 1. Padded CBOR means revision 0, which only very old phones send.
 */
export function parsePostHandshake(plaintext: Uint8Array): CablePostHandshake {
  let message: unknown;
  let revision: 0 | 1 = 1;
  try {
    message = decode(plaintext, { useMaps: true });
  } catch {
    revision = 0;
    message = decodePaddedCbor(plaintext);
  }
  if (!(message instanceof Map)) {
    throw new Error("The phone sent an invalid post-handshake message.");
  }
  const features = message.get(3);
  const ctap =
    features === undefined ||
    (Array.isArray(features) && features.some((feature) => feature === "ctap"));
  const getInfo = message.get(1);
  if (!ctap || !(getInfo instanceof Uint8Array)) {
    throw new Error("The phone does not offer WebAuthn over this connection.");
  }
  const info = decode(getInfo, { useMaps: true });
  if (!(info instanceof Map)) throw new Error("The phone sent an invalid getInfo.");
  return { revision, getInfo: info };
}

// Revision 0 pads the map; a trailing uint16 (little-endian) gives the length.
function decodePaddedCbor(plaintext: Uint8Array) {
  if (plaintext.length < 2) throw new Error("The phone sent a short message.");
  const bytes = Buffer.from(plaintext);
  const padding = bytes.readUInt16LE(bytes.length - 2);
  if (padding + 2 > bytes.length) throw new Error("The phone sent invalid padding.");
  return decode(bytes.subarray(0, bytes.length - 2 - padding), { useMaps: true });
}

export const cableMessageType = { shutdown: 0, ctap: 1, update: 2, json: 3 } as const;
