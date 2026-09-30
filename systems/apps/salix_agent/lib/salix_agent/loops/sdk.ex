defmodule SalixAgent.Loops.Sdk do
  @moduledoc """
  What an Agent reads before it writes a background Loop: the exact C SDK
  header the pinned spinfoam binary compiles against (`spinfoam --dump-sdk`,
  cached per node) and a fixed programming guide that states the target's
  constraints, the handle model and the host capability contract
  (docs/salix/tasks-background-execution.md, "Background loops").

  This is an interface contract, not a template: it ships no runnable
  program beyond the ten-line shape every Loop has anyway. The header is
  the binary's own, so the guide can never drift from what `loop.build`
  compiles.
  """

  alias SalixAgent.Loops.Host

  @header_key {__MODULE__, :header}

  @guide """
  # Writing a background Loop

  A Loop is one C translation unit (`main.c`, plus optional headers passed
  as `files`) compiled to eBPF by the compiler embedded in spinfoam (TinyCC,
  itself running inside the VM) and run by the node that holds this Agent's
  lease. It runs until it returns, is
  paused, or is deleted; it survives node moves and restarts by reloading
  from its last checkpoint.

  ## Shape

      #include "spinfoam.h"
      SF_MAIN sf_i64 main(void) {
        for (;;) {
          /* wait */ sf_sleep_ms(60000);            /* or sf_event_next(timeout) */
          /* check */ ...                           /* read config, call a read tool */
          /* wake  */ sf_host_call("agent.notify", args, 10000);
        }
      }

  * The entry point is `SF_MAIN sf_i64 main(void)`. Returning stops the
    Loop: it becomes `paused(exited)` with the return value as exit code
    and the Session is told once. A long-running watch never returns.
  * A fault (bad handle, out-of-bounds access, trap) reloads the Loop from
    its checkpoint at most three times an hour, then it is `failed`.

  ## Target constraints (eBPF, not a hosted C runtime)

  * BPF v3, little endian, 4096-byte stack frame. No heap, no libc beyond
    `memcpy`, `memset`, `memcmp`, no recursion, no function pointers. Keep
    buffers small and static-sized; string literals are fine.
  * Integer C only: the compiler rejects floating point and signed division
    or modulo (`/` and `%` on signed operands); use unsigned operands for
    those, and scaled integers instead of doubles.
  * Waiting is only `sf_sleep_ms`, `sf_yield` and `sf_event_next`. A busy
    loop without them burns the node's CPU budget.
  * Every JSON value is at most 16 KiB encoded, depth 32, 4096 nodes.
    Event ids and topics are at most 128 bytes. The mailbox holds 32 events
    or 32 KiB; an event that does not fit is rejected at delivery.

  ## Handles

  * Every `sf_*` function that returns `sf_handle` returns an owned handle
    (`>= 0`) or a negative error. At most 128 handles are live at once, so
    `sf_drop` every handle you no longer need, on every path.
  * `sf_json_set` and `sf_json_push` copy the value; you still own both
    handles. `sf_json_get` / `sf_json_at` return a new owned handle.
  * Use the public string helpers, such as
    `sf_json_string_equals(event, "topic", "MY_EVENT")`. Do not call a
    `_raw` function with handwritten string lengths. A wrong length silently
    rejects matching events. For `sf_json_parse`, use `sizeof(literal) - 1`
    or the byte count returned by `sf_json_read_string`.
  * Errors: `SF_INVALID` (-1) bad handle or argument, `SF_LIMIT` (-2) a
    bound was hit, `SF_TIMEOUT` (-3), `SF_DENIED` (-4) the name is not a
    Loop capability, `SF_HOST_ERROR` (-5) the host refused or failed
    the call (reason in the host log), `SF_CLOSED` (-6) the Loop is being
    stopped: return promptly.

  ## Compiler rules (what makes a build fail or a program fault)

  The embedded compiler is TinyCC's BPF backend, verified against the
  pinned binary. Integer C with globals, pointer tables, string-pointer
  initializers, constant indexing and constant conditions all work as in
  C; a violation of the rules below is a build failure or a runtime fault.

  * The call stack holds 8 frames including `main`: helpers may nest at
    most 7 calls deep below `main`, and recursion counts every level
    (`local call stack exhausted` fault). Write loops, not recursion.
  * Each frame is 4 KiB: large buffers go in `static` globals, never on
    the stack.
  * `unsigned` arithmetic wraps at 32 or 64 bits as in C; `%` and `/` need
    unsigned operands (signed division does not compile). There is no
    floating point.
  * There is no `sprintf` and no heap: build strings with `memcpy` and your
    own integer-to-text helper into a static buffer.

  ## Config and checkpoint

  * `sf_config()` returns the object given to `loop.create` plus
    `loop_id`, `incarnation` and `state`: the last `loop.state.put` value,
    or null on the first load. Read what you need, then `sf_drop` it.
  * Checkpoint deliberately: put only what a fresh incarnation needs to
    continue (a cursor, a last-seen value, a counter). At most 16 KiB.

  ## Host capabilities

  Call with `sf_host_call(name, params_object_handle, timeout_ms)`. There is
  no grant step: every capability below is callable by name, under the
  authorization of the Agent that created the Loop; any other name returns
  `SF_DENIED`. Results are JSON object handles.

  | capability | params | result |
  | --- | --- | --- |
  | `agent.notify` | `{"content": text <= 8 KiB, "dedup_key": <= 128 bytes}` | `{"status": "queued" | "duplicate"}` |
  | `loop.state.put` | `{"state": any JSON <= 16 KiB}` | `{"status": "stored"}` |
  | `loop.state.get` | `{}` | `{"state": ...}` |
  | `loop.ack` | `{"event_id": id}` | `{"status": "acked", "event_id": id}` |
  | `loop.log` | `{"message": text <= 1 KiB}` | `{"status": "logged"}` |
  | read-only Salix tools, by canonical name | that tool's arguments | `{"tool": name, "error": false, "content": text <= 16 KiB}` |
  | any external environment tool (`env.exec`, `env.copy`, `env.process_list/tail/write`, `env.computer_use`, `env.android`, `device.list`, `device.get`) | that tool's arguments | the same envelope; `content` is the tool's JSON text (for `env.exec`: `exit_code`, `stdout`, `stderr`) |
  | any SSH tool (`ssh.*`) | that tool's arguments from `help ssh` | the same envelope. Parse `content` as JSON for the SSH result. |
  | `decide` | `{"state", "questions"}` as in `help decide` | the tool envelope; parse `content` as JSON and check `error` before reading `answers` |
  | `web.http_request` | `{"url", "method", "headers", "query", "body", "credential_env", "timeout_ms"}` as in the tool schema | the same envelope; `content` is the JSON text `{"status", "ok", "headers", "body" or "body_text", "truncated", "duration_ms"}` |

  * `agent.notify` wakes this Session with a message that starts with the
    Loop's name. A wake is deduplicated by `dedup_key`: use one stable key
    per condition (`"cpu-high"`), a fresh key per distinct occurrence
    (`"build-<id>"`). Budget: 6 wakes per 10 minutes; past it the call
    returns `SF_HOST_ERROR`, and an hour of continuous limiting pauses the
    Loop with reason `budget`. Notify on state changes, never on every
    poll.
  * `sf_event_next(timeout_ms)` returns an envelope `{event_id, topic,
    payload}` delivered by `loop.send`, the group events endpoint, or a secret webhook URL, or
    `SF_TIMEOUT`. Acknowledge processed events with `loop.ack`; an event id
    already acked is rejected at delivery, so retries are safe.
    Keep the current event until processing succeeds or a bounded failure
    stops the Loop. A popped, unacknowledged event does not reappear in the
    running guest merely because the provider redelivers it. Retry that event
    internally, checkpoint it, or return a nonzero error for owner recovery.
    A negative host result, an error envelope, invalid decision JSON, and
    insufficient evidence are failures, not a quiet classification. Do not
    acknowledge them as completed. For a useful result, acknowledge only
    after `agent.notify` returns `queued` or `duplicate`.
  * `loop.webhook` enables a secret URL for this Loop. `loop.list` and
    `loop.get` return the saved URL. External senders POST a JSON object
    without an Authorization header. The topic is `webhook` and the payload
    is the full object. Send `Idempotency-Key` for retries. Without it,
    each request has a fresh event ID. Treat the URL as a credential.
  * Tools run with the Loop's own sealed origin and the creator's
    authority. Read tools, SSH tools, the external environment tools and
    `web.http_request`, `composio.execute`, and `decide` are the tools a Loop may call. Salix messaging,
    memory, workspace and schedule writes are never callable. Give tool
    calls a timeout of at least 10000 ms; the host runs them under your
    deadline.
  * `composio.execute` calls connected provider tools, including writes, under the Agent's existing disclosure and IFC checks. Use a fixed tool slug and account.
    `composio.create_trigger` binds a provider watch to this Loop from a normal Agent round.
    Incoming Composio events use the trigger slug as topic and provider event ID for retries.
  * `web.http_request` polls or posts to an HTTP JSON API. Keep the `url`
    and `method` in the program or its config, never in an event payload:
    the program decides where it calls. A non-2xx status is a normal
    result: read `ok` and `status` from `content` before acting. Its
    `timeout_ms` (default 20000) must be below the `sf_host_call` timeout.
    Tokens come from `credential_env` references and `${NAME}`
    placeholders, never literals.
  * `ssh.*` tools use the Group SSH key and the target Agent Session.
    Call `ssh.open` to connect, then use its `ssh_session_id` for commands,
    terminal interaction, or SFTP. Close the connection with `ssh.close` when done.
    SSH sessions do not survive Agent restarts or platform deploys. Reconnect
    when needed instead of treating a checkpointed session ID as a durable connection.
    `ssh.download` requires a `/drive` destination. Workspace downloads require a normal Agent round.
    Give `sf_host_call` a longer timeout than the SSH operation.
  * `env.exec` needs `device_id`, `environment`, `command` and a short
    `description` (under 20 characters), plus an optional `timeout` in
    seconds (default 120): give `sf_host_call` a longer timeout than that.
    `content` is the result JSON as text; `exit_code` says whether the
    command succeeded. Keep `device_id` and `environment` in the program or
    its config so the program decides which environment it reaches. Output
    is bounded to 16 KiB per call: tail or filter in the command itself.

  ## Minimal example: poll a read tool, wake once per change

      #include "spinfoam.h"
      static const char QUERY[] = "{\\"path\\":\\"/status.md\\"}";
      static const char WAKE[]  = "{\\"content\\":\\"status.md changed\\",\\"dedup_key\\":\\"status-changed\\"}";
      SF_MAIN sf_i64 main(void) {
        sf_i64 last = -1;
        for (;;) {
          sf_handle q = sf_json_parse(QUERY, sizeof(QUERY) - 1);
          sf_handle r = sf_host_call("fs.read_file", q, 20000);
          sf_drop(q);
          if (r == SF_DENIED) return 2;            /* not a loop capability: stop */
          if (r >= 0) {
            sf_handle c = sf_json_get(r, "content");
            sf_i64 len = sf_bytes_len(c);
            sf_drop(c);
            sf_drop(r);
            if (last >= 0 && len != last) {
              sf_handle w = sf_json_parse(WAKE, sizeof(WAKE) - 1);
              sf_handle a = sf_host_call("agent.notify", w, 10000);
              if (a >= 0) sf_drop(a);
              sf_drop(w);
            }
            last = len;
          }
          sf_sleep_ms(300000);
        }
      }

  Build it with `loop.build` (which writes the ELF to `/loops/main.elf` in
  your workspace, or the `path` you give), then `loop.create` with
  `path: "/loops/main.elf"`. The Loop records that file's hash; keep the
  file while the Loop exists.

  # spinfoam.h (the header loop.build compiles against)
  """

  @doc "The programming guide, without the header."
  @spec guide() :: String.t()
  def guide,
    do:
      @guide <>
        "\n## Decisions\n\n" <>
        SalixAgent.Decide.guidance() <>
        "\n\n" <>
        SalixAgent.Decide.contract() <>
        "\nThe example threshold needs workload calibration.\n\n```c\n" <>
        SalixAgent.Decide.example_program(:loop) <> "```\n"

  @doc """
  The sections every spinfoam program shares (target constraints, handles,
  compiler rules), so the script guide never drifts from the Loop guide.
  """
  @spec target_sections() :: String.t()
  def target_sections do
    [_, rest] = String.split(@guide, "## Target constraints", parts: 2)
    [sections, _] = String.split(rest, "## Config and checkpoint", parts: 2)
    "## Target constraints" <> sections
  end

  @doc "The guide's example program as compilable C, so tests keep it honest."
  @spec example_program() :: String.t()
  def example_program do
    [_, rest] =
      String.split(@guide, "## Minimal example: poll a read tool, wake once per change\n\n",
        parts: 2
      )

    [code, _] = String.split(rest, "\n\nBuild it with", parts: 2)

    code
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))
    |> Kernel.<>("\n")
  end

  @doc "The exact `spinfoam.h` of the pinned binary on this node, cached."
  @spec header() :: {:ok, String.t()} | {:error, term()}
  def header do
    case :persistent_term.get(@header_key, nil) do
      nil -> dump_header()
      header -> {:ok, header}
    end
  end

  @doc "Guide followed by the header: what `loop.sdk` returns."
  @spec document() :: {:ok, String.t()} | {:error, term()}
  def document do
    with {:ok, header} <- header() do
      {:ok, guide() <> "\n```c\n" <> header <> "```\n"}
    end
  end

  defp dump_header do
    with {:ok, exe} <- Host.executable() do
      case System.cmd(exe, ["--dump-sdk"], stderr_to_stdout: false) do
        {header, 0} when byte_size(header) > 0 ->
          :persistent_term.put(@header_key, header)
          {:ok, header}

        {output, status} ->
          {:error, {:dump_failed, status, String.slice(output, 0, 200)}}
      end
    end
  rescue
    error -> {:error, {:dump_failed, Exception.message(error)}}
  end
end
