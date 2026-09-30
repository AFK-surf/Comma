---
name: tailcat-ssh
description: Reach a user's own computer or server over SSH through Tailcat, with no public IP, open port, VPN or account. Guide the user to install tailcat and start its SSH server with the Group SSH key, then connect with ssh.open tailcat and work through the ssh.* tools.
---

# SSH Through Tailcat

Use this skill when the user wants you to work on their own machine (a laptop, a home server, a VM behind NAT or a firewall) and the machine has no public SSH address.
[Tailcat](https://github.com/tailscale/tailcat) runs on the user's machine and prints an address that starts with `tc`. You connect to that address with `ssh.open` and the `tailcat` argument.

The `ssh.*` tools are in the `ssh` help namespace: call `help` with `tool: "ssh"` to load them.
In the internal LLM runtime, invoke tools with `call(tool="<name>", params={...})`.

Use the user's conversation language. Keep commands, keys and addresses unchanged.

## How access works

- The Group SSH key authenticates you. The user's Tailcat server accepts only that key.
- Each connection uses a new, temporary Tailcat client key. So the user must not restrict clients with `tailcat serve --allow`: that server never answers you.
- The user keeps control: access ends when they stop the `tailcat` process.

## Guide the user

### 1. Get the Group public key

1. Call `ssh.public_key`.
2. Keep the returned `public_key` line (it starts with `ssh-ed25519`). You put it in the user's command below.

### 2. Install tailcat on the target machine

Ask which operating system the target machine runs. Then give the matching command:

- macOS: `brew install tailcat`
- Windows: `scoop install tailcat`
- Linux: download the `.deb`, `.rpm` or `.tar.gz` package for the machine's CPU from <https://github.com/tailscale/tailcat/releases>. Alternatives: `nix profile install nixpkgs#tailcat`, the AUR package `tailcat-bin`, or `go install github.com/tailscale/tailcat/cmd/tailcat@latest`.

Tailcat needs no root access, no open port and no account. It uses outbound connections only.

### 3. Start the SSH server

Give this command in one shell code block. Put the `public_key` line from step 1 inside the quotes:

```sh
tailcat serve --ssh-authorized-keys='<public_key line>' ssh
```

On Windows PowerShell, use double quotes around the key line.

This runs Tailcat's built-in SSH server. It gives a login shell, command execution and SFTP as the user who runs the command. It needs no `sshd` and does not change any SSH configuration.

Alternative, when the machine already runs OpenSSH `sshd` and the user prefers it:

1. Tell the user to append the `public_key` line to `~/.ssh/authorized_keys` of the account you will use.
2. Give `tailcat serve 22`. This forwards the Tailcat address to the local `sshd` on port 22.

Never suggest these options:

- `tailcat serve no-auth-ssh`: anyone who learns the address gets a shell.
- `--allow=...`: it rejects your temporary client key.
- `--derp-map-url` or a private relay: you can use only Tailscale's standard relays, so the connection fails with `tailcat_blocked_relay`.

### 4. Get the address

The server prints a line like `🐈 Server listening with new address: tcXXXX...`.
Ask the user to send you the address (the text that starts with `tc`), in this private conversation.
Also ask for the login name of the account that runs `tailcat` (with `tailcat serve 22`, the account that has the key in `authorized_keys`). The built-in server always uses the account that runs `tailcat`, whatever name you send.

The process must keep running while you work. If the user must close the terminal, suggest one of these:

- Run it inside `tmux` or `screen`.
- Run it in the background with the output in a log file, then read the address from the log:

  ```sh
  nohup tailcat serve --ssh-authorized-keys='<public_key line>' ssh < /dev/null > ~/tailcat.log 2>&1 &
  grep 'listening' ~/tailcat.log
  ```

### 5. Keep the same address (optional)

By default, each `tailcat serve` run creates a new address, and the old address stops working. This is the safest mode for one-time help.
For repeated access, the user can save a key once:

```sh
tailcat genkey --key=default
```

After that, `tailcat serve` uses the saved key and prints the same address on every start. Anyone who ever received that address can reach the server when it runs. The Group key requirement still protects it. To retire a saved address for good, the user runs `tailcat genkey --delete --key=default`.

The user can also publish a saved address as a DNS TXT record `tailcat=tc...` and give you the DNS name. Do this only with the `--ssh-authorized-keys` server above, never with `no-auth-ssh`.

## Connect

1. Call `ssh.open` with `tailcat` set to the address (or the DNS name) and `user` set to the login name. Do not pass `host`. `port` defaults to 22.
2. The first connection trusts and records the server's host key under the name `tailcat:nodekey:...`. A new address from a new `tailcat serve` run gets a new name, so its first connection records the key again.
3. Work with `ssh.write`, `ssh.read`, `ssh.screen`, `ssh.exec`, `ssh.upload`, `ssh.download` and `ssh.list_files`, as for any SSH session.
4. Call `ssh.close` when the work is done.

## Diagnose failures

| Code | Meaning | Action |
|---|---|---|
| `tailcat_unreachable` | The server did not answer within 10 seconds. | Ask whether `tailcat serve` still runs. Make sure the command has no `--allow`. Ask for the current address, because a restart without a saved key changes it. |
| `tailcat_invalid_address` | The address is incomplete or wrong, or the DNS name has no `tailcat=` TXT record. | Ask the user to copy the full address again. It is one word that starts with `tc`. |
| `tailcat_blocked_relay` | The address names a relay outside Tailscale's standard relays. | Ask the user to restart `tailcat serve` without `--derp-map-url` or other relay options. |
| `tailcat_connect_failed` | The server answered, but the port refused the connection. | With `tailcat serve 22`, make sure `sshd` runs. Otherwise make sure the command ends with `ssh`. Check `port`. |
| `auth_failed` | The server does not accept the Group SSH key. | Check that the quoted key line is complete and unchanged. With `sshd`, check `~/.ssh/authorized_keys` of that user. |
| `host_key_mismatch` | The server presents a different host key at the same address. | Stop. Tell the user the fingerprints. Continue only after the user confirms the change, then call `ssh.known_hosts.remove` with the `tailcat:nodekey:...` host. |
| `tailcat_unavailable`, `tailcat_relay_unavailable` | The platform side of Tailcat is not available. | Retry after a short wait. If it continues, tell the user. |

## Finish

1. Close your SSH sessions with `ssh.close`.
2. Tell the user that they can stop Tailcat with Ctrl-C (or stop the background process) to end all access.
3. If the user saved a key and wants no further access, tell them to run `tailcat genkey --delete --key=default`.
