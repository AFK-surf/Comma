/**
 * A phone for hybrid passkey tests. It reads the QR code like a phone camera,
 * returns the Bluetooth advert a phone would broadcast, and serves the tunnel
 * locally: it answers the Noise handshake and acts as a passkey provider.
 * Clients of `/air` receive every advert, as a Bluetooth scan would.
 * It is written from the CTAP 2.2 hybrid section, apart from the initiator
 * code, so the two meet only on the wire.
 */
import {
  ECDH,
  createCipheriv,
  createDecipheriv,
  createECDH,
  createHash,
  createHmac,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  sign,
  type KeyObject,
} from "node:crypto";
import type { AddressInfo } from "node:net";
import { WebSocketServer, type RawData, type WebSocket } from "ws";

export interface StoredPasskey {
  credentialId: Buffer;
  rpId: string;
  userId: Buffer;
  userName: string;
  privateKey: KeyObject;
}

export interface PendingTunnel {
  identityPublicKey: Buffer;
  advertPlaintext: Buffer;
  qrSecret: Buffer;
}

function cborHead(major: number, length: number) {
  if (length < 24) return Buffer.from([(major << 5) | length]);
  if (length < 0x100) return Buffer.from([(major << 5) | 24, length]);
  if (length < 0x10000) {
    const bytes = Buffer.alloc(3);
    bytes[0] = (major << 5) | 25;
    bytes.writeUInt16BE(length, 1);
    return bytes;
  }
  const bytes = Buffer.alloc(5);
  bytes[0] = (major << 5) | 26;
  bytes.writeUInt32BE(length, 1);
  return bytes;
}

/**
 * The CBOR this phone needs: integers, byte and text strings, arrays, maps and
 * booleans. Its own codec, so that Playwright can load the phone without the
 * ESM-only codec of the initiator.
 */
function encode(value: unknown): Buffer {
  if (typeof value === "number")
    return value >= 0 ? cborHead(0, value) : cborHead(1, -1 - value);
  if (typeof value === "boolean") return Buffer.from([value ? 0xf5 : 0xf4]);
  if (typeof value === "string") {
    const text = Buffer.from(value, "utf8");
    return Buffer.concat([cborHead(3, text.length), text]);
  }
  if (value instanceof Uint8Array)
    return Buffer.concat([cborHead(2, value.length), value]);
  if (Array.isArray(value))
    return Buffer.concat([cborHead(4, value.length), ...value.map(encode)]);
  if (value instanceof Map) {
    return Buffer.concat([
      cborHead(5, value.size),
      ...[...value].flatMap(([key, item]) => [encode(key), encode(item)]),
    ]);
  }
  throw new TypeError("The test phone cannot encode this value.");
}

function decode(input: Uint8Array): unknown {
  const bytes = Buffer.from(input);
  let offset = 0;
  const read = (): unknown => {
    const initial = bytes[offset++]!;
    const major = initial >> 5;
    const info = initial & 31;
    let length = info;
    if (info === 24) {
      length = bytes.readUInt8(offset);
      offset += 1;
    } else if (info === 25) {
      length = bytes.readUInt16BE(offset);
      offset += 2;
    } else if (info === 26) {
      length = bytes.readUInt32BE(offset);
      offset += 4;
    } else if (info > 26) {
      throw new Error("The test phone cannot decode this CBOR.");
    }
    const take = () => {
      const value = bytes.subarray(offset, offset + length);
      offset += length;
      return value;
    };
    switch (major) {
      case 0:
        return length;
      case 1:
        return -1 - length;
      case 2:
        return Buffer.from(take());
      case 3:
        return take().toString("utf8");
      case 4:
        return Array.from({ length }, read);
      case 5: {
        const map = new Map<unknown, unknown>();
        for (let index = 0; index < length; index += 1) map.set(read(), read());
        return map;
      }
      default:
        if (initial === 0xf4) return false;
        if (initial === 0xf5) return true;
        throw new Error("The test phone cannot decode this CBOR.");
    }
  };
  return read();
}

const ctapOk = 0x00;
const ctapNoCredentials = 0x2e;

const sha256 = (...parts: Uint8Array[]) =>
  parts.reduce((hash, part) => hash.update(part), createHash("sha256")).digest();
const hkdf = (secret: Uint8Array, salt: Uint8Array, info: Uint8Array, length: number) =>
  Buffer.from(hkdfSync("sha256", secret, salt, info, length));
const infoType = (type: number) => {
  const info = Buffer.alloc(4);
  info.writeUInt32LE(type);
  return info;
};
const hex = (bytes: Uint8Array) => Buffer.from(bytes).toString("hex").toUpperCase();

function decodeDigits(digits: string) {
  const widths = [0, 3, 5, 8, 10, 13, 15, 17];
  const bytes: number[] = [];
  for (let offset = 0; offset < digits.length; offset += 17) {
    const part = digits.slice(offset, offset + 17);
    let value = BigInt(part);
    for (let index = 0; index < widths.indexOf(part.length); index += 1) {
      bytes.push(Number(value & 0xffn));
      value >>= 8n;
    }
  }
  return Uint8Array.from(bytes);
}

class Noise {
  chainingKey = Buffer.alloc(32);
  hash: Buffer;
  key = Buffer.alloc(32);
  constructor() {
    this.chainingKey.write("Noise_KNpsk0_P256_AESGCM_SHA256", "ascii");
    this.hash = Buffer.from(this.chainingKey);
  }
  mixHash(data: Uint8Array) {
    this.hash = sha256(this.hash, data);
  }
  mixKey(input: Uint8Array, length = 64) {
    const output = hkdf(input, this.chainingKey, Buffer.alloc(0), length);
    this.chainingKey = output.subarray(0, 32);
    if (length === 96) this.mixHash(output.subarray(32, 64));
    this.key = output.subarray(length - 32);
  }
  seal(plaintext: Uint8Array) {
    const cipher = createCipheriv("aes-256-gcm", this.key, Buffer.alloc(12)).setAAD(
      this.hash
    );
    const sealed = Buffer.concat([
      cipher.update(plaintext),
      cipher.final(),
      cipher.getAuthTag(),
    ]);
    this.mixHash(sealed);
    return sealed;
  }
  open(sealed: Buffer) {
    const decipher = createDecipheriv("aes-256-gcm", this.key, Buffer.alloc(12)).setAAD(
      this.hash
    );
    decipher.setAuthTag(sealed.subarray(-16));
    const plaintext = Buffer.concat([
      decipher.update(sealed.subarray(0, -16)),
      decipher.final(),
    ]);
    this.mixHash(sealed);
    return plaintext;
  }
}

function transportNonce(sequence: number) {
  const nonce = Buffer.alloc(12);
  nonce.writeUInt32BE(sequence, 8);
  return nonce;
}

function makeCredential(request: Map<number, unknown>, passkeys: StoredPasskey[]) {
  const rp = request.get(2) as Map<string, string>;
  const user = request.get(3) as Map<string, unknown>;
  const rpId = rp.get("id")!;
  const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = publicKey.export({ format: "jwk" });
  const credentialId = randomBytes(16);
  passkeys.push({
    credentialId,
    rpId,
    userId: Buffer.from(user.get("id") as Uint8Array),
    userName: String(user.get("name")),
    privateKey,
  });
  const coseKey = encode(
    new Map<number, unknown>([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, Buffer.from(jwk.x!, "base64url")],
      [-3, Buffer.from(jwk.y!, "base64url")],
    ])
  );
  const idLength = Buffer.alloc(2);
  idLength.writeUInt16BE(credentialId.length);
  const authData = Buffer.concat([
    sha256(Buffer.from(rpId)),
    // User present, user verified, attested credential data.
    Buffer.from([0x45]),
    Buffer.alloc(4),
    Buffer.alloc(16),
    idLength,
    credentialId,
    coseKey,
  ]);
  return Buffer.concat([
    Buffer.from([ctapOk]),
    encode(
      new Map<number, unknown>([
        [1, "none"],
        [2, authData],
        [3, new Map()],
      ])
    ),
  ]);
}

function getAssertion(request: Map<number, unknown>, passkeys: StoredPasskey[]) {
  const rpId = String(request.get(1));
  const clientDataHash = request.get(2) as Uint8Array;
  const passkey = passkeys.find((candidate) => candidate.rpId === rpId);
  if (!passkey) return Buffer.from([ctapNoCredentials]);
  const authData = Buffer.concat([
    sha256(Buffer.from(rpId)),
    Buffer.from([0x05]),
    Buffer.from([0, 0, 0, 1]),
  ]);
  return Buffer.concat([
    Buffer.from([ctapOk]),
    encode(
      new Map<number, unknown>([
        [
          1,
          new Map<string, unknown>([
            ["id", passkey.credentialId],
            ["type", "public-key"],
          ]),
        ],
        [2, authData],
        [
          3,
          sign("sha256", Buffer.concat([authData, clientDataHash]), passkey.privateKey),
        ],
        [
          4,
          new Map<string, unknown>([
            ["id", passkey.userId],
            ["name", passkey.userName],
          ]),
        ],
      ])
    ),
  ]);
}

/** What a phone reads from a `FIDO:/` QR code. */
export function readCableQrCode(uri: string) {
  const qr = decode(decodeDigits(uri.slice("FIDO:/".length))) as Map<
    number,
    Uint8Array
  >;
  const qrSecret = Buffer.from(qr.get(1)!);
  return {
    identityPublicKey: ECDH.convertKey(
      Buffer.from(qr.get(0)!),
      "prime256v1",
      undefined,
      undefined,
      "uncompressed"
    ) as Buffer,
    qrSecret,
    eidKey: hkdf(qrSecret, Buffer.alloc(0), infoType(1), 64),
    tunnelId: hkdf(qrSecret, Buffer.alloc(0), infoType(2), 16),
  };
}

/** The 20-byte advert for a tunnel the server gave this routing id. */
export function cableAdvert(
  qr: ReturnType<typeof readCableQrCode>,
  routingId: Uint8Array
) {
  // Reserved zero, a random nonce, the routing id, and tunnel domain 0.
  const advertPlaintext = Buffer.concat([
    Buffer.from([0]),
    randomBytes(10),
    routingId,
    Buffer.from([0, 0]),
  ]);
  const cipher = createCipheriv("aes-256-ecb", qr.eidKey.subarray(0, 32), null);
  cipher.setAutoPadding(false);
  const ciphertext = Buffer.concat([cipher.update(advertPlaintext), cipher.final()]);
  const tag = createHmac("sha256", qr.eidKey.subarray(32)).update(ciphertext).digest();
  return { advert: Buffer.concat([ciphertext, tag.subarray(0, 4)]), advertPlaintext };
}

/** What one phone holds and what it was asked. */
export interface CablePhoneAccount {
  /** A CTAP status the phone answers instead of completing the command. */
  deny: number | undefined;
  /** The phone closes the tunnel instead of answering, as iOS does on cancel. */
  hangUp?: boolean | undefined;
  passkeys: StoredPasskey[];
  commands: Array<{ command: number; request: Map<number, unknown> }>;
}

/**
 * Answers one tunnel connection as the phone: the Noise KNpsk0 handshake,
 * getInfo, a linking update, and the reply to one CTAP command.
 */
export function answerTunnel(
  socket: WebSocket,
  tunnel: PendingTunnel,
  phone: CablePhoneAccount
) {
  let readSequence = 0;
  let writeSequence = 0;
  let readKey: Buffer | undefined;
  let writeKey: Buffer | undefined;
  const sendEncrypted = (message: Uint8Array) => {
    const padded = Buffer.alloc((message.length + 32) & ~31);
    padded.set(message);
    padded[padded.length - 1] = padded.length - message.length - 1;
    const cipher = createCipheriv(
      "aes-256-gcm",
      writeKey!,
      transportNonce(writeSequence++)
    );
    socket.send(
      Buffer.concat([cipher.update(padded), cipher.final(), cipher.getAuthTag()])
    );
  };
  socket.on("message", (raw: RawData) => {
    const data = raw as Buffer;
    if (!readKey) {
      // KNpsk0 responder: the initiator's static key came from the QR code.
      const noise = new Noise();
      noise.mixHash(Buffer.from([1]));
      noise.mixHash(tunnel.identityPublicKey);
      noise.mixKey(hkdf(tunnel.qrSecret, tunnel.advertPlaintext, infoType(3), 32), 96);
      const initiatorEphemeral = data.subarray(0, 65);
      noise.mixHash(initiatorEphemeral);
      noise.mixKey(initiatorEphemeral);
      noise.open(data.subarray(65));
      const ephemeral = createECDH("prime256v1");
      ephemeral.generateKeys();
      noise.mixHash(ephemeral.getPublicKey());
      noise.mixKey(ephemeral.getPublicKey());
      noise.mixKey(ephemeral.computeSecret(initiatorEphemeral));
      noise.mixKey(ephemeral.computeSecret(tunnel.identityPublicKey));
      socket.send(
        Buffer.concat([ephemeral.getPublicKey(), noise.seal(Buffer.alloc(0))])
      );
      const keys = hkdf(Buffer.alloc(0), noise.chainingKey, Buffer.alloc(0), 64);
      readKey = keys.subarray(0, 32);
      writeKey = keys.subarray(32);
      const getInfo = encode(
        new Map<number, unknown>([
          [1, ["FIDO_2_0", "FIDO_2_1"]],
          [3, Buffer.alloc(16)],
          [
            4,
            new Map([
              ["rk", true],
              ["uv", true],
            ]),
          ],
          [9, ["internal", "hybrid"]],
        ])
      );
      sendEncrypted(
        encode(
          new Map<number, unknown>([
            [1, getInfo],
            [3, ["ctap"]],
          ])
        )
      );
      // Phones send a linking update before the reply; the initiator skips it.
      sendEncrypted(
        Buffer.concat([Buffer.from([2]), encode(new Map([[1, randomBytes(8)]]))])
      );
      return;
    }
    const decipher = createDecipheriv(
      "aes-256-gcm",
      readKey,
      transportNonce(readSequence++)
    );
    decipher.setAuthTag(data.subarray(-16));
    const padded = Buffer.concat([
      decipher.update(data.subarray(0, -16)),
      decipher.final(),
    ]);
    const message = padded.subarray(0, padded.length - padded.at(-1)! - 1);
    if (message[0] === 0) {
      socket.close();
      return;
    }
    const command = message[1]!;
    const ctapRequest = decode(message.subarray(2)) as Map<number, unknown>;
    phone.commands.push({ command, request: ctapRequest });
    if (phone.hangUp) {
      socket.close();
      return;
    }
    const reply =
      phone.deny === undefined
        ? command === 0x01
          ? makeCredential(ctapRequest, phone.passkeys)
          : getAssertion(ctapRequest, phone.passkeys)
        : Buffer.from([phone.deny]);
    sendEncrypted(Buffer.concat([Buffer.from([1]), reply]));
  });
}

export async function startCablePhone() {
  const pending = new Map<string, PendingTunnel>();
  const adverts: Buffer[] = [];
  const air = new Set<WebSocket>();
  const phone: CablePhoneAccount = { deny: undefined, passkeys: [], commands: [] };
  const server = new WebSocketServer({
    host: "127.0.0.1",
    port: 0,
    handleProtocols: (protocols) =>
      protocols.has("fido.cable") ? "fido.cable" : false,
  });
  await new Promise<void>((resolve) => server.once("listening", () => resolve()));
  const { port } = server.address() as AddressInfo;

  server.on("connection", (socket, request) => {
    if (request.url === "/air") {
      air.add(socket);
      socket.on("close", () => air.delete(socket));
      for (const advert of adverts) socket.send(advert);
      return;
    }
    const tunnel = pending.get(request.url ?? "");
    pending.delete(request.url ?? "");
    if (!tunnel) {
      socket.close();
      return;
    }
    answerTunnel(socket, tunnel, phone);
  });

  return Object.assign(phone, {
    /** Replaces the tunnel server origin in the initiator. */
    tunnelOrigin: `ws://127.0.0.1:${port}`,
    /** Scans the QR code and returns the 20-byte advert the phone broadcasts. */
    scan(uri: string) {
      const qr = readCableQrCode(uri);
      const { advert, advertPlaintext } = cableAdvert(qr, randomBytes(3));
      pending.set(
        `/cable/connect/${hex(advertPlaintext.subarray(11, 14))}/${hex(qr.tunnelId)}`,
        {
          identityPublicKey: qr.identityPublicKey,
          advertPlaintext,
          qrSecret: qr.qrSecret,
        }
      );
      adverts.push(advert);
      for (const socket of air) socket.send(advert);
      return advert;
    },
    close: () =>
      new Promise<void>((resolve) => {
        for (const client of server.clients) client.terminate();
        server.close(() => resolve());
      }),
  });
}

export type CablePhone = Awaited<ReturnType<typeof startCablePhone>>;
