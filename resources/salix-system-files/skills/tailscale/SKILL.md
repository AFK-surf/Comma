---
name: tailscale
description: Connect the Group to the user's own Tailscale network (tailnet) and reach the devices there. Guide a tailnet admin to approve the Group's node with a login link and to grant its tag access, then use tailnet.peers, ssh.open with via_tailnet and web.http_request with via_tailnet.
---

# Tailscale Network

Use this skill when the user wants you to reach devices in their Tailscale network: a home server, a NAS, a Raspberry Pi, a dashboard or an API on a private address.
The Group has at most one node in one tailnet. All Agents of the Group use it.

The `tailnet.*` tools are in the `tailnet` help namespace: call `help` with `tool: "tailnet"` to load them.
In the internal LLM runtime, invoke tools with `call(tool="<name>", params={...})`.

Use the user's conversation language. Keep commands, tags, names and addresses unchanged.

## Check the current state

1. Call `tailnet.status`.
2. Read `state`:
   - `disabled`: the Group has no tailnet. Connect it (below).
   - `running` or `idle`: the node is in the tailnet. `idle` means it is offline until the next use; any tailnet call starts it.
   - `needs_login`: a tailnet admin must open `login_url`.
   - `needs_approval`: the tailnet requires device approval. A tailnet admin approves the node in the Tailscale admin console.
   - `error`: read `error.code` (see Errors).

## Connect the Group

Only the Router connects or disconnects the Group. A Worker asks the Router or the user.
The user can also do this in the Comma app settings or the Bridge For Teams dashboard.

### 1. Prepare the tailnet policy

The Group's node requests the tag `tag:comma-agent`. A tagged node does not expire, and the tailnet policy controls exactly what it can reach.
Ask the tailnet admin to add the tag and a grant to the tailnet policy file (Access controls in the Tailscale admin console). Example:

```json
{
  "tagOwners": {
    "tag:comma-agent": ["autogroup:admin"]
  },
  "grants": [
    { "src": ["tag:comma-agent"], "dst": ["tag:homelab"], "ip": ["22", "443"] }
  ]
}
```

Adapt `dst` and `ip` to the devices and ports the user wants you to reach. Keep the grant narrow.
If the admin does not want a tag, call `tailnet.connect` with `tags: []`. The node then belongs to the approving user, has that user's access, and its key expires (usually after 180 days).

### 2. Get the login link

1. Ask for the tailnet name, as the admin console shows it (for example `example.com`, `user@gmail.com`, or the MagicDNS suffix `tail1234.ts.net`).
2. Call `tailnet.connect` with `expected_tailnet` set to that name. Add `accept_routes: true` only when the user wants to reach subnets that a subnet router advertises.
3. When `state` is `needs_login`, send `login_url` to the tailnet admin, only in a private conversation with them. Whoever opens and approves the link adds the Group's node to their tailnet.
4. The admin opens the link and approves the node. If the tag owner is a group of admins, the approving user must be in it.
5. Call `tailnet.status` until `state` is `running`.

The link stops working after 30 minutes. Call `tailnet.connect` again for a new one.

## Reach devices

1. Call `tailnet.peers` to list the devices: name, MagicDNS name, addresses, OS, online state and approved subnet routes.
2. SSH: call `ssh.open` with `host` set to the MagicDNS name or address and `via_tailnet: true`.
   - The Group SSH key authenticates. Call `ssh.public_key` and ask the user to add the `public_key` line to `~/.ssh/authorized_keys` on the device.
   - Tailscale SSH is not used: the device must run its own SSH server.
3. HTTP: call `web.http_request` with the device URL and `via_tailnet: true`. HTTPS works with certificates for the device's name, such as `https://nas.tail1234.ts.net`.

## Errors

- `tailnet_not_configured`: the Group has no tailnet. Connect it.
- `tailnet_needs_login`: the node waits for approval, or its key expired. Call `tailnet.status` (Router: it includes a new `login_url`).
- `tailnet_mismatch`: the link was approved in another tailnet. The node left that tailnet. Check the tailnet name with the user, then connect again.
- `tailnet_host_unknown`: no peer has that name. Call `tailnet.peers`.
- `tailnet_destination_not_allowed`: the address is not a peer and not inside an approved subnet route. Only tailnet devices are reachable through the node.
- `tailnet_connect_failed`: the device is offline, the tailnet policy does not grant the port to `tag:comma-agent`, or nothing listens on the port. Ask the admin to check the grant.
- `tailnet_unavailable` or `tailnet_starting`: retry after a few seconds.

## Disconnect

Call `tailnet.disconnect` with `user_confirmed: true` only after the user confirms. The node logs out and leaves the tailnet. Reconnecting needs a new login link.

## Never suggest

- Pasting an auth key, an OAuth client secret or an API key. The Group needs only the login link.
- Using the Group's node as an exit node, or reaching the internet through the tailnet.
- Granting `tag:comma-agent` access to `*` when the user wants only some devices.
