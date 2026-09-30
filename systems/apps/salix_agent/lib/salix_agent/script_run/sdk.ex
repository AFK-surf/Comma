defmodule SalixAgent.ScriptRun.Sdk do
  @moduledoc """
  What an Agent reads before it writes a `script.run` program: a guide to
  the one-shot script contract (`salix.call`, `script.result`, `script.log`,
  limits), the target and compiler sections shared with background Loops
  (`SalixAgent.Loops.Sdk.target_sections/0`), and the exact `spinfoam.h` of
  this node's binary.
  """

  alias SalixAgent.Loops.Sdk, as: LoopSdk

  @intro """
  # Writing a script.run program

  A script is one C translation unit (`main.c`, plus optional headers in
  `files`) compiled to eBPF by the compiler embedded in spinfoam and run
  once, on this node, while the tool call waits. It is not a background
  Loop: it has no checkpoint, no events, no `agent.notify`, and it ends
  when `main` returns or the 5 s wall limit is reached.

  ## Shape

      #include "spinfoam.h"
      static const char CALL[] = "{\\"tool\\":\\"fs.read_file\\",\\"args\\":{\\"path\\":\\"/notes.md\\"}}";
      SF_MAIN sf_i64 main(void) {
        sf_handle call = sf_json_parse(CALL, sizeof(CALL) - 1);
        sf_handle reply = sf_host_call("salix.call", call, 20000);
        sf_drop(call);
        if (reply < 0) return reply;                 /* host-level failure */
        sf_handle ok = sf_json_get(reply, "ok");
        if (sf_json_bool(ok) != 1) { sf_drop(ok); sf_drop(reply); return 2; }
        sf_drop(ok);
        sf_handle value = sf_json_get(reply, "value");
        sf_handle out = sf_json_object();
        sf_json_set(out, "value", value);
        sf_handle stored = sf_host_call("script.result", out, 5000);
        sf_drop(out); sf_drop(value); sf_drop(reply);
        return stored < 0 ? stored : 0;
      }

  * The entry point is `SF_MAIN sf_i64 main(void)`. Return 0 for success.
    Any other return value, a fault (bad handle, out-of-bounds access,
    trap) or the wall limit fails the tool call; the model sees the return
    code or the fault and every console line.
  * The result of the call is the JSON value given to `script.result`
    (`{"exit_code": 0}` when none was set), followed by a `--- console ---`
    section with the `script.log` lines.
  * `sf_config()` returns `{"kind": "script", "env": {...}}`: the `env`
    entries of `script.run_file`, all strings. `sf_json_get` returns
    `SF_INVALID` for a missing key.

  ## Host capabilities

  Call with `sf_host_call(name, params_object_handle, timeout_ms)`. Exactly
  three names exist; any other name returns `SF_DENIED`.

  | capability | params | result |
  | --- | --- | --- |
  | `salix.call` | `{"tool": canonical tool name, "args": that tool's arguments}` | `{"ok": true, "value": decoded tool content}` or `{"ok": false, "error": text}`; `"truncated": true` when the content was cut to fit 16 KiB |
  | `script.result` | `{"value": any JSON <= 16 KiB}` | `{"status": "stored"}` (the last value wins) |
  | `script.log` | `{"message": text <= 1 KiB}` | `{"status": "logged"}` (at most 256 lines) |

  * `salix.call` reaches every tool this session may call, with the same
    names, arguments, authorization and information-flow rules as a direct
    call; use `help` (`{"tool": "help", "args": {"tool": "fs.read_file"}}`)
    to inspect one. A tool failure is data (`ok == false`, `error` text),
    never a host error, so the program can branch on it. `script.run` and
    `script.run_file` cannot be called from a script.
  * `value` is the tool's content decoded as JSON when it is JSON, else
    `{"content": text}`. Every tool result is bounded to 16 KiB; larger
    content arrives cut, with `"truncated": true`.
  * `sf_log` (spinfoam's own log) is not a console: its frames are dropped
    when the object exits. Use `script.log`.
  * Give tool calls a timeout of at least 10000 ms; the host runs them
    under the tool's own deadline, and the 5 s wall limit counts only the
    program's own time, not time spent inside a tool call.

  """

  @outro """

  # spinfoam.h (the header script.run compiles against)
  """

  @doc "The guide, without the header."
  @spec guide() :: String.t()
  def guide,
    do:
      @intro <>
        "\n## Decisions\n\n" <>
        SalixAgent.Decide.guidance() <>
        "\n\n" <>
        SalixAgent.Decide.contract() <>
        "\nCall through salix.call with tool decide. The example threshold needs workload calibration.\n\n```c\n" <>
        SalixAgent.Decide.example_program(:script) <> "```\n\n" <> LoopSdk.target_sections()

  @doc "The guide's shape program as compilable C, so tests keep it honest."
  @spec example_program() :: String.t()
  def example_program do
    [_, rest] = String.split(@intro, "## Shape\n\n", parts: 2)
    [code, _] = String.split(rest, "\n\n* The entry point", parts: 2)

    code
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))
    |> Kernel.<>("\n")
  end

  @doc "Guide followed by the header: what `script.sdk` returns."
  @spec document() :: {:ok, String.t()} | {:error, term()}
  def document do
    with {:ok, header} <- LoopSdk.header() do
      {:ok, guide() <> @outro <> "\n```c\n" <> header <> "```\n"}
    end
  end
end
