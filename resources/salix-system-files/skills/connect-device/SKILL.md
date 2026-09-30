---
name: connect-device
description: Install and connect a Mac or Linux computer directly to Comma with local consent, then verify Connector file access and discovered agents.
---

# Connect Another Computer

Use the language requested by the localized connection draft, or the user's conversation language.
Keep commands, device IDs, paths, and verification text unchanged.

## Install

1. Call `device.create_connector_install_command` with a suitable device name.
2. Retain `device_id`, `command`, `registration_expires_at`, `verification_path`, and `verification_content`.
3. Give `command` unchanged in one shell code block in the authorized private conversation.
4. Ask the user to run it on the target computer and type `yes` at its local consent prompt.
5. Explain that access starts read-only and runs in the background until reboot, without a startup service.

The target needs curl, nohup, and a POSIX shell. The installer selects macOS/Linux arm64 or x86_64.
Installation does not require Drive, SSH, or `env.remote_shell`.
The command contains a workspace credential.
Do not send it through a native Runtime. Use the same command after an uncertain result.
Do not create another credential merely because registration is slow.
First registration must occur before `registration_expires_at`. That deadline does not expire an already registered device.
If the user cancels, stop setup. Existing device removal and credential revocation cancel access.

## Verify

1. Call `device.get` for the retained exact device ID.
2. Inspect its connection, stable environment ID, and discovered agents.
3. Call `env.copy` with that `src_device_id`, `src_environment`, and `verification_path`.
   Use `dst_environment: "vfs"` and `dst_path: "device-checks/<device_id>.txt"`.
4. Read the copied file with `fs.read_file` and compare it with `verification_content`, ignoring the final newline.

Device status alone does not pass verification. A timeout or disconnect is not success.
If copying fails, diagnose it without enabling operations for this read test.
Before retrying installation, query the same device. Do not replay unrelated commands.

## Finish

After the file check succeeds, state that verification passed and the user can close the target terminal.
Connector continues running until the target computer restarts.
Use the device name or the localized term for target computer.
Reserve this computer for the client identified by the initiating Message.
Report empty agent discovery accurately. Registration and file access do not prove a Worker completed a task.
When the user enables operations, use `env.runtime_targets` and the existing Worker flow.
