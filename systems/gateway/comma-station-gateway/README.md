# comma-station-gateway

The gateway lets Salix call tools on still.fail stations enrolled in a Comma
workspace. Salix sends HTTP requests. The gateway forwards each request to the
station over iroh on ALPN `comma/tools/1` and returns the station response.
The wire contract is the station control-plane contract, sections 8 and 9.

## HTTP API

`POST /v1/stations/{station_id}/tools`

- Header: `authorization: Bearer <COMMA_STATION_GATEWAY_TOKEN>`.
- Body: `{"op", "args", "context", "id"?}`. `context` holds `workspace`,
  `user_id`, `user_email`, `agent` and `conversation`. If `id` is missing, the
  gateway uses `x-request-id` or makes a new id.

| Status | Body | Meaning |
|---|---|---|
| 200 | `{"ok":true,"result":…}` or `{"ok":false,"error":…}` | The station answered. |
| 400 | `{"ok":false,"error":{"code":"invalid_request"}}` | The request is not valid. |
| 401 | `{"ok":false,"error":{"code":"unauthorized"}}` | The token is missing or wrong. |
| 502 | `station_unreachable` | The request was not sent: no connection or stream, also when the deadline passes first. A retry is safe. |
| 502 | `station_disconnected` | The connection failed after the request was sent. The outcome is unknown. |
| 502 | `bad_station_response` | The request was sent, but the response is not a valid response header. The outcome is unknown. |
| 503 | `overloaded` | Too many requests are in flight. |
| 504 | `timeout` | The request was sent, and the station did not answer in time. The outcome is unknown. |

The gateway sends a request at most one time. It does not retry after the
first request byte can have left, because ops such as `exec` are not
idempotent. It can open a new connection before the request is sent.

The admin listener serves `/healthz`, `/readyz` and `/metrics`.

## Identity and connections

The gateway has one persistent iroh secret key. Its public key is the node id
that Comma publishes to stations in `gateway_keys`
(`COMMA_STATION_GATEWAY_KEYS`). Stations admit only those node ids.

- `comma-station-gateway generate-key` prints a new secret key and its node id.
- `comma-station-gateway node-id` prints the node id of the configured key.

The gateway dials a station by its id. It finds the relay and addresses of the
station on the Mainline DHT, where stations publish them. Its own home relay is
the nearest of `COMMA_STATION_RELAY_URLS`. It keeps one connection for each
station and closes connections that are idle.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `COMMA_STATION_GATEWAY_SECRET_KEY` or `COMMA_STATION_GATEWAY_SECRET_KEY_FILE` | required | 64 hex characters. |
| `COMMA_STATION_GATEWAY_TOKEN` | required | Bearer token for Salix, at least 32 characters. |
| `COMMA_STATION_RELAY_URLS` | none | Comma relay URLs, separated by commas. None disables relays. |
| `COMMA_STATION_DHT_LOOKUP` | `true` | Find stations on the Mainline DHT. |
| `COMMA_STATION_GATEWAY_LISTEN` | `0.0.0.0:8080` | Tools API. |
| `COMMA_STATION_GATEWAY_ADMIN_LISTEN` | `0.0.0.0:9090` | Health and metrics. |
| `COMMA_STATION_CONNECT_TIMEOUT_MS` | `10000` | Dial limit. |
| `COMMA_STATION_REQUEST_TIMEOUT_MS` | `60000` | Request limit. A larger `args.timeout_ms` plus 15 s extends it. |
| `COMMA_STATION_MAX_REQUEST_TIMEOUT_MS` | `900000` | Ceiling for the extended limit. |
| `COMMA_STATION_IDLE_TIMEOUT_MS` | `300000` | Idle connections close after this time. |
| `COMMA_STATION_MAX_CONNECTIONS` | `1024` | Cached station connections. |
| `COMMA_STATION_GATEWAY_MAX_IN_FLIGHT` | `256` | Concurrent requests. |
| `RUST_LOG` | `info,…` | Log filter. Logs are JSON lines. |

## Test

```sh
cargo test
```

The tests run a fake station in the same process and send requests through the
HTTP API. The Helm chart is in `k8s/comma-station-gateway`.
