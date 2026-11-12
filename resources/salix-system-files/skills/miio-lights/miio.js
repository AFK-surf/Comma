// Xiaomi miIO over UDP 54321, after python-miio's miio/protocol.py. Run with device.lan_script.
// args: {host, token, method, params?, id?, port?}; token is the saved miio_token, given with
// secrets: {"token": "<its name>"}. id is the message id (1 to 9999, random when omitted).
// Returns {host, result}. Errors start with their code (device_not_answering, bad_token, …).
//
// Every packet starts with a 32-byte header: magic 0x2131, total length, 0x00000000, the device id, a stamp and a
// checksum. A hello is that header with every other byte 0xFF; the device answers with its id and stamp. A command
// carries JSON {"id","method","params"} and a NUL, encrypted with AES-128-CBC (key MD5(token), iv MD5(key ‖ token),
// PKCS#7), and the checksum MD5(header[0..16] ‖ token ‖ ciphertext). Replies are checked and decrypted the same way.
var PORT = args.port || 54321;
var host = args.host;

function fail(code, message) { throw new Error(code + ": " + message); }

if (typeof host !== "string" || !host) fail("bad_args", "host is required");
if (typeof args.method !== "string" || !args.method) fail("bad_args", "method is required");
var params = args.params === undefined ? [] : args.params;
if (typeof params !== "object" || params === null) fail("bad_args", "params must be an array or an object");
if (typeof args.token !== "string" || !/^[0-9A-Fa-f]{32}$/.test(args.token)) fail("bad_token", "The saved token is not 32 hex characters. Ask the user for the correct token and save it again.");

var token = bytes.fromHex(args.token);
var key = crypto.hash("md5", token);
var iv = crypto.hash("md5", bytes.concat([key, token]));

function u16(n) { return [(n >> 8) & 255, n & 255]; }
function u32(n) { return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]; }

function exchange(packet, timeout, max) {
  return lan.udp({ host: host, port: PORT, payload_b64: packet, timeout_ms: timeout, max_responses: max }).responses;
}

// Hello: the device's id and stamp.
var hello = [0x21, 0x31, 0x00, 0x20];
for (var i = 0; i < 28; i++) hello.push(0xff);
var replies = exchange(bytes.fromArray(hello), 2000, 1);
if (!replies.length) fail("device_not_answering", "The device at " + host + " is not answering on UDP 54321. Check the address with device.lan_discover and that the device is powered.");
var h = bytes.toArray(replies[0].payload_b64);
if (h.length !== 32 || h[0] !== 0x21 || h[1] !== 0x31 || h[2] !== 0 || h[3] !== 32)
  fail("device_reply_malformed", "The device at " + host + " answered with a packet this protocol does not recognize.");
var deviceId = h.slice(8, 12);
var stamp = ((h[12] << 24) >>> 0) + (h[13] << 16) + (h[14] << 8) + h[15];

// The command. Ids run from 1 to 9999.
var id = args.id >= 1 && args.id <= 9999 && args.id % 1 === 0 ? args.id : 1 + Math.floor(Math.random() * 9999);
var plain = bytes.concat([bytes.fromText(JSON.stringify({ id: id, method: args.method, params: params })), bytes.fromArray([0])]);
var ciphertext = crypto.encrypt({ mode: "cbc", key: key, iv: iv, data: plain, padding: "pkcs7" });
var header = bytes.fromArray([0x21, 0x31].concat(u16(32 + bytes.length(ciphertext)), [0, 0, 0, 0], deviceId, u32((stamp + 1) >>> 0)));
var checksum = crypto.hash("md5", bytes.concat([header, token, ciphertext]));
replies = exchange(bytes.concat([header, checksum, ciphertext]), 3000, 16);

// The sent request owns the message id and the hello owns the device id: a stale or other-device packet does not
// complete this command, even with a valid checksum. Otherwise the last unusable reply says what went wrong.
var payload = null, last = null;
for (var r = 0; r < replies.length && payload === null; r++) {
  var packet = replies[r].payload_b64, length = bytes.length(packet);
  var head = bytes.toArray(bytes.slice(packet, 0, 16));
  if (length <= 32 || head[0] !== 0x21 || head[1] !== 0x31 || head[2] * 256 + head[3] !== length) {
    last = "malformed";
    continue;
  }
  var body = bytes.slice(packet, 32);
  if (bytes.toHex(bytes.slice(packet, 16, 32)) !== bytes.toHex(crypto.hash("md5", bytes.concat([bytes.slice(packet, 0, 16), token, body])))) {
    last = "bad_token";
    continue;
  }
  var decoded = null;
  try {
    decoded = JSON.parse(bytes.toText(crypto.decrypt({ mode: "cbc", key: key, iv: iv, data: body, padding: "pkcs7" })).split("\u0000")[0]);
  } catch (e) {}
  if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) last = "malformed";
  else if (decoded.id === id && head.slice(8, 12).join() === deviceId.join()) payload = decoded;
}
if (payload === null) {
  if (last === "bad_token") fail("bad_token", "The saved token could not verify the reply. Ask the user to check the token and save it with device.secret_save.");
  if (last === "malformed") fail("device_reply_malformed", "The device at " + host + " answered with a packet this protocol does not recognize.");
  fail("device_no_reply", "The device did not return a matching command reply. The command may have executed. Read its state before retrying.");
}
if (payload.error !== undefined) {
  var error = payload.error, code = error && typeof error === "object" ? error.code : undefined;
  var message = error && typeof error === "object" ? error.message : error;
  fail("device_error", "The device answered with an error" + (code !== undefined ? " " + code : "") + ": " + String(message).slice(0, 300));
}
return { host: host, result: payload.result === undefined ? null : payload.result };
