defmodule SalixAgent.ScriptRun do
  @moduledoc """
  One-shot scripts behind `script.run` and `script.run_file`: an
  agent-authored integer-C program compiled by spinfoam's embedded compiler
  and run once as a `kind: :script` object in this node's spinfoam child
  (`SalixAgent.Loops.Host`).

  The run owns nothing durable: the compiled ELF goes from the build reply
  straight into `sf.object.load`, the object is unloaded when the run
  ends, and no row or file records that it happened.

  ## Capabilities

  The object is loaded with exactly three capabilities:

    * `salix.call {"tool", "args"}`: the gateway to every canonical tool the
      calling round may see. The call runs here, in the tool process that
      owns the script, through `SalixAgent.SessionToolDispatch` with the
      round's own context, so disclosure, IFC and the outer dependency
      admission all apply exactly as they do to a direct call. A
      tool failure comes back as data (`{"ok": false, "error": text}`): a
      JSON-RPC error would reach the guest as a bare `SF_HOST_ERROR`.
    * `script.result {"value"}`: the run's return value (the last write wins).
    * `script.log {"message"}`: one console line. spinfoam's own `sf_log`
      frames are discarded when an object exits, so this is the only
      reliable console channel for a short program.

  Recursive `script.run` / `script.run_file` calls are refused. spinfoam
  hands every value through 16 KiB JSON handles, so a tool result larger
  than that is truncated and marked rather than turned into `SF_LIMIT`.

  ## Outcome

  A zero return is success: the result value (or `{"exit_code": 0}`) plus a
  `--- console ---` section. A non-zero return, a guest fault, the wall
  limit, a lost child or a build failure is a model-only failed tool result
  that keeps every journal event and tool observation the script's host
  calls completed before the failure.

  Terminal notifications from spinfoam are advisory: when the wall timer
  fires, `sf.object.stop` returns the object's true terminal state, so an
  exit whose notification was dropped still counts as the exit it was.
  """

  alias SalixAgent.{SessionToolDispatch, VisibleReplyPolicy, VisibleReplyScope}
  alias SalixAgent.Loops.Host
  alias SalixAgent.Spinfoam.Build

  @gateway "salix.call"
  @result_capability "script.result"
  @log_capability "script.log"
  @capabilities [@gateway, @result_capability, @log_capability]
  @recursive ~w(script.run script.run_file)
  @source_send_tool "im_api.internal.send_message"

  @default_wall_ms 5_000
  @max_value_bytes 16 * 1024
  @value_budget @max_value_bytes - 256
  @max_env_bytes 15 * 1024
  @max_log_lines 256
  @max_log_bytes 64 * 1024
  @max_log_line_bytes 1024

  @typedoc "Dispatcher tool ctx (see `SalixAgent.Tools`)."
  @type ctx :: %{
          required(:agent_id) => String.t(),
          optional(:session_id) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc "Per-run host state threaded through every capability call."
  @type t :: %{
          ctx: ctx(),
          events: [map()],
          tool_observations: [map()],
          diagnostic_results: [map()],
          result: :none | {:set, term()},
          logs: [String.t()],
          log_bytes: non_neg_integer()
        }

  @doc "The capability names a script object is loaded with."
  @spec capabilities() :: [String.t()]
  def capabilities, do: @capabilities

  @doc "Wall limit for one run, in milliseconds (`:salix_agent, :script_wall_timeout_ms`)."
  @spec wall_timeout_ms() :: pos_integer()
  def wall_timeout_ms,
    do: Application.get_env(:salix_agent, :script_wall_timeout_ms, @default_wall_ms)

  @doc "Initial host state for one run."
  @spec new(ctx()) :: t()
  def new(ctx),
    do: %{
      ctx: ctx,
      events: [],
      tool_observations: [],
      diagnostic_results: [],
      result: :none,
      logs: [],
      log_bytes: 0
    }

  @doc """
  Compile `files` (with `entry` as the translation unit), run the program
  once with `env` readable as `config.env`, and return the tool result.
  """
  @spec run(%{String.t() => String.t()}, String.t(), %{String.t() => String.t()}, ctx()) ::
          String.t()
          | {String.t(), [map()]}
          | {:tool_observations, String.t(), [map()], [map()]}
          | {:tool_failure, String.t(), String.t(), String.t(), nil, [map()], [map()]}
  def run(files, entry, env, ctx) when is_map(files) and is_binary(entry) and is_map(env) do
    started = System.monotonic_time()
    state = new(ctx)

    outcome =
      with :ok <- check_env(env),
           :ok <- ensure_available(),
           {:ok, build} <- Build.compile(files, entry),
           {:ok, object_id} <- load(build.elf, env, ctx) do
        execute(object_id, state)
      else
        {:error, reason} -> {:error, reason, state}
      end

    emit(outcome, System.monotonic_time() - started)
    render(outcome)
  end

  # ---- lifecycle -------------------------------------------------------------

  defp ensure_available do
    case Host.status() do
      %{available: true} -> :ok
      %{reason: reason} -> {:error, {:unavailable, reason}}
      _ -> {:error, {:unavailable, :host_not_running}}
    end
  end

  defp check_env(env) do
    cond do
      not Enum.all?(env, fn {k, v} -> is_binary(k) and is_binary(v) end) ->
        {:error, :invalid_env}

      byte_size(Jason.encode!(env)) > @max_env_bytes ->
        {:error, :env_too_large}

      true ->
        :ok
    end
  end

  defp load(elf, env, ctx) do
    ref = %{
      kind: :script,
      owner: self(),
      agent_id: ctx[:agent_id],
      session_id: ctx[:session_id],
      tenant_id: ctx[:tenant_id],
      group_id: ctx[:group_id]
    }

    config = %{"kind" => "script", "env" => env}
    capabilities = Enum.map(@capabilities, &%{"name" => &1, "arguments" => %{}})
    Host.object_load(ref, elf, config, capabilities)
  end

  defp execute(object_id, state) do
    try do
      case Host.object_start(object_id) do
        :ok -> await(object_id, state, deadline())
        {:error, reason} -> {:error, {:start_failed, reason}, state}
      end
    after
      _ = Host.object_unload(object_id)
      flush(object_id)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + wall_timeout_ms()

  # The wall budget is guest time: it is re-armed after every host call, so
  # a slow tool does not count against it.
  defp await(object_id, state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:script_host_call, ^object_id, rpc_id, capability, arguments} ->
        {reply, state} = capability_call(capability, arguments, state)
        Host.host_reply(rpc_id, reply)
        await(object_id, state, deadline())

      {:script_host_cancel, ^object_id, _rpc_id} ->
        await(object_id, state, deadline)

      {:script_terminal, ^object_id, :runtime_lost} ->
        {:error, :runtime_lost, state}

      {:script_terminal, ^object_id, status} when is_map(status) ->
        {:ok, status, state}
    after
      remaining ->
        # A dropped terminal notification is not a wall violation: stopping
        # an already terminal object returns its real outcome.
        case Host.object_stop(object_id) do
          {:ok, %{"state" => terminal} = status} when terminal in ["exited", "failed"] ->
            {:ok, status, state}

          _ ->
            {:error, {:limit, :wall}, state}
        end
    end
  end

  defp flush(object_id) do
    receive do
      {:script_host_call, ^object_id, rpc_id, _capability, _arguments} ->
        Host.host_reply(rpc_id, {:error, "script run has ended"})
        flush(object_id)

      {:script_host_cancel, ^object_id, _rpc_id} ->
        flush(object_id)

      {:script_terminal, ^object_id, _status} ->
        flush(object_id)
    after
      0 -> :ok
    end
  end

  # ---- capabilities ------------------------------------------------------------

  defp capability_call(@gateway, arguments, state) do
    tool = to_string(arguments["tool"] || "")
    args = ensure_map(arguments["args"])

    cond do
      tool == "" ->
        {{:ok, %{"ok" => false, "error" => "salix.call: tool is required"}}, state}

      tool in @recursive ->
        {{:ok, %{"ok" => false, "error" => "#{tool} cannot be called from inside a script"}},
         state}

      true ->
        case host_call(tool, args, state) do
          {{:ok, value}, state} -> {{:ok, bounded_value(value)}, state}
          {{:error, message}, state} -> {{:ok, %{"ok" => false, "error" => message}}, state}
        end
    end
  end

  defp capability_call(@result_capability, arguments, state) do
    value = Map.get(arguments, "value")

    if byte_size(Jason.encode!(value)) > @max_value_bytes,
      do: {{:error, "result exceeds #{@max_value_bytes} bytes"}, state},
      else: {{:ok, %{"status" => "stored"}}, %{state | result: {:set, value}}}
  end

  defp capability_call(@log_capability, arguments, state) do
    message = arguments["message"] || arguments["text"] || arguments
    line = if is_binary(message), do: message, else: Jason.encode!(message)
    line = String.slice(line, 0, @max_log_line_bytes)

    cond do
      length(state.logs) >= @max_log_lines or state.log_bytes + byte_size(line) > @max_log_bytes ->
        {{:error, "console budget exhausted"}, state}

      true ->
        {{:ok, %{"status" => "logged"}},
         %{state | logs: [line | state.logs], log_bytes: state.log_bytes + byte_size(line)}}
    end
  end

  defp capability_call(name, _arguments, state),
    do: {{:error, "capability not available to scripts: " <> to_string(name)}, state}

  # Results cross into the guest as one 16 KiB JSON value. A larger tool
  # content is cut to fit and marked, so the program can still act on it;
  # spinfoam would otherwise answer the whole call with SF_LIMIT. The bound
  # is the encoded envelope, not the raw text: quotes, backslashes and
  # control characters grow when JSON-encoded.
  defp bounded_value(value) do
    reply = %{"ok" => true, "value" => value}

    if byte_size(Jason.encode!(reply)) <= @value_budget do
      reply
    else
      text = if is_binary(value), do: value, else: Jason.encode!(value)
      envelope = byte_size(Jason.encode!(%{"ok" => true, "value" => "", "truncated" => true}))

      %{
        "ok" => true,
        "value" => encoded_prefix(text, @value_budget - envelope),
        "truncated" => true
      }
    end
  end

  # The longest valid UTF-8 prefix of `text` whose JSON string encoding
  # (without the surrounding quotes) is at most `budget` bytes. Each step
  # shrinks the prefix by the measured expansion ratio, so it converges in
  # a few encodes even for text that is all escapes.
  defp encoded_prefix(text, budget) do
    fit_encoded(valid_utf8_prefix(binary_part(text, 0, min(byte_size(text), budget))), budget)
  end

  defp fit_encoded("", _budget), do: ""

  defp fit_encoded(prefix, budget) do
    encoded = byte_size(Jason.encode!(prefix)) - 2

    if encoded <= budget do
      prefix
    else
      shorter = min(div(byte_size(prefix) * budget, encoded), byte_size(prefix) - 1)
      fit_encoded(valid_utf8_prefix(binary_part(prefix, 0, max(shorter, 0))), budget)
    end
  end

  defp valid_utf8_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_utf8_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # ---- canonical tool dispatch (the JavaScript host's gateway, unchanged) ----

  @doc """
  Execute one canonical tool call issued by the script through the round's
  own dispatch, threading events, observations and diagnostic results
  through `state`.
  """
  @spec host_call(String.t(), map(), t()) :: {{:ok, term()} | {:error, String.t()}, t()}
  def host_call(name, args, state) do
    if canonical_host_call?(name) do
      run_canonical_host_tool(name, args, state)
    else
      {{:error, "unknown host call: " <> to_string(name)}, state}
    end
  end

  defp canonical_host_call?(name) when is_binary(name) do
    name in ["help", "decide"] or String.contains?(name, ".")
  end

  defp canonical_host_call?(_name), do: false

  defp run_canonical_host_tool(name, _args, state) when name in @recursive do
    {{:error, "#{name} cannot be called from inside a script"}, state}
  end

  defp run_canonical_host_tool(name, args, state) do
    ctx =
      state.ctx
      # A script has its own `salix.call` envelope. Do not let a parent
      # internal LLM round force host calls through the internal `call` wrapper.
      |> Map.delete(:llm_tool_envelope)
      |> Map.put(:runtime_kind, :script)
      |> Map.put(:defer_tool_observations, true)

    # A host call declares its provenance the same way the `call` envelope
    # does (docs/verification.md); the object is lifted off the arguments
    # so the target tool's schema is untouched.
    {tool_args, ifc} = SalixAgent.IFC.Declaration.lift(args || %{})

    tool_call =
      %{id: "script-host:" <> random_id(), name: name, args: tool_args}
      |> then(&if(ifc, do: Map.put(&1, :ifc, ifc), else: &1))

    [result] = SessionToolDispatch.execute([tool_call], ctx)

    state = %{
      state
      | events:
          state.events ++
            List.wrap(result[:events] || result["events"]) ++
            visible_reply_egress_events(name, args, result, state.ctx, tool_call.id),
        tool_observations:
          state.tool_observations ++
            List.wrap(result[:tool_observations] || result["tool_observations"]),
        diagnostic_results: record_diagnostic_result(state.diagnostic_results, result)
    }

    if result[:error] || result["error"] do
      {{:error, host_error_content(result)}, state}
    else
      {{:ok, decode_tool_content(result[:content] || result["content"])}, state}
    end
  end

  # ---- results -----------------------------------------------------------------

  defp render({:ok, %{"state" => "exited"} = status, state}) do
    case get_in(status, ["outcome", "exit_code"]) do
      0 ->
        value =
          case state.result do
            {:set, value} -> value
            :none -> %{"exit_code" => 0}
          end

        finalize_result(Jason.encode!(value) <> console_suffix(state), state)

      code ->
        failed_result("script exited with code #{inspect(code)}" <> console_suffix(state), state)
    end
  end

  defp render({:ok, %{"state" => "failed"} = status, state}) do
    error = get_in(status, ["outcome", "error"]) || "program fault"
    failed_result("script fault: #{error}" <> console_suffix(state), state)
  end

  defp render({:ok, status, state}),
    do: failed_result("script stopped: #{inspect(status["state"])}", state)

  defp render({:error, reason, state}),
    do: failed_result(failure_message(reason) <> console_suffix(state), state)

  defp console_suffix(%{logs: []}), do: ""

  defp console_suffix(%{logs: logs}),
    do: "\n--- console ---\n" <> Enum.join(Enum.reverse(logs), "\n")

  defp failure_message({:build_failed, failure}), do: "script build: " <> failure.diagnostics

  defp failure_message({:limit, :wall}),
    do: "script wall time limit exceeded: #{format_duration_ms(wall_timeout_ms())}"

  defp failure_message(:runtime_lost), do: "script runtime lost while the program ran"

  defp failure_message({:unavailable, reason}),
    do: "script runtime unavailable on this node: #{inspect(reason)}"

  defp failure_message(:script_capacity), do: "script runtime busy on this node"

  defp failure_message({:host_unavailable, reason}),
    do: "script runtime unavailable on this node: #{inspect(reason)}"

  defp failure_message(:host_unavailable), do: "script runtime unavailable on this node"
  defp failure_message(:build_timeout), do: "script build did not finish within the budget"
  defp failure_message(:env_too_large), do: "env exceeds #{@max_env_bytes} bytes"
  defp failure_message(:invalid_env), do: "env entries must be string names and string values"
  defp failure_message({:start_failed, reason}), do: "script could not start: #{inspect(reason)}"
  defp failure_message(reason), do: "script error: #{inspect(reason)}"

  # Go fmt's %s on time.Duration prints whole seconds as "5s".
  defp format_duration_ms(ms) when rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s"
  defp format_duration_ms(ms), do: "#{ms}ms"

  defp failed_result(diagnostic, state) do
    events = if is_map(state), do: state[:events] || [], else: []
    observations = if is_map(state), do: state[:tool_observations] || [], else: []

    {:tool_failure, diagnostic, "tool_error", "model_only", nil, events, observations}
  end

  @doc false
  def finalize_result(content, state) when is_binary(content) and is_map(state) do
    events = state[:events] || []
    observations = state[:tool_observations] || []

    case outer_diagnostic_result(state[:diagnostic_results] || []) do
      nil ->
        case {events, observations} do
          {[], []} -> content
          {events, []} -> {content, events}
          {events, observations} -> {:tool_observations, content, events, observations}
        end

      result ->
        {
          :tool_failure,
          result[:content] || result["content"] || "nested tool failed",
          result[:error_class] || result["error_class"] || result[:guidance_reason] ||
            result["guidance_reason"] || "nested_tool_failure",
          result[:diagnostic_visibility] || result["diagnostic_visibility"],
          result[:public_summary] || result["public_summary"],
          events,
          observations
        }
    end
  end

  defp record_diagnostic_result(results, result) do
    if VisibleReplyPolicy.model_only_result?(result) or
         VisibleReplyPolicy.user_reportable_result?(result) do
      results ++ [result]
    else
      results
    end
  end

  defp outer_diagnostic_result(results) do
    Enum.find(results, &VisibleReplyPolicy.model_only_result?/1) ||
      Enum.find(results, &VisibleReplyPolicy.user_reportable_result?/1)
  end

  defp host_error_content(result) do
    if VisibleReplyPolicy.user_reportable_result?(result) do
      result[:public_summary] || result["public_summary"]
    else
      result[:content] || result["content"] || "tool failed"
    end
  end

  defp decode_tool_content(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"content" => content}
    end
  end

  defp decode_tool_content(content), do: content

  # The outer transcript only records `script.run` / `script.run_file`, so a
  # later final cannot infer from its declared tool calls that the script
  # already sent the activation's visible reply. Persist an exact,
  # runtime-authored execution fact only after the nested source send
  # actually succeeds. The verified kernel recognizes the fact by its
  # `script_host` source (`VerifiedKernel/Session/Fact.lean`); the two must
  # move together.
  defp visible_reply_egress_events(@source_send_tool, args, result, ctx, nested_tool_call_id) do
    conversation_id = value(args, "conversation_id")
    source_message_ids = normalize_source_message_ids(ctx)
    group_id = value(ctx, "group_id")
    outer_tool_call_id = value(ctx, "tool_call_id")

    if successful_nested_egress?(result) and present?(conversation_id) and
         present?(group_id) and present?(outer_tool_call_id) and source_message_ids != [] do
      ownership_key =
        VisibleReplyScope.egress_ownership_key(group_id, conversation_id, source_message_ids)

      [
        %{
          "type" => "session_event",
          "event_id" => "visible-reply-egress:#{outer_tool_call_id}:#{nested_tool_call_id}",
          "kind" => "visible_reply_egress",
          "source" => "script_host",
          "method" => @source_send_tool,
          "event" => %{
            "agent_group_id" => group_id,
            "conversation_id" => conversation_id,
            "source_message_ids" => source_message_ids,
            "ownership_key" => ownership_key,
            "outer_tool_call_id" => outer_tool_call_id,
            "nested_tool_call_id" => nested_tool_call_id
          },
          "created_at" => System.system_time(:second)
        }
      ]
    else
      []
    end
  end

  defp visible_reply_egress_events(_name, _args, _result, _ctx, _nested_tool_call_id), do: []

  defp successful_nested_egress?(result) do
    not truthy?(value(result, "error")) and value(result, "status") != "guidance" and
      value(result, "diagnostic_visibility") in [nil, "none"]
  end

  defp normalize_source_message_ids(ctx) do
    (List.wrap(value(ctx, "source_message_ids")) ++ [value(ctx, "source_message_id")])
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
  end

  defp truthy?(value), do: value in [true, "true", 1]
  defp present?(value), do: is_binary(value) and value != ""

  defp value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp value(_map, _key), do: nil

  defp ensure_map(args) when is_map(args), do: args
  defp ensure_map(_), do: %{}

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp emit(outcome, duration) do
    Salix.Telemetry.emit_operation(
      "salix_agent",
      "script_run",
      "script",
      outcome_label(outcome),
      duration
    )
  end

  defp outcome_label({:ok, %{"state" => "exited", "outcome" => %{"exit_code" => 0}}, _}), do: "ok"
  defp outcome_label({:ok, _, _}), do: "rejected"
  defp outcome_label({:error, {:limit, :wall}, _}), do: "timeout"
  defp outcome_label({:error, {:build_failed, _}, _}), do: "rejected"
  defp outcome_label({:error, _, _}), do: "error"
end
