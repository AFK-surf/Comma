---
name: colab-gpu
description: Run GPU/CPU workloads on connected Google Colab accounts via colab.* tools (exec, upload, download, stop) and Coding Sandbox staging.
---

# Google Colab GPU Compute

Use this skill when the user wants to run GPU-accelerated workloads (PyTorch, CUDA, Blender/Cycles rendering, video/audio processing, model inference or fine-tuning) on their connected Google Colab account.

The `colab.*` tools live in the hidden `colab` help namespace. Call `help` with `tool: "colab"` to load their schemas before your first call.
In the internal LLM runtime, invoke tools with `call(tool="<name>", params={...})`.

Use the user's conversation language. Keep tool names, GPU codes, paths and commands unchanged.

## Before you start

1. Call `colab.status` to inspect connected Google Colab accounts (remaining Compute Units, hourly burn rate, active VMs) and any VMs already owned by this session or Task.
2. If the `google-colab` plugin is not yet installed or no Google Colab account is connected (or `colab.*` tools are not offered):
   - **Router**: call `plugin.request_install` with `plugin_id: "google-colab"` and a concise `reason` explaining the GPU task so Comma renders the native install card in chat.
   - Wait for the user to complete the 2-step Google sign-in and authorization code paste (or enable the **Google Colab** plugin under **Plugins**) before retrying `colab.status`.

## Running GPU commands

- Call `colab.exec` with `command` and optional `gpu` (`G4`, `L4`, `T4`, `A100`, `H100`, or `CPU`; defaults to `G4`) and `high_mem` (`true`/`false`).
- Omit `vm_id` on your first call: Comma reuses a warm matching VM owned by this session/Task or allocates a new one automatically.
- Reuse the returned `vm_id` on subsequent `colab.exec`, `colab.upload`, and `colab.download` calls targeting the same runtime.
- Default working directory is `/content`.
- Each command runs up to `timeout_seconds` (default 120, max 600).

## Long-running background jobs

Colab VMs are automatically released after **180 seconds** of inactivity once no tool call is running.
For jobs that take longer than one `colab.exec` call:

1. Start the job detached in the background and pass `hold_minutes` (1..720, up to 12 hours) so the VM stays alive between status checks:

   ```sh
   nohup python3 train.py < /dev/null > /content/train.log 2>&1 &
   echo $!
   ```

2. Poll progress later with `colab.exec` (`vm_id` set) by checking `ps -p <pid>` and `tail -n 50 /content/train.log`.
3. Download results with `colab.download` once finished.

## Moving files (including from a Coding Sandbox)

- `colab.upload` streams up to **1 GiB** from the Agent workspace (VFS) or `/drive/...` onto the Colab VM (default `/content/<basename>`).
- `colab.download` streams up to **1 GiB** from the Colab VM into VFS or `/drive/...`.
- **From a Coding Sandbox Task (`salix_call`)**: the sandbox's local filesystem is separate from Salix VFS. Stage files through VFS (or `/drive/...`) using `env.copy` with `src_environment: "self"` or `dst_environment: "self"`:
  - Upload to Colab: `env.copy` (`src_environment: "self"`, `dst_environment: "vfs"`, `dst_path: "/.colab-stage/<task_id>/input.tar.gz"`) → `colab.upload` (`source: "/.colab-stage/<task_id>/input.tar.gz"`).
  - Download from Colab: `colab.download` (`destination: "/.colab-stage/<task_id>/out.png"`) → `env.copy` (`src_environment: "vfs"`, `dst_environment: "self"`).
  - Note: files written to `/drive/...` are persistent and visible to Workspace members; use `/.colab-stage/<task_id>/...` in VFS for temporary staging.

## Stopping VMs (always end billing)

- Always call `colab.stop` with `vm_id` (or pass `stop_after: true` on your final `colab.exec`) as soon as your work is complete so Google Colab Compute Units stop accruing.
- Disabling the Google Colab plugin hides `colab.*` (including `colab.stop`); idle VMs are then released automatically after 180 seconds by the background Reaper.
- Only report that billing has stopped when `colab.stop` returns `"billing_stopped": true`. If it returns `"state": "unassign_unconfirmed"`, tell the user their Google authorization was revoked and they should either reconnect the same Google account under **Plugins → Google Colab** or terminate the runtime directly in Google Colab.
