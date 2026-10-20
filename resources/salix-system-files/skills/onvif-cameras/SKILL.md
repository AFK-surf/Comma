---
name: onvif-cameras
description: "Read and control ONVIF IP cameras on the user's local network through a gateway (TP-LINK, Hikvision, Dahua and most other brands): device information, media profiles, PTZ pan/tilt/zoom, and taking a look through one frame of the video stream. Use with the home-gateway skill when the user asks about a network camera or what it sees."
activation: per-message
---

# ONVIF Cameras

ONVIF cameras speak SOAP 1.2 over HTTP. Send every request with
`device.lan_request` through a gateway: `method: "POST"`, the camera's
service URL as `url`, and the SOAP Envelope as `body`. Follow the
`/.runtime/skills/home-gateway/SKILL.md` instructions to find the gateway.

## Password

Calls other than `GetSystemDateAndTime` need the camera account. Cameras
refuse HTTP Basic and Digest; they answer `400` with `NotAuthorized` and
need a WS-Security header. Do not compute it yourself and do not hand it to
another agent: give `auth` and the platform adds the header.

```json
"auth": {"type": "onvif_ws_security", "username": "admin", "secret_ref": "office-camera"}
```

1. Call `device.secret_list` first. An `onvif_password` whose name or host
   matches the camera is its password: use its name as `secret_ref`.
2. If none matches, ask the user once for the camera's ONVIF username and
   password. Save the password with `device.secret_save`
   (`kind: "onvif_password"`, a short `name` such as `office-camera`, and the
   camera's `host` and `model`), then use the name. The username is not
   secret; give it in `auth.username` (often `admin`).
3. Never repeat, quote or summarize the password or any part of it, in a
   reply, your reasoning, a file or a memory.
4. Do not repeat the password from earlier messages, and never ask the user
   for a password that `device.secret_list` already names.

Do not put a `Security` header in `body`; the platform refuses it.

## Service URL

Most cameras serve every ONVIF service at one URL. TP-LINK cameras use
`http://<ip>:2020/onvif/service`; others often use port 80 with
`/onvif/device_service`. `GetCapabilities` returns each service's `XAddr` when
the URL is unknown.

## Requests

Every body is this Envelope with one operation inside `Body`:

```xml
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>OPERATION</s:Body></s:Envelope>
```

- Device information (model, firmware, serial):
  `<GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>`
- Camera clock, no `auth` needed:
  `<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>`
- Media profiles: `<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>`.
  Use the `token` attribute of a `Profiles` element (TP-LINK: `profile_1`) as
  `ProfileToken` below.
- Snapshot URI (then see Take a Look):
  `<GetSnapshotUri xmlns="http://www.onvif.org/ver10/media/wsdl"><ProfileToken>profile_1</ProfileToken></GetSnapshotUri>`
- Start moving (speeds from -1 to 1; positive x pans right, positive y tilts
  up, positive zoom zooms in):

  ```xml
  <ContinuousMove xmlns="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><ProfileToken>profile_1</ProfileToken><Velocity><tt:PanTilt x="0.5" y="0"/></Velocity><Timeout>PT1S</Timeout></ContinuousMove>
  ```

- Stop moving:
  `<Stop xmlns="http://www.onvif.org/ver20/ptz/wsdl"><ProfileToken>profile_1</ProfileToken><PanTilt>true</PanTilt><Zoom>true</Zoom></Stop>`

Always send `Stop` after `ContinuousMove`, even when the move had a
`Timeout`. Move only when the user asks, and in short steps.

## Take a Look

When the user asks what the camera sees ("看看办公室现在有没有人"), take one
frame of its video stream:

1. `device.lan_request` with `url: "rtsp://<ip>:554/stream2"` and
   `auth: {"type": "http_digest", "username": "admin", "secret_ref": "<name>"}`
   (the same saved password). On TP-LINK cameras use the sub stream,
   `/stream2` (H.264, 640×360, a frame in well under a second). The main
   stream, `/stream1`, is H.265, which is not read, and its bit rate fills a
   T-Circle's tunnel: do not use it. For another brand, read the path from
   ONVIF `GetStreamUri`.
   The result gives the picture's workspace `path`, and you see the picture.
2. Answer from what you see. Say only what the picture shows, and that it is
   one moment.
3. Offer to post the photo. When the user agrees, send it with
   `im_api.internal.send_message` and a content block
   `{"type": "image", "path": "<path>", "file_name": "snapshot.jpg"}`.

An rtsp:// url needs a gateway whose `lan_gateway` methods include
`lan_tcp_dial`. On `not_a_lan_gateway`, tell the user the gateway firmware or
connector needs an update, and stop.

A camera that answers `GetSnapshotUri` (many TP-LINK models do not) also
serves an HTTP snapshot: `device.lan_request` with that URI as `url`,
`response: "binary"` and the same `auth`, on a gateway whose `lan_gateway`
includes `response_chunks`. Do not fetch a snapshot as text: the body is
binary and larger than the 64 KB text limit.

On `gateway_busy`, the gateway (a T-Circle) is on a voice call and refuses
the transfer so the call does not stutter. Tell the user "正在通话，挂断后再拍"
(in their language) and stop; take the picture when they ask again after the
call. It is not a failure of the camera or the gateway.

Other frame errors: `camera_unauthorized` (do not retry, on either stream:
a TP-LINK camera locks the account after repeated failures; ask the user to
check the account and the saved password), `stream_not_found` (wrong path), `unsupported_codec` (the stream
is not H.264; use the camera's H.264 stream), `camera_redirected` (the camera
points elsewhere; this is not followed), `camera_timeout` (no key frame in
time; retry once with a longer `timeout_seconds`).

A snapshot is personal data. Take one only when the user asks, keep it in the
workspace, and post it only to the conversation that asked.

## Errors

- `400` with `NotAuthorized` in the body: the username or saved password is
  wrong, or the camera's clock is far from the real time. Call
  `GetSystemDateAndTime` and compare it with the current UTC time. If the
  clock is off by more than a few minutes, ask the user to fix the camera's
  time (NTP). Otherwise ask the user to check the account and save the
  password again under the same name.
- `saved_token_not_found` or `wrong_secret_kind`: no `onvif_password` is saved
  under that name. Check `device.secret_list`.
- `ActionNotSupported` or a SOAP `Fault` about the operation: the camera does
  not have it, for example PTZ on a fixed camera. Tell the user.
- Gateway errors (`gateway_offline`, `operations_not_allowed`,
  `gateway_timeout`): see the home-gateway skill.

## Sources

- [ONVIF Core Specification](https://www.onvif.org/specs/core/ONVIF-Core-Specification.pdf), 5.12 (user token)
- [ONVIF Application Programmer's Guide](https://www.onvif.org/wp-content/uploads/2016/12/ONVIF_WG-APG-Application_Programmers_Guide-1.pdf)
