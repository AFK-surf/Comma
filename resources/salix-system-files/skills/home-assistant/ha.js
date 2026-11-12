// Home Assistant's REST API (https://developers.home-assistant.io/docs/api/rest/) through the gateway. Run with
// device.lan_script and secrets: {"token": "<saved api_token>"}.
// args: {host, token, path, method?, body?, port?, https?}: path such as /api/states or
// /api/services/light/turn_on; body (an object) goes as JSON. Returns {status, body} (body parsed when it is JSON).
var host = args.host;
function fail(code, message) { throw new Error(code + ": " + message); }
if (typeof host !== "string" || !host) fail("bad_args", "host is required");
if (typeof args.token !== "string" || !args.token) fail("bad_token", "No Home Assistant token: give secrets {\"token\": \"<saved api_token>\"}.");
if (typeof args.path !== "string" || args.path.indexOf("/api/") !== 0) fail("bad_args", "path must start with /api/");
var method = (args.method || (args.body === undefined ? "GET" : "POST")).toUpperCase();
var request = {
  method: method,
  url: (args.https ? "https://" : "http://") + host + ":" + (args.port || 8123) + args.path,
  headers: { Authorization: "Bearer " + args.token, Accept: "application/json" },
  timeout_seconds: 20
};
if (args.body !== undefined) request.body = JSON.stringify(args.body);
var reply = lan.http(request);
if (reply.status === 401) fail("bad_token", "Home Assistant refused the token. Ask the user for a new long-lived access token and save it again.");
var body = reply.body;
try { body = JSON.parse(reply.body); } catch (e) {}
if (reply.status >= 400) fail("ha_error", "Home Assistant answered HTTP " + reply.status + ": " + String(reply.body).slice(0, 300));
var result = { status: reply.status, body: body };
if (reply.truncated) result.truncated = true;
return result;
