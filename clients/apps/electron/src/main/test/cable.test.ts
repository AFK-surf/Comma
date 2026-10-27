import { describe, expect, it } from "vitest";
import { realMainClock } from "../clock";
import {
  CableCrypter,
  CableHandshake,
  cableConnectUrl,
  cableTunnelDomain,
  createCableQrSession,
  decodeQrDigits,
  decryptCableAdvert,
  encodeQrDigits,
  parsePostHandshake,
} from "../modules/browser-sidebar/hybrid/cable";

// Vectors from Chromium's v2_handshake_unittest.cc and webauthn-rs, which
// captured them from real phones, plus a fixed-key transcript cross-checked
// byte for byte against webauthn-rs.
const hex = (value: string) => Buffer.from(value, "hex");
const identityPrivateKey = Buffer.alloc(32, 0x11);
const qrSecret = hex("01fea6f7c4807493dc256f9eacf756c9");
const advert = hex("027d84ed6076b55e247c830f82955e4d126e7f43");

describe("caBLE v2 initiator", () => {
  it("writes and reads the QR digit encoding", () => {
    expect(encodeQrDigits(Uint8Array.from([0x61, 0x62, 0xff]))).toBe("16736865");
    expect(decodeQrDigits("16736865")).toEqual(Uint8Array.from([0x61, 0x62, 0xff]));
    expect(decodeQrDigits("999")).toBeUndefined();
    expect(decodeQrDigits("1")).toBeUndefined();

    // A Safari QR code, decoded and written again byte for byte.
    const safari =
      "089962132878132862898875319509818655951233947060166026934941652203853844930597225184066237811614893181300344014421205790072080843938838513707157859599106109321447142404";
    expect(encodeQrDigits(decodeQrDigits(safari)!)).toBe(safari);
  });

  it("names the QR code, tunnel and connection the way Chrome does", () => {
    const session = createCableQrSession("ga", {
      identityPrivateKey,
      clock: { ...realMainClock, now: () => 1_767_225_600_000 },
      qrSecret,
    });
    expect(session.uri).toBe(
      "FIDO:/064761326369506941132196635817367045715076129656615309261485932746823659474011834762847004127724694996106571000111935910078432531307684700203776486671106107096654083076"
    );
    expect(session.tunnelId.toString("hex").toUpperCase()).toBe(
      "367CBBF5F5085DF4098476AFE4B9B1D2"
    );
    const found = decryptCableAdvert(advert, session.eidKey);
    expect(found?.plaintext.toString("hex")).toBe("008bb5c5c9a44d913a5eb20265550000");
    expect(cableConnectUrl(session, found!)).toBe(
      "wss://cable.ua5v.com/cable/connect/026555/367CBBF5F5085DF4098476AFE4B9B1D2"
    );

    const tampered = Buffer.from(advert);
    tampered[0]! ^= 1;
    expect(decryptCableAdvert(tampered, session.eidKey)).toBeUndefined();
    expect([0, 1, 255, 266, 0xf980].map(cableTunnelDomain)).toEqual([
      "cable.ua5v.com",
      "cable.auth.com",
      undefined,
      "cable.wufkweyy3uaxb.com",
      "cable.my4kstlhndi4c.net",
    ]);
  });

  it("completes the KNpsk0 handshake and reads the phone's first message", () => {
    const session = createCableQrSession("ga", {
      clock: { ...realMainClock, now: () => 1_767_225_600_000 },
      identityPrivateKey,
      qrSecret,
    });
    const found = decryptCableAdvert(advert, session.eidKey)!;
    const handshake = new CableHandshake(session, found, Buffer.alloc(32, 0x22));
    expect(handshake.message.toString("hex")).toBe(
      "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf350185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c912858409cd0eb0740bc491b6bf605730e469"
    );
    const crypter = handshake.finish(
      hex(
        "0451a7580833898ea1b183cbd7350a4099078c6ef1c1e18e970cd7683035f25e7d0110522712b0b5a7cff081685486984a94e6831edac46e7360fa9d834a7a81a1d51a859f2d69ab2dd7ab770d3f3a8c2c"
      )
    );
    const postHandshake = crypter.decrypt(
      hex(
        "640dbe36395a16c4156c1a1a45f858b19b1faf3e6bc1d2ea9ac830fc932e76145b9498f377ea4a4f7d35138c76b16ec2"
      )
    );
    expect(parsePostHandshake(postHandshake)).toEqual({
      revision: 1,
      getInfo: new Map([[1, ["FIDO_2_0"]]]),
    });
    expect(() => handshake.finish(Buffer.alloc(80))).toThrow();
  });

  it("encrypts transport messages with Chromium's padding and counter", () => {
    const crypter = new CableCrypter(
      hex("e34f1aa3747238c04d3bd25e07ef1b35fef359000d755615cd85be27cfc807d1"),
      hex("1fba3cce17622c68268d9f75b5a8a3351b517f096fb5e294941af7e3a6a8d6e1")
    );
    const ciphertext = crypter.encrypt(
      hex(
        "0101a60158203889285c8c6323950ced074984f9f9463bc1739bb621a9e5f1ee8dd9393ba28002a26269647818776562617574686e2e6669727374796561722e69642e6175646e616d657818776562617574686e2e6669727374796561722e69642e617503a362696450d6d7aa298fe84a06aaded7e49d900a62646e616d6561616b646973706c61794e616d6561610482a263616c672664747970656a7075626c69632d6b6579a263616c6739010064747970656a7075626c69632d6b65790581a2626964440001020364747970656a7075626c69632d6b657907a1627576f5"
      )
    );
    expect(ciphertext.toString("hex")).toBe(
      "5062cf34571e0827a7c0207f7c00184567d613eab0da080ad042d80664c59df7b01a13db17fd277575ccff53b6a34fdb4fbcf832f3d360f8e5a7daee7f265a9253a904d6ebff2f9370d35536d8bf054830aaadffb996b420b2b3170ac80a83796823ed3c284b177c23400ca0124d6a68263d39783cfef0273fdf3bfcfa0a6c33df319b126f6e8290d22c4cd32a7a978856ba2273d1be1c0a291e5ee197416aa0f7a104e4d0ac582b708482326d5ff0f1768c1416d016b1f89242e70e80312fe6b6d4029a40ada374b31e7d66fac3ba7283944b9b60da4b98f67804095fd39cd1d45d75c93d2d86cbfc21616f9f1a576ccf8c862ee185125fc1ed7ed2486e2c5fbfc39c919597dd86c338e7df553d51e8"
    );
  });

  it("accepts the getInfo of an iPhone, which omits the feature list", () => {
    const message = hex(
      "a101583aa40181684649444f5f325f300350f24a8e70d0d3f82c293732523cc4de5a04a262726bf5627576f5098268696e7465726e616c66687962726964"
    );
    const { getInfo } = parsePostHandshake(message);
    expect(getInfo.get(9)).toEqual(["internal", "hybrid"]);
    expect(getInfo.get(4)).toEqual(
      new Map([
        ["rk", true],
        ["uv", true],
      ])
    );
  });
});
