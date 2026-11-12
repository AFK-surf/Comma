// SPDX-License-Identifier: Apache-2.0
// The LAN script API on one runtime: run by this host test (firmware) and by the station's runner tests
// (Cue), so both platforms give the same answers. Returns "ok" or throws naming the first difference.
// The vectors are NIST SP 800-38A (AES-ECB/CBC), the GCM spec's test case 4, RFC 1321, FIPS 180 and RFC 4231.
function same(name, got, want) {
  if (got !== want) throw new Error(name + ": got " + got + ", want " + want);
}
function throwsLike(name, f, pattern) {
  try { f(); } catch (e) {
    if (!pattern.test(String(e))) throw new Error(name + ": threw " + e);
    return;
  }
  throw new Error(name + ": did not throw");
}
var hex = bytes.fromHex, toHex = bytes.toHex;

same("fromText", bytes.fromText("héllo"), "aMOpbGxv");
same("toText", bytes.toText("aMOpbGxv"), "héllo");
same("toText invalid", bytes.toText(bytes.fromArray([0x61, 0xff, 0x62])), "a�b");
same("hex", toHex(hex("00ff10Ab")), "00ff10ab");
same("array", bytes.toArray(hex("0102ff")).join(","), "1,2,255");
same("fromArray", toHex(bytes.fromArray([1, 2, 255, 256])), "0102ff00");
same("concat", toHex(bytes.concat([hex("01"), "", hex("0203")])), "010203");
same("slice", toHex(bytes.slice(hex("0102030405"), 1, -1)), "020304");
same("slice open", toHex(bytes.slice(hex("0102030405"), -2)), "0405");
same("length", bytes.length(hex("0102030405")), 5);
throwsLike("bad base64", function () { bytes.toHex("abc"); }, /base64/);
throwsLike("bad hex", function () { hex("0g"); }, /hex/);

same("md5", toHex(crypto.hash("md5", bytes.fromText("abc"))), "900150983cd24fb0d6963f7d28e17f72");
same("sha1", toHex(crypto.hash("sha1", bytes.fromText("abc"))), "a9993e364706816aba3e25717850c26c9cd0d89d");
same("sha256", toHex(crypto.hash("sha256", bytes.fromText("abc"))),
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
same("hmac", toHex(crypto.hmac("sha256", hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), bytes.fromText("Hi There"))),
  "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
same("hmac empty key", toHex(crypto.hmac("md5", "", "")), "74e6f7298a9c2d168935f58c001bad88");
same("random", bytes.length(crypto.randomBytes(16)), 16);

var key = hex("2b7e151628aed2a6abf7158809cf4f3c");
var plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51");
same("ecb", toHex(crypto.encrypt({ mode: "ecb", key: key, data: plain })),
  "3ad77bb40d7a3660a89ecaf32466ef97f5d3d58503b9699de785895a96fdbaaf");
same("ecb back", crypto.decrypt({ mode: "ecb", key: key, data: crypto.encrypt({ mode: "ecb", key: key, data: plain }) }), plain);
var iv = hex("000102030405060708090a0b0c0d0e0f");
same("cbc", toHex(crypto.encrypt({ mode: "cbc", key: key, iv: iv, data: plain })),
  "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b2");
var padded = crypto.encrypt({ mode: "cbc", key: key, iv: iv, data: bytes.fromText("hello"), padding: "pkcs7" });
same("pkcs7 length", bytes.length(padded), 16);
same("pkcs7 back", bytes.toText(crypto.decrypt({ mode: "cbc", key: key, iv: iv, data: padded, padding: "pkcs7" })), "hello");
throwsLike("bad padding", function () { crypto.decrypt({ mode: "ecb", key: key, data: plain, padding: "pkcs7" }); }, /padding/);
throwsLike("not a block", function () { crypto.encrypt({ mode: "ecb", key: key, data: hex("01") }); }, /multiple of 16/);
throwsLike("bad key", function () { crypto.encrypt({ mode: "ecb", key: hex("01"), data: plain }); }, /key/);

var gk = hex("feffe9928665731c6d6a8f9467308308");
var gp = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39");
var gn = hex("cafebabefacedbaddecaf888");
var ga = hex("feedfacedeadbeeffeedfacedeadbeefabaddad2");
var sealed = crypto.encrypt({ mode: "gcm", key: gk, iv: gn, aad: ga, data: gp });
same("gcm", toHex(sealed.data), "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091");
same("gcm tag", toHex(sealed.tag), "5bc94fbc3221a5db94fae95ae7121a47");
same("gcm back", crypto.decrypt({ mode: "gcm", key: gk, iv: gn, aad: ga, data: sealed.data, tag: sealed.tag }), gp);
throwsLike("gcm forged", function () {
  crypto.decrypt({ mode: "gcm", key: gk, iv: gn, aad: ga, data: sealed.data, tag: hex("00000000000000000000000000000000") });
}, /tag/);

same("args", JSON.stringify(args), "{\"n\":1}");
console.log("selftest", { done: true });
return "ok";
