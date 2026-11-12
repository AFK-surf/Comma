// Gree air conditioners over UDP 7000, after greeclimate's cipher.py and network.py. Run with device.lan_script.
// args: {host, status: [columns]} or {host, set: {column: integer}}; port only when the unit is not on 7000.
// Returns {host, mac, values, name?, model?}. Errors start with their code (device_not_answering, …).
//
// A scan returns the unit's mac and cipher, a bind returns its key, then the status or command. Older modules use
// AES-128-ECB, newer ones AES-128-GCM with a fixed nonce and associated data (a reply with a `tag` is GCM). The scan
// and bind use a key that is the same for every unit; the bind hands out the unit's own key.
var PORT = args.port || 7000;
var KEYS = { ecb: bytes.fromText("a3K8Bx%2r8Y7#xDh"), gcm: bytes.fromText("{yxAHAY_Lm6pbC/<") };
var NONCE = bytes.fromArray([0x54, 0x40, 0x78, 0x44, 0x49, 0x67, 0x5a, 0x51, 0x6c, 0x5e, 0x63, 0x13]);
var AAD = bytes.fromText("qualcomm-test");
var COLUMN = /^[A-Za-z0-9]{1,24}$/;
var host = args.host;

function fail(code, message) { throw new Error(code + ": " + message); }

if (typeof host !== "string" || !host) fail("bad_args", "host is required");
if (args.status && args.set) fail("bad_args", "give status or set, not both");
var cols = args.status, opt, p;
if (args.set) {
  opt = Object.keys(args.set).sort();
  p = opt.map(function (k) { return args.set[k]; });
  cols = opt;
  if (!p.every(function (v) { return typeof v === "number" && v % 1 === 0; })) fail("bad_args", "set values must be integers");
}
if (!cols || !cols.length || cols.length > 24 || !cols.every(function (c) { return typeof c === "string" && COLUMN.test(c); }))
  fail("bad_args", "give status (columns to read) or set (columns to change): at most 24 names of letters and digits");

// One datagram from a fresh socket; the first answer from the host belongs to it.
function exchange(text) {
  var r = lan.udp({ host: host, port: PORT, payload_b64: bytes.fromText(text), timeout_ms: 2000, max_responses: 1 });
  return r.responses.length ? bytes.toText(r.responses[0].payload_b64) : null;
}

function seal(pack, mac, key, cipher, i) {
  var plain = bytes.fromText(JSON.stringify(pack));
  if (cipher === "gcm") {
    var sealed = crypto.encrypt({ mode: "gcm", key: key, iv: NONCE, aad: AAD, data: plain });
    return JSON.stringify({ cid: "app", i: i, pack: sealed.data, t: "pack", tag: sealed.tag, tcid: mac, uid: 0 });
  }
  var pack64 = crypto.encrypt({ mode: "ecb", key: key, data: plain, padding: "pkcs7" });
  return JSON.stringify({ cid: "app", i: i, pack: pack64, t: "pack", tcid: mac, uid: 0 });
}

// The envelope's own fields are not authenticated; only the pack is trusted.
function open(text, keyFor) {
  try {
    var envelope = JSON.parse(text);
    if (!envelope || typeof envelope.pack !== "string") return null;
    var cipher = typeof envelope.tag === "string" ? "gcm" : "ecb", plain;
    if (cipher === "gcm") {
      plain = bytes.toText(crypto.decrypt({ mode: "gcm", key: keyFor(cipher), iv: NONCE, aad: AAD, data: envelope.pack, tag: envelope.tag }));
    } else {
      // Units pad with PKCS#7 or NUL bytes; the JSON ends at its last brace.
      plain = bytes.toText(crypto.decrypt({ mode: "ecb", key: keyFor(cipher), data: envelope.pack }));
      plain = plain.substring(0, plain.lastIndexOf("}") + 1);
    }
    var pack = JSON.parse(plain);
    return pack && typeof pack === "object" ? { pack: pack, cipher: cipher } : null;
  } catch (e) {
    return null;
  }
}

function generic(cipher) { return KEYS[cipher]; }

// Text the unit reports about itself: printable, at most 64 characters.
function text(value) {
  if (typeof value !== "string") return undefined;
  var t = value.replace(/[\x00-\x1f\x7f�]/g, "").slice(0, 64).trim();
  return t || undefined;
}

function malformed() { fail("device_reply_malformed", "The device at " + host + " answered with a packet that is not the Gree protocol."); }

// Scan: the unit's identity and cipher.
var reply = exchange('{"t":"scan"}');
if (reply === null) fail("device_not_answering", "The device at " + host + " is not answering on UDP 7000. Check the address with device.lan_discover and that the unit has power.");
var scan = open(reply, generic);
var mac = scan && scan.pack.t === "dev" ? scan.pack.mac || scan.pack.cid : null;
if (typeof mac !== "string" || !/^[0-9A-Za-z@]{1,40}$/.test(mac)) malformed();
var unit = { cipher: scan.cipher, name: text(scan.pack.name), model: text(scan.pack.model) };

// Bind: the unit's key. A module that answers the scan with the older cipher can still require the newer one.
var key = null, cipher = null;
var ciphers = unit.cipher === "ecb" ? ["ecb", "gcm"] : ["gcm"];
for (var i = 0; i < ciphers.length && key === null; i++) {
  reply = exchange(seal({ mac: mac, t: "bind", uid: 0 }, mac, KEYS[ciphers[i]], ciphers[i], 1));
  if (reply === null) continue;
  var bound = open(reply, generic);
  var k = bound && bound.pack.t === "bindok" && bound.pack.mac === mac ? bound.pack.key : null;
  if (typeof k !== "string" || bytes.length(bytes.fromText(k)) !== 16) malformed();
  key = bytes.fromText(k);
  cipher = ciphers[i];
}
if (key === null) fail("device_bind_failed", "The unit at " + host + " did not answer the bind request, so it cannot be controlled from this network. Its Wi-Fi module may only accept its own app.");

// The status or the command.
reply = exchange(args.set
  ? seal({ opt: opt, p: p, t: "cmd" }, mac, key, cipher, 0)
  : seal({ cols: cols, mac: mac, t: "status" }, mac, key, cipher, 0));
if (reply === null) fail("device_no_reply", "The unit did not answer the request. A change may have been applied. Read its state before retrying.");
var answer = open(reply, function () { return key; });
var pack = answer ? answer.pack : {};
if (pack.mac === mac && typeof pack.r === "number" && pack.r !== 200) fail("device_error", "The unit refused the request with code " + pack.r + ".");
var names, values;
if (pack.t === "dat" && pack.mac === mac) {
  names = pack.cols;
  values = pack.dat;
} else if (pack.t === "res" && pack.mac === mac) {
  // Some modules answer with an empty `val` and the values in `p`.
  names = pack.opt;
  values = pack.val === undefined || pack.val === null || (Array.isArray(pack.val) && !pack.val.length) ? pack.p : pack.val;
}
if (!Array.isArray(names) || !Array.isArray(values) || names.length !== values.length ||
    !names.every(function (n) { return typeof n === "string"; })) malformed();
var result = { host: host, mac: mac, values: {} };
names.forEach(function (n, j) { result.values[n] = values[j]; });
if (unit.name) result.name = unit.name;
if (unit.model) result.model = unit.model;
return result;
