// Network printers over IPP (RFC 8010/8011, IPP Everywhere). Run with device.lan_script.
// args.action:
//   "status": printer state, reasons, ink and paper (Get-Printer-Attributes);
//   "print": one document (Print-Job): document (base64, give it with files), format (default image/jpeg), copies,
//            color ("monochrome" by default or "color"), scaling (default "fit"), job_name;
//   "validate": the same checks without printing (Validate-Job);
//   "job": a job's state (Get-Job-Attributes, job_id).
// Common args: host, port (631), path (/ipp/print).
// Returns the decoded IPP answer: {status, ok, operation, printer?, job?}. Errors start with their code.
var action = args.action || "status";
var host = args.host;
function fail(code, message) { throw new Error(code + ": " + message); }
if (typeof host !== "string" || !host) fail("bad_args", "host is required");

var OPS = { print: 0x0002, validate: 0x0004, job: 0x0009, status: 0x000b };
if (!OPS[action]) fail("bad_args", "action must be status, print, validate or job");
var port = args.port || 631, path = args.path || "/ipp/print";

// ── IPP encoding ──
var out = [];
function u16(n) { out.push((n >> 8) & 255, n & 255); }
function u32(n) { out.push((n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255); }
function text(s) { return bytes.toArray(bytes.fromText(s)); }
function attr(tag, name, values) {
  if (!Array.isArray(values)) values = [values];
  values.forEach(function (value, i) {
    out.push(tag);
    var n = i === 0 ? text(name) : [];
    u16(n.length); out.push.apply(out, n);
    if (tag === 0x21 || tag === 0x23) { u16(4); u32(value); }
    else { var v = text(String(value)); u16(v.length); out.push.apply(out, v); }
  });
}
out.push(2, 0); u16(OPS[action]); u32(1);
out.push(0x01);
attr(0x47, "attributes-charset", "utf-8");
attr(0x48, "attributes-natural-language", "en");
attr(0x45, "printer-uri", "ipp://" + host + ":" + port + path);
attr(0x42, "requesting-user-name", "comma");
if (action === "status") {
  attr(0x44, "requested-attributes", ["printer-state", "printer-state-reasons", "printer-state-message", "marker-names",
    "marker-levels", "marker-colors", "media-ready", "document-format-supported", "printer-make-and-model"]);
}
if (action === "job") {
  if (!(args.job_id > 0)) fail("bad_args", "job_id is required");
  attr(0x21, "job-id", args.job_id);
}
var documentB64 = "";
if (action === "print" || action === "validate") {
  attr(0x42, "job-name", args.job_name || "Comma");
  attr(0x49, "document-format", args.format || "image/jpeg");
  out.push(0x02);
  attr(0x21, "copies", args.copies || 1);
  attr(0x44, "print-color-mode", args.color || "monochrome");
  attr(0x44, "print-scaling", args.scaling || "fit");
  if (action === "print") {
    if (typeof args.document !== "string" || !args.document) fail("bad_args", "document (base64) is required: give it with files");
    documentB64 = args.document;
  }
}
out.push(0x03);
var body = bytes.concat([bytes.fromArray(out), documentB64]);
var head = "POST " + path + " HTTP/1.1\r\nHost: " + host + ":" + port + "\r\nContent-Type: application/ipp\r\n" +
  "Content-Length: " + bytes.length(body) + "\r\nConnection: close\r\n\r\n";

// ── HTTP over lan.tcp ──
var reply = lan.tcp({ host: host, port: port, send_b64: bytes.concat([bytes.fromText(head), body]), timeout_ms: 25000, idle_ms: 5000 });
var hex = bytes.toHex(reply.data_b64), at = -1;
for (var k = hex.indexOf("0d0a0d0a"); k >= 0; k = hex.indexOf("0d0a0d0a", k + 1)) if (k % 2 === 0) { at = k; break; }
if (at < 0) {
  if (action === "print") fail("printer_no_answer", "The printer did not answer. The job may have been printed: check with status before printing again.");
  fail("printer_no_answer", "The printer at " + host + ":" + port + " did not answer over IPP.");
}
var headers = bytes.toText(bytes.fromHex(hex.substring(0, at)));
var status = /^HTTP\/1\.[01] (\d+)/.exec(headers);
if (!status || status[1] !== "200") fail("printer_http_error", "The printer answered " + (status ? "HTTP " + status[1] : "something other than HTTP") + " on " + path + ".");
var payload = hex.substring(at + 8);
if (/transfer-encoding:\s*chunked/i.test(headers)) {
  var joined = "";
  for (var p = 0; p < payload.length;) {
    var line = payload.indexOf("0d0a", p);
    while (line >= 0 && line % 2) line = payload.indexOf("0d0a", line + 1);
    if (line < 0) break;
    var size = parseInt(bytes.toText(bytes.fromHex(payload.substring(p, line))), 16);
    if (!(size > 0)) break;
    joined += payload.substring(line + 4, line + 4 + size * 2);
    p = line + 4 + size * 2 + 4;
  }
  payload = joined;
}

// ── IPP decoding ──
var b = bytes.toArray(bytes.fromHex(payload)), i = 8;
if (b.length < 9) fail("printer_reply_malformed", "The printer's IPP answer is too short.");
var code = (b[2] << 8) | b[3];
var groups = { 1: "operation", 2: "job", 4: "printer" }, group = null, last = null, result = {};
function str(from, to) { return bytes.toText(bytes.fromArray(b.slice(from, to))); }
while (i < b.length) {
  var tag = b[i++];
  if (tag === 0x03) break;
  if (tag < 0x10) { group = groups[tag] || "other"; result[group] = result[group] || {}; continue; }
  var nl = (b[i] << 8) | b[i + 1]; i += 2;
  var name = nl ? str(i, i + nl) : last; i += nl;
  var vl = (b[i] << 8) | b[i + 1]; i += 2;
  var value;
  if ((tag === 0x21 || tag === 0x23) && vl === 4) value = ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]);
  else if (tag === 0x22) value = b[i] === 1;
  else if (tag >= 0x40) value = str(i, i + vl);
  else value = bytes.toHex(bytes.fromArray(b.slice(i, i + vl)));
  i += vl;
  if (!group) continue;
  var into = result[group];
  if (!nl && into[name] !== undefined) into[name] = [].concat(into[name], [value]);
  else into[name] = value;
  last = name;
}
var printerStates = { 3: "idle", 4: "processing", 5: "stopped" };
var jobStates = { 3: "pending", 4: "pending-held", 5: "processing", 6: "processing-stopped", 7: "canceled", 8: "aborted", 9: "completed" };
if (result.printer && printerStates[result.printer["printer-state"]]) result.printer["printer-state"] = printerStates[result.printer["printer-state"]];
if (result.job && jobStates[result.job["job-state"]]) result.job["job-state"] = jobStates[result.job["job-state"]];
delete result.operation;
result.status = "0x" + ("000" + code.toString(16)).slice(-4);
result.ok = code < 0x0100;
return result;
