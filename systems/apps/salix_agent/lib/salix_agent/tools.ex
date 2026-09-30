defmodule SalixAgent.Tools do
  @moduledoc """
  Tool registry and dispatcher. Ships the canonical
  product tools that route through
  `SalixAgent.FileBackend` — the only agent-visible file dispatch path.

  Tool calls may execute concurrently, but persisted results MUST stay in
  original call order, and registration order MUST be stable
  (prompt-cache determinism). `specs/0` returns a fixed-order list; `execute/2`
  admits calls through bounded `SalixAgent.DependencyJob` lanes and returns
  results in call order.

  A tool function takes `(args, ctx)` where `ctx` is `%{agent_id, session_id}`,
  returns either `content` (a string) or `{content, events}` where `events` are
  journal events (e.g. `vfs_write`) the round commits atomically with the tool
  result.
  """

  alias SalixAgent.{DependencyJob, FileBackend, StorageAuthorization, Waits}
  alias SalixAgent.Tools.{AsyncPolicy, Schemas}

  @normal_auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()

  # Registration order is pinned. Never reorder without accepting prompt-cache
  # churn.
  @registry [
    {"help",
     "Return tool manuals, schemas, and examples. Discover tool names on demand with tool=mcp_manager, plugin, calendar, inbound_api, ssh, or im_api.internal.label; then request help for a returned name. Discover MCP server operations with mcp.list. Use tool=ifc for information-flow rules.",
     &__MODULE__.help/2, @normal_auto_wait_seconds},
    {"fs.write_file",
     "Create a visible file, or replace one whole. To change an existing file use fs.edit_file instead: rewriting a file you already read sends the whole file back through the model, which is slow, spends output tokens and trips rate limits.",
     &__MODULE__.write_file/2, @normal_auto_wait_seconds},
    {"fs.read_file",
     "Read content from a visible file path, including VFS files and session runtime files such as /.runtime/compaction-recovery.md and /.runtime/skills. Text files can be read fully, by line with start_line/num_lines, or from the end with tail_lines. Oversized text results keep the head and tail and report omitted middle characters. Image files return image content only when the active agent template supports image input; otherwise they require a configured vision describer. Other binary formats need dedicated readers and are reported as unsupported.",
     &__MODULE__.read_file/2, @normal_auto_wait_seconds},
    {"fs.list_files", "List visible file paths under a prefix.", &__MODULE__.list_files/2,
     @normal_auto_wait_seconds},
    {"fs.delete_file", "Delete a visible file path (body retained).", &__MODULE__.delete_file/2,
     @normal_auto_wait_seconds},
    {"script.run",
     "Run a small C program once, compiled to eBPF by spinfoam's embedded compiler and executed in a sandbox on this node. Call script.sdk first: it gives the exact spinfoam.h, the limits (integer C only, 4 KiB stack, 16 KiB JSON values, no libc) and the compiler rules. The program includes \"spinfoam.h\", defines SF_MAIN sf_i64 main(void), calls any Salix tool through sf_host_call(\"salix.call\", {\"tool\": name, \"args\": {...}}, timeout_ms) with the same canonical names and authorization as a normal round, sets its return value with script.result {\"value\": ...} and appends console lines with script.log {\"message\": ...}. Return 0 for success; a non-zero return, a fault or the 5 s wall limit fails the call. Recursive script.run/script.run_file calls are rejected.",
     &__MODULE__.script_run/2, @normal_auto_wait_seconds, [safety: "write"]},
    {"fs.edit_file",
     "Change part of a visible file: replace the first occurrence of old text with new text. The way to modify an existing file; make old unique and include a few lines of context. Decoded framed text views are read-only.",
     &__MODULE__.edit_file/2, @normal_auto_wait_seconds},
    {"fs.copy_file", "Copy a visible file to a new path.", &__MODULE__.copy_file/2,
     @normal_auto_wait_seconds},
    {"fs.move_file", "Move/rename a visible file.", &__MODULE__.move_file/2,
     @normal_auto_wait_seconds},
    {"fs.grep",
     "Search visible file contents for a regex; returns matching path:line. Search work is bounded per request; excessive input work fails explicitly, while match/output limits stop with a truncation marker.",
     &__MODULE__.grep/2, @normal_auto_wait_seconds},
    {"fs.glob", "List visible file paths matching a glob pattern.", &__MODULE__.glob/2,
     @normal_auto_wait_seconds},
    {"fs.stat_file", "Return metadata for a visible file path.", &__MODULE__.stat_file/2,
     @normal_auto_wait_seconds},
    {"web.search",
     "Search the web for current information; returns titles, URLs and text snippets.",
     &__MODULE__.web_search/2, @normal_auto_wait_seconds}
  ]

  @type call :: %{optional(any) => any}

  # Runtime-owned replay contract. These handlers do not mutate business state.
  # A discarded attempt can repeat bounded computation or search quota use.
  # HTTP, plugins, JavaScript and delegated environment tools are not eligible.
  @doc false
  def replayable_read?(name),
    do:
      name in [
        "help",
        "web.search",
        "fs.read_file",
        "fs.grep",
        "fs.list_files",
        "fs.glob",
        "fs.stat_file",
        "tool_call.get_result"
      ]

  @doc false
  def cancel_speculative_reads(agent_id, pending) do
    Enum.each(pending, fn item ->
      DependencyJob.cancel(item.dependency_job)

      SalixAgent.EventArchive.Emit.async_tool_result(agent_id, item.session_id, item, %{
        id: item.tool_call_id,
        name: item.tool_name,
        status: "cancelled",
        error: true,
        error_class: "intent_unconfirmed",
        content: "Read discarded because its intent was not confirmed."
      })
    end)
  end

  @type ctx :: %{required(:agent_id) => String.t(), optional(:session_id) => String.t()}
  @type tool_return ::
          String.t()
          | {String.t(), [map()]}
          | {:tool_status, String.t(), String.t(), [map()]}
          | {:tool_failure, String.t(), String.t(), String.t(), String.t() | nil, [map()]}
          | {:tool_failure, String.t(), String.t(), String.t(), String.t() | nil, [map()],
             [map()]}
  @type result :: %{
          id: String.t(),
          name: String.t(),
          content: String.t(),
          error: boolean(),
          input: String.t(),
          output: String.t(),
          status: String.t(),
          duration_ms: non_neg_integer(),
          error_class: String.t() | nil,
          error_message: String.t() | nil,
          events: [map()]
        }

  @default_tool_timeout_ms 30_000
  @copy_timeout_ms 600_000
  @image_generation_timeout_ms 120_000
  @video_generation_timeout_ms 600_000
  @audio_transcription_timeout_ms 615_000
  @mcp_tool_timeout_ms 600_000
  @android_tool_timeout_ms 221_000
  # Exec carries its own `timeout` (seconds); the outer dispatcher deadline is
  # derived from it so a long command isn't brutal-killed at the flat default.
  # The grace margin lets the inner exec path time out first and return a real
  # result; the ceiling bounds a runaway request.
  @exec_timeout_grace_ms 15_000
  @max_exec_timeout_ms 600_000
  @read_page_default_lines 200
  @read_page_max_lines 2_000
  @read_text_output_max_chars 120_000
  @record_stream_prefixes [<<1, 0, 0, 0, 0, 0, 0>>, <<2, 0, 0, 0, 0, 0, 0>>]
  @record_stream_text_extensions ~w(.txt .log)
  @record_stream_max_frames 65_536
  @grep_max_files 1_000
  @grep_max_input_bytes 16 * 1024 * 1024
  @grep_max_frames @record_stream_max_frames
  @grep_max_matches 2_000
  @grep_max_output_bytes 120_000
  @grep_truncated_marker "[fs.grep truncated: additional matches omitted after reaching result limits]"
  @dependency_admission_context_key :__salix_tool_dependency_admission__

  # Read safety is product-owned disclosure metadata. It describes operations
  # to the model and downstream policy surfaces; it does not reorder a batch or
  # grant/deny execution based on diagnostic-repair state.
  @read_safety_tools ~w(
    help
    fs.read_file
    fs.list_files
    fs.grep
    fs.glob
    fs.stat_file
    web.search
    tool_call.get_status
    tool_call.get_result
    plugin.definitions_list
    plugin.definition_get
    plugin.projection_get
    web.read_pages
    memory.get
    memory.search
    memory.ask_worker
    env.process_list
    env.process_tail
    device.list
    device.get
    agent.list
    agent.get
    env.runtime_targets
    calendar.list_items
    calendar.get_item
    meeting.get
    im.connects_list
    im.provider_apis_list
    mcp_manager.definition_list
    mcp.list
    mcp.get
    schedule.list
    oauth.list_credentials
    oauth.complete_authorization
    composio.list_connections
    composio.check_connection
    composio.list_tools
    composio.get_tool
    composio.list_toolkits
  )

  @typedoc """
  Static tool registry entry.

  A fifth/sixth tuple element may carry registry metadata such as
  `roles: ["router"]`, `runtimes: [:internal]`, or `safety: "write"`. Metadata is system policy used
  while materializing the session disclosure; it is never model-authored.
  """
  @type entry ::
          {String.t(), String.t(), (map(), ctx() -> tool_return()), pos_integer()}
          | {String.t(), String.t(), map(), (map(), ctx() -> tool_return()), pos_integer()}
          | {String.t(), String.t(), (map(), ctx() -> tool_return()), pos_integer(), keyword()}
          | {String.t(), String.t(), map(), (map(), ctx() -> tool_return()), pos_integer(),
             keyword()}

  # Full registry: the pinned core list plus the ported willow tool areas,
  # appended in a FIXED module order so it stays stable across releases.
  # Runtime concat avoids compile-order coupling between sibling modules.
  @doc false
  def registry do
    @registry ++
      SalixAgent.Tools.AsyncOps.defs() ++
      SalixAgent.Tools.Skill.defs() ++
      SalixAgent.Tools.Plugin.defs() ++
      SalixAgent.Tools.Browser.defs() ++
      SalixAgent.Tools.Web.defs() ++
      SalixAgent.Decide.defs() ++
      SalixAgent.Tools.Memory.entries() ++
      SalixAgent.Tools.Peers.defs() ++
      SalixAgent.Tools.DependencyInstallations.defs() ++
      SalixAgent.Tools.AgentManagement.defs() ++
      SalixAgent.Tools.RuntimeTargets.defs() ++
      SalixAgent.Tools.CloudRuntime.defs() ++
      SalixAgent.Tools.Calendar.defs() ++
      SalixAgent.Tools.MeetingPreparation.defs() ++
      SalixAgent.Tools.ImRouter.defs() ++
      SalixAgent.Tools.MCP.defs() ++
      SalixAgent.Tools.Schedules.defs() ++
      SalixAgent.Tools.Loops.defs() ++
      SalixAgent.Tools.OAuth.defs() ++
      SalixAgent.Tools.Media.defs() ++
      SalixAgent.Tools.Preview.defs() ++
      SalixAgent.Tools.DynamicUI.defs() ++
      SalixAgent.Tools.RuntimeAuth.defs() ++
      SalixAgent.Tools.Compute.defs() ++
      SalixAgent.Tools.Composio.defs() ++
      SalixAgent.Tools.ComposioTriggers.defs() ++
      SalixAgent.Tools.Proactive.defs() ++
      SalixAgent.Tools.Recommendations.defs() ++
      SalixAgent.Tools.OwnerEmail.defs() ++
      SalixAgent.Tools.Meeting.defs() ++
      SalixAgent.Tools.IFC.defs() ++
      SalixAgent.Tools.History.entries() ++
      SalixAgent.Tools.Drive.defs() ++
      SalixAgent.Tools.RemoteShell.defs() ++
      SalixAgent.Tools.DeviceConnection.defs() ++
      SalixAgent.Tools.InboundApi.defs() ++
      SalixAgent.Tools.SSH.defs()
  end

  @doc """
  Tool specs in stable registration order, each carrying its
  `"input_schema"` (`SalixAgent.Tools.Schemas`) so the contract the LLM sees
  matches the dispatcher's validation.
  """
  @spec specs() :: [map()]
  def specs do
    registry()
    |> Enum.map(fn entry ->
      name = entry_name(entry)
      desc = entry_description(entry)

      %{"name" => name, "description" => desc}
      |> Map.put("input_schema", entry_schema(entry))
      |> Map.put("auto_wait_timeout_seconds", entry_auto_wait_seconds(entry))
    end)
  end

  @doc false
  def call_spec(target_names \\ []) do
    target_schema =
      %{
        "type" => "string",
        "description" =>
          "Target canonical tool name or dynamic operation id, e.g. fs.read_file, help, or im.connects_list."
      }
      |> maybe_put_target_enum(target_names)

    %{
      "name" => "call",
      "description" =>
        "Internal LLM envelope for one target business or capability tool call. Call the session controls wait_for and end_turn directly. The outer tool name is already call; set the tool argument to the target canonical tool such as fs.read_file or help, and set params to that target tool's JSON object arguments. If you already know the target tool and valid parameters, call it directly. To inspect a target tool, set tool=\"help\" and params={\"tool\":\"fs.read_file\"}.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "tool" => target_schema,
          "params" => %{
            "type" => "object",
            "description" => "JSON object containing the target tool parameters."
          },
          "ifc" => SalixAgent.IFC.Declaration.schema()
        },
        "required" => ["tool", "params"]
      },
      "auto_wait_timeout_seconds" => @normal_auto_wait_seconds
    }
  end

  defp maybe_put_target_enum(schema, target_names) when is_list(target_names) do
    names =
      target_names
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.sort()

    if names == [], do: schema, else: Map.put(schema, "enum", names)
  end

  defp maybe_put_target_enum(schema, _target_names), do: schema

  @doc """
  Execute tool calls concurrently; return results in original call order. Each
  result carries any `events` the tool wants committed with its result.

  The materialized tool disclosure in `ctx` determines whether a tool may run.
  """
  @spec execute([call()], ctx()) :: [result()]
  def execute(calls, ctx) when is_list(calls) do
    calls = if Map.get(ctx, :calls_prepared) == true, do: calls, else: prepare_calls(calls, ctx)
    SalixAgent.EventArchive.Emit.tool_calls(ctx, calls)

    # Per-turn caps (2 image / 1 video / 5 js — SalixMedia.Caps): calls beyond
    # the cap within ONE batch are rejected without executing.
    prepared = enforce_caps(calls)
    executable = executable_calls(prepared)
    started_at = System.system_time(:millisecond)
    observability_context = SystemsObservability.Context.capture()

    executed =
      Enum.map(executable, fn call ->
        prepare_tool_dependency(call, ctx, observability_context)
      end)
      |> Enum.map(fn
        {_call, _call_ctx, {:ok, job}} ->
          case DependencyJob.yield(job, job.timeout_ms + 1_000) do
            {:ok, result} ->
              result

            {:exit, reason} ->
              {:tool_crashed, reason}

            nil ->
              # Defensive outer bound: the owner timer should normally win,
              # but a missing timer message must not retain admission forever.
              :ok = DependencyJob.cancel(job)
              {:tool_crashed, {:dependency_timeout, :tool}}
          end

        {_call, _call_ctx, {:inline, result}} ->
          result

        {_call, _call_ctx, {:error, result}} ->
          result
      end)

    prepared
    |> merge_prepared_results(executed, started_at)
    |> collect_tool_observations(ctx, async: false)
    |> archive_results(ctx)
  end

  # Archive boundary 5, synchronous arm. Emitted at the seam rather than at
  # call sites: Round has two tool paths and SessionToolExecution a third, and
  # instrumenting them individually is how the async arm came to be missed.
  defp archive_results(results, ctx) do
    SalixAgent.EventArchive.Emit.tool_results(ctx, results)
    results
  end

  @doc """
  Admit tool calls for a runtime round without waiting in the actor mailbox.

  Calls whose exact completion message is already available return their final
  result as a fast-path optimization. Every other call returns an early result
  and a pending job record immediately; the caller owns committing the early
  result and later committing the completion notification when the job replies.
  """
  @spec execute_with_async_window([call()], ctx()) :: {[result()], [map()]}
  def execute_with_async_window(calls, ctx) when is_list(calls) do
    session_id = required_session_id!(ctx)
    calls = if Map.get(ctx, :calls_prepared) == true, do: calls, else: prepare_calls(calls, ctx)
    SalixAgent.EventArchive.Emit.tool_calls(ctx, calls)
    prepared = enforce_caps(calls)
    calls = executable_calls(prepared)
    started_at = System.system_time(:millisecond)
    observability_context = SystemsObservability.Context.capture()

    jobs =
      Enum.map(calls, fn call ->
        prepare_tool_dependency(call, ctx, observability_context)
      end)

    {results, pending} =
      Enum.map_reduce(jobs, [], fn
        {call, call_ctx, {:ok, job}}, pending ->
          # This code runs in a session actor. Poll only messages which have
          # already arrived; a user tool never owns a synchronous mailbox
          # window. Fast completion remains an optimization, while any live
          # dependency is parked under its exact job token immediately.
          case if(ctx[:planned_async_intent], do: nil, else: DependencyJob.yield(job, 0)) do
            {:ok, result} ->
              {result, pending}

            {:exit, reason} ->
              {crashed_result(call, reason, started_at), pending}

            nil ->
              tool_call_id = tool_call_id(call)
              auto_wait_seconds = auto_wait_seconds_for_call(call)
              wait = auto_wait(tool_call_id, call, auto_wait_seconds, session_id)
              result = async_running_result(call, tool_call_id, wait, started_at, call_ctx)

              pending_item =
                %{
                  dependency_job: job,
                  ref: job.ref,
                  pid: job.pid,
                  session_id: session_id,
                  call: call,
                  tool_call_id: tool_call_id,
                  tool_name: call[:name] || call["name"],
                  call_index: call[:call_index] || call["call_index"],
                  started_at: started_at,
                  auto_wait_seconds: auto_wait_seconds,
                  trace_ctx: ctx[:trace_ctx],
                  observability_link: SystemsObservability.Context.inject(observability_context),
                  tenant_id: ctx[:tenant_id],
                  group_id: ctx[:group_id],
                  role: ctx[:role],
                  billing_context: ctx[:billing_context] || %{},
                  actor_type: ctx[:actor_type] || "tool"
                }
                |> put_async_trusted_origin(call_ctx)
                |> Map.put("terminal_reply", call[:terminal_reply])

              pending = [pending_item | pending]

              {result, pending}
          end

        {_call, _call_ctx, {:inline, result}}, pending ->
          {result, pending}

        {_call, _call_ctx, {:error, result}}, pending ->
          {result, pending}
      end)

    pending = Enum.reverse(pending)
    results = merge_batch_auto_wait(results)

    results =
      prepared
      |> merge_prepared_results(results, started_at)
      |> collect_tool_observations(ctx, async: false)
      |> archive_results(ctx)

    {results, pending}
  end

  # Pure admission projection. The caller commits these running observations
  # with the assistant intent before executing any tool dependency.
  @doc false
  def planned_async_results(calls, ctx) do
    started_at = System.system_time(:millisecond)

    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, results} ->
      with false <- guidance_call?(call),
           {:ok, call_ctx} <- SalixAgent.ToolCallProvenance.select(call, ctx) do
        id = tool_call_id(call)
        wait = auto_wait(id, call, auto_wait_seconds_for_call(call), required_session_id!(ctx))
        result = async_running_result(call, id, wait, started_at, call_ctx)
        {:cont, {:ok, [result | results]}}
      else
        _ -> {:halt, :fallback}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, results |> Enum.reverse() |> merge_batch_auto_wait()}
      :fallback -> :fallback
    end
  end

  defp prepare_tool_dependency(call, ctx, observability_context) do
    case SalixAgent.ToolCallProvenance.select(call, ctx) do
      {:ok, call_ctx} ->
        {call, call_ctx, start_tool_dependency(call, call_ctx, observability_context)}

      {:error, reason} ->
        {call, ctx,
         {:inline,
          error_result(
            call,
            "Select one admitted Task source: triage_delegation_ref for Triage, or source_message_id for a human request. Do not combine them: " <>
              reason,
            reason
          )}}
    end
  end

  defp start_tool_dependency(call, ctx, observability_context) do
    case runtime_ownership_check(ctx) do
      :ok ->
        do_start_tool_dependency(call, ctx, observability_context)

      {:error, :fenced} ->
        # This node's runtime for the agent was superseded: refuse to fire
        # the side effect — inline (guidance, js-host leaf) and dependency
        # branches alike. Any later attempt to commit this result is fenced
        # by the session store anyway; refusing here keeps the external
        # effect itself from happening (rollout-concurrent-runner-fencing D3).
        {:inline,
         error_result(
           call,
           "runtime ownership for this agent moved to another node",
           "runtime_fenced"
         )}
    end
  end

  defp do_start_tool_dependency(call, ctx, observability_context) do
    admission_context = Map.get(ctx, @dependency_admission_context_key)

    cond do
      guidance_call?(call) ->
        # Tool disclosure and schema validation happen in prepare_calls/2,
        # before dependency admission. A rejected call has no user-owned
        # dependency to isolate, and must remain synchronous so capability
        # surfaces cannot return async_running before the authorization result.
        {:inline, run_tool_dependency(call, ctx, observability_context)}

      is_reference(admission_context) ->
        # A script host call is a leaf of the already-admitted outer script.run
        # dependency. Reusing that admission avoids self-saturation at a
        # per-tenant limit of one while retaining the outer actor-owned deadline.
        {:inline, run_tool_dependency(call, ctx, observability_context)}

      true ->
        start_new_tool_dependency(call, ctx, observability_context)
    end
  end

  defp runtime_ownership_check(%{agent_id: agent_id}) when is_binary(agent_id),
    do: SalixAgent.OwnershipCell.check(agent_id)

  defp runtime_ownership_check(_ctx), do: :ok

  defp start_new_tool_dependency(call, ctx, observability_context) do
    admission_context = make_ref()
    admitted_ctx = Map.put(ctx, @dependency_admission_context_key, admission_context)

    dependency = fn ->
      run_tool_dependency(call, admitted_ctx, observability_context)
    end

    timeout_ms =
      tool_timeout_ms(call[:name] || call["name"], call[:args] || call["args"] || %{}) + 1_000

    case DependencyJob.start(:tool, dependency_tenant_id(ctx), dependency, timeout_ms: timeout_ms) do
      {:ok, job} ->
        {:ok, job}

      {:error, :dependency_saturated} ->
        {:error,
         error_result(call, "tool dependency admission is saturated", "dependency_saturated")}

      {:error, reason} ->
        {:error,
         error_result(
           call,
           "tool dependency could not start: #{inspect(reason)}",
           "dependency_start_failed"
         )}
    end
  end

  defp run_tool_dependency(call, ctx, observability_context) do
    SystemsObservability.Context.run(observability_context, fn ->
      SystemsObservability.Trace.with_span(
        :salix_tool,
        %{
          component: "salix_agent",
          surface: observability_context.surface,
          operation: "execute"
        },
        fn ->
          call
          |> run_one_with_timeout(ctx)
          |> SalixAgent.ToolCallProvenance.stamp_result(ctx)
          |> SalixAgent.IFC.Check.stamp_result(call, ctx, ctx[:ifc_round_label])
        end
      )
    end)
  end

  defp dependency_tenant_id(%{tenant_id: tenant_id})
       when is_binary(tenant_id) and tenant_id != "",
       do: tenant_id

  defp dependency_tenant_id(%{agent_id: agent_id}) when is_binary(agent_id),
    do: "agent:" <> agent_id

  @doc false
  def emit_deferred_tool_observations(results) when is_list(results) do
    results
    |> Enum.flat_map(&deferred_tool_observations/1)
    |> Enum.each(&SalixAgent.ToolTelemetry.emit_fact/1)

    :ok
  end

  @doc false
  def has_deferred_tool_observations?(result),
    do: deferred_tool_observations(result) != []

  @doc false
  def strip_deferred_tool_observations(result), do: drop_deferred_tool_observations(result)

  defp collect_tool_observations(results, ctx, opts) when is_list(results) do
    attrs =
      ctx
      |> Map.take([
        :agent_id,
        :session_id,
        :tenant_id,
        :group_id,
        :trace_ctx,
        :billing_context,
        :actor_type
      ])
      |> Map.merge(Map.new(opts))

    defer? = Map.get(ctx, :defer_tool_observations) == true
    Enum.map(results, &collect_tool_observation(&1, attrs, defer?))
  end

  defp collect_tool_observation(result, attrs, true) do
    facts = deferred_tool_observations(result)

    facts =
      case SalixAgent.ToolTelemetry.terminal_fact(result, attrs) do
        {:ok, fact} -> facts ++ [fact]
        :skip -> facts
        {:error, _reason} -> facts
      end

    put_deferred_tool_observations(result, facts)
  end

  defp collect_tool_observation(result, attrs, false) do
    result
    |> deferred_tool_observations()
    |> Enum.each(&SalixAgent.ToolTelemetry.emit_fact/1)

    SalixAgent.ToolTelemetry.emit_tool_call(result, attrs)
    drop_deferred_tool_observations(result)
  end

  @doc false
  def deferred_tool_observations(result) when is_map(result) do
    result
    |> Map.get(:tool_observations, Map.get(result, "tool_observations", []))
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  def deferred_tool_observations(_result), do: []

  defp put_deferred_tool_observations(result, []),
    do: drop_deferred_tool_observations(result)

  defp put_deferred_tool_observations(result, facts),
    do: Map.put(result, :tool_observations, facts)

  defp drop_deferred_tool_observations(result) when is_map(result) do
    result
    |> Map.delete(:tool_observations)
    |> Map.delete("tool_observations")
  end

  @doc false
  def tool_timeout_ms(name, args \\ %{}) do
    name = to_string(name)

    :salix_agent
    |> Application.get_env(:tool_timeouts, %{})
    |> configured_tool_timeout_ms(name)
    |> case do
      # Operator config wins; otherwise honor a per-call timeout (Exec), then
      # fall back to the per-tool default.
      nil -> call_tool_timeout_ms(name, args) || default_tool_timeout_ms(name)
      timeout -> timeout
    end
  end

  # A long cloud-VM `Exec` (e.g. `timeout: 120`) must not be killed at the 30s
  # default. Derive the outer deadline from the caller's seconds, plus a grace
  # margin (inner exec times out first), bounded by a ceiling.
  defp call_tool_timeout_ms("env.remote_shell", args) when is_map(args) do
    seconds = Map.get(args, "timeout_seconds", 120)
    seconds = if is_integer(seconds), do: min(max(seconds, 1), 120), else: 120

    case args["action"] do
      "register" -> (seconds + 90) * 1_000
      "exec" -> (seconds + 15) * 1_000
      _ -> 60_000
    end
  end

  defp call_tool_timeout_ms("env.exec", args) do
    execution_ms = exec_arg_timeout_ms(args) || 120_000

    min(@max_exec_timeout_ms, execution_ms) +
      SalixAgent.Tools.AsyncPolicy.exec_readiness_timeout_ms() + @exec_timeout_grace_ms
  end

  defp call_tool_timeout_ms("env.process_tail", args) do
    case process_tail_wait_ms(args) do
      nil -> nil
      ms -> min(@max_exec_timeout_ms, ms + @exec_timeout_grace_ms)
    end
  end

  defp call_tool_timeout_ms("decide", _args), do: 5_000

  # The request's own `timeout_ms` (default 20s, at most 60s) plus grace, so
  # the HTTP client times out first and returns a real error.
  defp call_tool_timeout_ms("web.http_request", args),
    do: SalixAgent.Tools.HttpRequest.dispatch_timeout_ms(args)

  # Output waits, exec timeouts and transfers carry their own deadlines.
  defp call_tool_timeout_ms("ssh." <> _ = name, args) when is_map(args),
    do: SalixAgent.Tools.SSH.dispatch_timeout_ms(name, args)

  defp call_tool_timeout_ms(_name, _args), do: nil

  defp exec_arg_timeout_ms(args) when is_map(args) do
    case Map.get(args, "timeout", Map.get(args, :timeout)) do
      secs when is_integer(secs) and secs > 0 ->
        secs * 1_000

      secs when is_binary(secs) ->
        case Integer.parse(secs) do
          {v, ""} when v > 0 -> v * 1_000
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp exec_arg_timeout_ms(_args), do: nil

  defp process_tail_wait_ms(args) when is_map(args) do
    case Map.get(args, "wait_seconds", Map.get(args, :wait_seconds)) do
      secs when is_integer(secs) and secs > 0 ->
        secs * 1_000

      secs when is_binary(secs) ->
        case Integer.parse(secs) do
          {v, ""} when v > 0 -> v * 1_000
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp process_tail_wait_ms(_args), do: nil

  defp default_tool_timeout_ms("env.copy"), do: @copy_timeout_ms
  defp default_tool_timeout_ms("env.android"), do: @android_tool_timeout_ms
  defp default_tool_timeout_ms("memory.ask_worker"), do: 30_000
  # A build (15 s deadline in spinfoam) plus the run's wall limit and slack.
  defp default_tool_timeout_ms("script." <> _),
    do: 15_000 + SalixAgent.ScriptRun.wall_timeout_ms() + 2_000

  defp default_tool_timeout_ms("meeting.preparation.publish_personal_report"),
    do: SalixAgent.LLM.request_timeout_ms() + 5_000

  defp default_tool_timeout_ms("image.generate"), do: @image_generation_timeout_ms
  defp default_tool_timeout_ms("video.generate"), do: @video_generation_timeout_ms
  defp default_tool_timeout_ms("audio.transcribe"), do: @audio_transcription_timeout_ms
  defp default_tool_timeout_ms("mcp." <> _), do: @mcp_tool_timeout_ms
  defp default_tool_timeout_ms(_name), do: @default_tool_timeout_ms

  defp configured_tool_timeout_ms(overrides, name) when is_map(overrides) do
    overrides
    |> Map.get(name)
    |> positive_timeout_ms()
  end

  defp configured_tool_timeout_ms(_overrides, _name), do: nil

  defp positive_timeout_ms(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp positive_timeout_ms(timeout) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp positive_timeout_ms(_timeout), do: nil

  # Walk the batch counting capped tool names; calls over the cap become error
  # results in their original position, so every tool call has one result and
  # persisted tool_result order still matches the model's tool call order.
  defp enforce_caps(calls) do
    # Caps.check/2 is pure (the caller maintains the counts map); count by the
    # queried name — count_for tolerates alias keys.
    {prepared, _counts} =
      Enum.reduce(calls, {[], %{}}, fn call, {prepared, counts} ->
        name = to_string(call[:name] || call["name"] || "")

        case SalixMedia.Caps.check(counts, name) do
          :ok ->
            {[{:run, call} | prepared], Map.update(counts, name, 1, &(&1 + 1))}

          {:error, :cap_exceeded} ->
            CommaLog.log("tool_capped", %{
              tool: name,
              tool_call_id: tool_call_id(call)
            })

            {[
               {:capped, error_result(call, "per-turn cap exceeded for #{name}", "capped")}
               | prepared
             ], counts}
        end
      end)

    Enum.reverse(prepared)
  end

  defp executable_calls(prepared) do
    prepared
    |> Enum.flat_map(fn
      {:run, call} -> [call]
      {:capped, _result} -> []
    end)
  end

  defp merge_prepared_results(prepared, executed, batch_started_at) do
    {results, []} =
      Enum.map_reduce(prepared, executed, fn
        {:run, call}, [{:tool_crashed, reason} | rest] ->
          {crashed_result(call, reason, batch_started_at), rest}

        {:run, _call}, [result | rest] ->
          {result, rest}

        {:capped, result}, rest ->
          {result, rest}
      end)

    results
  end

  defp run_one(call, ctx) do
    name = call[:name] || call["name"]
    id = call[:id] || call["id"]
    args = call[:args] || call["args"] || %{}

    cond do
      guidance_call?(call) ->
        guidance_tool_result(
          call,
          guidance_error(call),
          guidance_target(call)
        )

      true ->
        case lookup(name) do
          nil ->
            %{
              id: id,
              name: name,
              content: "unknown tool: #{name}",
              error: true,
              error_class: "unknown_tool",
              events: []
            }

          fun ->
            # Willow's tc.ToolCallID (e.g. publish_html_preview's site-name fallback).
            # The information-flow evidence rides alongside it so a tool that
            # creates a durable resource can record the provenance the
            # dispatcher established (docs/verification.md).
            ctx =
              ctx
              |> Map.put(:tool_call_id, to_string(id || ""))
              |> Map.put(:ifc_declaration, SalixAgent.IFC.Declaration.from_call(call))
              |> put_present(:ifc_evidence, call[:ifc_evidence] || call["ifc_evidence"])

            try do
              SalixAgent.MeetingSummaryScope.authorize_tool!(name, ctx)

              case fun.(args, ctx) do
                {:tool_failure, diagnostic, error_class, visibility, public_summary, events}
                when is_binary(diagnostic) and is_binary(error_class) and
                       is_binary(visibility) and is_list(events) ->
                  tool_failure_result(
                    id,
                    name,
                    diagnostic,
                    error_class,
                    visibility,
                    public_summary,
                    events
                  )

                {:tool_failure, diagnostic, error_class, visibility, public_summary, events,
                 observations}
                when is_binary(diagnostic) and is_binary(error_class) and
                       is_binary(visibility) and is_list(events) and is_list(observations) ->
                  id
                  |> tool_failure_result(
                    name,
                    diagnostic,
                    error_class,
                    visibility,
                    public_summary,
                    events
                  )
                  |> Map.put(:tool_observations, observations)

                {:tool_status, status, content, events}
                when is_binary(status) and is_list(events) ->
                  id
                  |> tool_result(name, content, events, status_hint: status)
                  |> put_guidance_reason(status, content)

                {content, events} when is_list(events) ->
                  tool_result(id, name, content, events)

                {:tool_observations, content, events, observations}
                when is_list(events) and is_list(observations) ->
                  id
                  |> tool_result(name, content, events)
                  |> Map.put(:tool_observations, observations)

                # A read that knows what audience it returned says so here, and
                # the dispatcher's stamping step keeps that label rather than
                # the round's (docs/verification.md).
                {:tool_ifc, content, events, %{} = ifc} when is_list(events) ->
                  id
                  |> tool_result(name, content, events)
                  |> Map.put(:ifc, ifc)

                content ->
                  tool_result(id, name, content, [])
              end
            rescue
              e ->
                %{
                  id: id,
                  name: name,
                  content: "error: #{Exception.message(e)}",
                  error: true,
                  error_class: exception_error_class(e),
                  events: []
                }
            end
        end
    end
  end

  defp run_one_with_timeout(call, ctx) do
    name = call[:name] || call["name"]
    timeout = tool_timeout_ms(name, call[:args] || call["args"] || %{})
    started_at = System.system_time(:millisecond)

    CommaLog.log("tool_start", %{
      agent_id: Map.get(ctx, :agent_id),
      session_id: Map.get(ctx, :session_id),
      tool: name,
      tool_call_id: tool_call_id(call),
      args: call[:args] || call["args"] || %{},
      timeout_ms: timeout
    })

    started = System.monotonic_time(:millisecond)
    timing = {started_at, started}

    SalixAgent.ExecutionSurface.observe(
      ctx,
      SalixAgent.ExecutionSurface.record(
        tool_call_id(call),
        "tool",
        SalixAgent.ExecutionTiming.running(timing),
        %{
          "tool_call_id" => tool_call_id(call),
          "tool_name" => name,
          "status" => "running",
          "input" => history_operation_input(call)
        },
        true
      )
    )

    result = run_linked_tool(call, ctx, timeout)

    duration_ms = System.monotonic_time(:millisecond) - started

    status =
      cond do
        result.error ->
          "error"

        result[:status_hint] in ["guidance", "completed", "cancelled", "error"] ->
          result.status_hint

        async_started_event?(result.events) ->
          "async_running"

        true ->
          "completed"
      end

    result =
      result
      |> Map.delete(:status_hint)
      |> Map.put(:input, Jason.encode!(call[:args] || call["args"] || %{}))
      |> Map.put(:output, result.content)
      |> Map.put(:status, status)
      |> Map.put(:duration_ms, duration_ms)
      |> Map.put(:started_at, started_at)
      |> Map.put(:call_index, call[:call_index] || call["call_index"])
      |> Map.put(
        :error_class,
        result[:error_class] || if(result.error, do: "tool_error", else: nil)
      )
      |> Map.put(:error_message, if(result.error, do: result.content, else: nil))

    CommaLog.log("tool_end", %{
      agent_id: Map.get(ctx, :agent_id),
      session_id: Map.get(ctx, :session_id),
      tool: result.name,
      tool_call_id: result.id,
      error: result.error,
      content: result.content,
      event_count: length(result.events),
      duration_ms: duration_ms
    })

    SalixAgent.ExecutionSurface.observe(
      ctx,
      SalixAgent.ExecutionSurface.record(
        tool_call_id(call),
        "tool",
        SalixAgent.ExecutionTiming.from_tool(result),
        %{
          "tool_call_id" => tool_call_id(call),
          "tool_name" => name,
          "status" => status,
          "input" => history_operation_input(call)
        },
        false
      )
    )

    result
  end

  # The live overlay needs operation context before the canonical result arrives.
  # Keep its payload bounded: at most 16 known strings of 320 characters, never
  # credentials or arbitrary result/file bodies. Full arguments stay in the ledger.
  defp history_operation_input(call) do
    (call[:args] || call["args"] || %{})
    |> Map.take(~w(environment environment_id path working_dir conversation_id conversation_name
                   chat_id command query pattern url process_name description content text title))
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> Map.new(fn {key, value} -> {key, String.slice(value, 0, 320)} end)
  end

  # Keep the tool linked to the dependency owner so cancelling the outer job
  # cannot orphan user-controlled work. Trap only this child's exit long enough
  # to turn crashes into terminal tool results, then drain the exact link signal
  # before restoring the owner's prior exit policy.
  defp run_linked_tool(call, ctx, timeout) do
    previous_trap_exit = Process.flag(:trap_exit, true)
    deadline = System.monotonic_time(:millisecond) + timeout
    ctx = Map.put(ctx, :tool_deadline_ms, min(ctx[:tool_deadline_ms] || deadline, deadline))
    task = Task.async(fn -> run_one(call, ctx) end)

    try do
      result =
        case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          {:exit, reason} -> error_result(call, "tool crashed: #{inspect(reason)}", "crashed")
          nil -> error_result(call, "tool timed out after #{format_timeout(timeout)}", "timeout")
        end

      drain_link_exit(task.pid)
      result
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  defp drain_link_exit(pid) do
    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp tool_result(id, name, content, events, opts \\ []) do
    content = safe_content(content)
    status_hint = Keyword.get(opts, :status_hint)

    case vm_tool_error_class(content) do
      nil ->
        result = %{
          id: id,
          name: name,
          content: content,
          error: status_hint == "error",
          events: events
        }

        case status_hint do
          status when is_binary(status) -> Map.put(result, :status_hint, status)
          _ -> result
        end

      error_class ->
        %{
          id: id,
          name: name,
          content: content,
          error: true,
          events: events,
          error_class: error_class
        }
    end
  end

  # Presentation accepts only these labels. Any other value would silently
  # become a private diagnostic and lose its public summary.
  @failure_visibilities ~w(model_only user_reportable)

  defp tool_failure_result(
         id,
         name,
         diagnostic,
         error_class,
         visibility,
         public_summary,
         events
       ) do
    unless visibility in @failure_visibilities do
      raise ArgumentError, "unsupported tool failure visibility: #{inspect(visibility)}"
    end

    %{
      id: id,
      name: name,
      content: safe_content(diagnostic),
      error: true,
      error_class: error_class,
      diagnostic_visibility: visibility,
      public_summary: public_summary,
      events: events
    }
  end

  defp vm_tool_error_class(content) when is_binary(content) do
    with {:ok, %{"ok" => false, "error_class" => "vm_" <> _ = error_class}} <-
           Jason.decode(content) do
      error_class
    else
      _ -> nil
    end
  end

  defp async_started_event?(events) when is_list(events) do
    Enum.any?(events, &((Map.get(&1, "type") || Map.get(&1, :type)) == "async_tool_call_started"))
  end

  # The journal is JSON-lines: tool_result content MUST be valid UTF-8. A tool
  # surfacing raw bytes (e.g. a binary file body) must not be able to wedge the
  # agent in a crash-looping commit (Jason.EncodeError on every retried round).
  defp safe_content(content) do
    s = to_string(content)
    if String.valid?(s), do: s, else: "[binary tool output, #{byte_size(s)} bytes]"
  end

  # Tools signal ordinary failures by raising RuntimeError (`raise "msg"`,
  # e.g. fs.read_file's "no such file"), so those keep the "tool_error" class
  # the session-trace API promises. Only non-RuntimeError exception structs
  # (FunctionClauseError, ArgumentError, ...) classify as "exception" —
  # genuine bugs rather than tool-reported errors.
  @doc false
  def exception_error_class(%RuntimeError{}), do: "tool_error"
  def exception_error_class(_exception), do: "exception"

  # A crashed tool ran for real time before its task died: anchor telemetry to
  # the batch start instead of error_result/3's "now" default, so crash rows
  # don't skew latency queries with 0ms durations stamped at handling time.
  defp crashed_result(call, reason, started_at) do
    call
    |> error_result("tool crashed: #{inspect(reason)}", "crashed")
    |> Map.merge(%{
      started_at: started_at,
      duration_ms: max(System.system_time(:millisecond) - started_at, 0)
    })
  end

  defp error_result(call, msg, error_class),
    do: %{
      id: tool_call_id(call),
      name: call[:name] || call["name"],
      content: msg,
      error: true,
      input: Jason.encode!(call[:args] || call["args"] || %{}),
      output: msg,
      status: "error",
      duration_ms: 0,
      started_at: System.system_time(:millisecond),
      call_index: call[:call_index] || call["call_index"],
      error_class: error_class,
      error_message: msg,
      events: []
    }

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A file read says what audience it returned, the same way a Slack read does
  # (docs/verification.md, §8).
  defp labelled(result, paths, ctx), do: SalixAgent.IFC.FileLabels.join(result, paths, ctx)

  defp normalize_calls(calls), do: Enum.map(calls, &normalize_call/1)

  defp normalize_call(call) when is_map(call) do
    call
    |> Map.drop([:reply_intent, "reply_intent", :terminal_reply, "terminal_reply"])
    |> Map.put(:id, tool_call_id(call))
  end

  defp prepare_calls(calls, ctx) do
    calls
    |> normalize_calls()
    |> call_envelopes(ctx[:llm_tool_envelope] == true)
    |> Enum.map(&normalize_tool_input/1)
    |> Enum.map(&enforce_disclosed_tool(&1, ctx))
  end

  @doc false
  @spec prepare_for_dispatch([call()], ctx()) :: [call()]
  def prepare_for_dispatch(calls, ctx) when is_list(calls) and is_map(ctx),
    do: prepare_calls(calls, ctx)

  @doc false
  @spec recoverable_envelope_guidance(call()) :: {:ok, result()} | :not_recoverable
  def recoverable_envelope_guidance(call) when is_map(call) do
    ctx = %{llm_tool_envelope: true}
    call = normalize_call(call)

    # Restrict restart reconstruction to the durable pseudo-tool envelope.
    # A direct historical tool name may predate envelope enforcement and could
    # already have produced an effect under an older runtime.
    if to_string(call[:name] || call["name"] || "") == "call" do
      [prepared] = call_envelopes([call], ctx.llm_tool_envelope)

      if guidance_call?(prepared) do
        result =
          prepared
          |> guidance_tool_result(guidance_error(prepared), guidance_target(prepared))
          |> Map.delete(:status_hint)
          |> Map.put(:status, "guidance")

        {:ok, result}
      else
        :not_recoverable
      end
    else
      :not_recoverable
    end
  end

  def recoverable_envelope_guidance(_call), do: :not_recoverable

  # The kernel applies the call envelope (`LoopHost.callEnvelopes`): a direct
  # capability call from an enveloped runtime, or a `call` targeting
  # `wait_for`, becomes guidance, and a `call` becomes its target with the
  # target's arguments, reply intent, and IFC declaration.
  defp call_envelopes(calls, envelope?),
    do:
      SalixVerifiedKernel.Session.query(
        SalixVerifiedKernel.Session.open(%{__struct__: SalixAgent.InternalSession.State}),
        :call_envelopes,
        {calls, envelope?}
      )

  # `env.exec.description` is presentation metadata, not operational input.
  # Canonicalize it before disclosed-schema validation so a verbose label does
  # not turn an otherwise valid command into model-only repair guidance.
  defp normalize_tool_input(call) when is_map(call) do
    name = to_string(call[:name] || call["name"] || "")
    args = call[:args] || call["args"]

    if name == "env.exec" and is_map(args) do
      normalized_args = normalize_tool_params(name, args)

      call
      |> Map.put(:args, normalized_args)
      |> Map.put("args", normalized_args)
    else
      call
    end
  end

  defp enforce_disclosed_tool(call, ctx) do
    if disclosure_available?(ctx) do
      name = to_string(call[:name] || call["name"] || "")
      args = call[:args] || call["args"] || %{}

      cond do
        guidance_call?(call) ->
          call

        not SalixAgent.ToolDisclosure.callable?(ctx, name) ->
          guidance_call(call, "tool is not callable in this session", name, ctx, "not_callable")

        true ->
          case validate_disclosed_params(name, args, ctx) do
            :ok -> call
            {:error, reason} -> guidance_call(call, reason, name, ctx, "invalid_params")
          end
      end
    else
      name = to_string(call[:name] || call["name"] || "")

      guidance_call(
        call,
        "tool disclosure is required for tool dispatch",
        name,
        ctx,
        "not_disclosed"
      )
    end
  end

  defp disclosure_available?(%{tool_disclosure: %{"tools" => tools}}) when is_list(tools),
    do: true

  defp disclosure_available?(_ctx), do: false

  defp guidance_call_args?(args) when is_map(args) do
    Map.has_key?(args, "_guidance_error") or Map.has_key?(args, :_guidance_error)
  end

  defp guidance_call_args?(_args), do: false

  defp guidance_call?(call) when is_map(call) do
    Map.has_key?(call, :guidance_error) or Map.has_key?(call, "guidance_error") or
      guidance_call_args?(call[:args] || call["args"] || %{})
  end

  defp guidance_call?(_call), do: false

  defp guidance_error(call) when is_map(call) do
    args = call[:args] || call["args"] || %{}

    call[:guidance_error] || call["guidance_error"] ||
      args["_guidance_error"] || args[:_guidance_error]
  end

  defp guidance_target(call) when is_map(call) do
    args = call[:args] || call["args"] || %{}

    call[:guidance_tool] || call["guidance_tool"] ||
      args["_guidance_tool"] || args[:_guidance_tool] ||
      call[:name] || call["name"]
  end

  defp guidance_reason(call) when is_map(call) do
    args = call[:args] || call["args"] || %{}

    call[:guidance_reason] || call["guidance_reason"] ||
      args["_guidance_reason"] || args[:_guidance_reason]
  end

  defp validate_disclosed_params(target, args, ctx),
    do: validate_tool_params(target, args, ctx)

  defp guidance_call(call, reason, target, ctx, guidance_reason)

  defp guidance_call(call, reason, target, %{llm_tool_envelope: true}, guidance_reason) do
    call
    |> Map.put(:name, "call")
    |> Map.put("name", "call")
    |> put_guidance_metadata(reason, target, guidance_reason)
  end

  defp guidance_call(call, reason, target, _ctx, guidance_reason) do
    target = to_string(target || call[:name] || call["name"] || "")

    call
    |> Map.put(:name, target)
    |> Map.put("name", target)
    |> put_guidance_metadata(reason, target, guidance_reason)
  end

  defp put_guidance_metadata(call, reason, target, guidance_reason) do
    call
    # A rejected call has no delivery intent. Keep its parameter guidance from
    # being replaced by final-reply authorization for the synthetic call tool.
    |> Map.delete(:reply_intent)
    |> Map.put(:guidance_error, reason)
    |> Map.put(:guidance_tool, to_string(target || ""))
    |> maybe_put_guidance_reason(guidance_reason)
  end

  defp maybe_put_guidance_reason(call, reason)
       when reason in ~w(not_callable not_disclosed invalid_params envelope_misuse),
       do: Map.put(call, :guidance_reason, reason)

  defp maybe_put_guidance_reason(call, _reason), do: call

  defp tool_call_id(call) do
    case call[:id] || call["id"] do
      id when is_binary(id) and id != "" -> id
      id when is_integer(id) -> Integer.to_string(id)
      id when is_atom(id) -> Atom.to_string(id)
      _ -> "tool-" <> random_id()
    end
  end

  defp async_running_result(call, tool_call_id, wait, started_at, ctx) do
    name = call[:name] || call["name"]
    args = call[:args] || call["args"] || %{}
    duration_ms = System.system_time(:millisecond) - started_at

    content =
      Jason.encode!(%{
        "status" => "running",
        "tool_call_id" => tool_call_id,
        "tool_name" => name,
        "auto_wait_seconds" => wait["timeout_seconds"],
        "message" =>
          "tool is still running asynchronously; completion will arrive as a session notification"
      })

    %{
      id: tool_call_id,
      name: name,
      content: content,
      error: false,
      input: Jason.encode!(args),
      output: content,
      status: "async_running",
      duration_ms: duration_ms,
      started_at: started_at,
      call_index: call[:call_index] || call["call_index"],
      error_class: nil,
      error_message: nil,
      events: [
        %{
          "type" => "async_tool_call_started",
          "session_id" => wait["session_id"],
          "tool_call_id" => tool_call_id,
          "tool_name" => name,
          "input" => Jason.encode!(args),
          "status" => "running",
          "started_at" => started_at,
          "auto_wait_seconds" => wait["timeout_seconds"]
        }
        |> put_async_trusted_origin(ctx)
        |> Map.put("terminal_reply", call[:terminal_reply])
      ]
    }
  end

  # The session owner, not the model or dependency, stamps the exact trusted
  # activation which admitted this async call. The durable start record and the
  # process-local pending token carry the same provenance so a terminal
  # notification can continue only that source-bound turn.
  defp put_async_trusted_origin(map, ctx) when is_map(map) and is_map(ctx) do
    SalixAgent.ToolCallProvenance.stamp(map, ctx)
  end

  defp merge_batch_auto_wait(results) do
    waits =
      results
      |> async_wait_candidates()
      |> Enum.group_by(& &1.session_id)
      |> Enum.map(fn {_session_id, candidates} -> batch_auto_wait(candidates) end)

    if waits == [] do
      results
    else
      results
      |> Enum.map(&drop_auto_wait_events/1)
      |> append_batch_waits(waits)
    end
  end

  defp append_batch_waits(results, []), do: results

  defp append_batch_waits(results, [{primary_index, wait} | rest]) do
    results =
      results
      |> Enum.with_index()
      |> Enum.map(fn {result, index} ->
        if index == primary_index do
          Map.update!(
            result,
            :events,
            &(&1 ++ [Waits.event(wait["session_id"], Map.delete(wait, "session_id"))])
          )
        else
          result
        end
      end)

    append_batch_waits(results, rest)
  end

  defp async_wait_candidates(results) do
    results
    |> Enum.with_index()
    |> Enum.flat_map(fn {result, index} ->
      result
      |> Map.get(:events, [])
      |> Enum.flat_map(fn
        %{"type" => "async_tool_call_started"} = event ->
          tool_call_id = event["tool_call_id"]
          session_id = event["session_id"]

          if is_binary(tool_call_id) and tool_call_id != "" and is_binary(session_id) and
               session_id != "" do
            [
              %{
                index: index,
                tool_call_id: tool_call_id,
                tool_name: event["tool_name"],
                provenance: event,
                session_id: session_id,
                auto_wait_seconds: normalize_auto_wait_seconds(event["auto_wait_seconds"])
              }
            ]
          else
            []
          end

        _ ->
          []
      end)
    end)
  end

  defp drop_auto_wait_events(result) do
    Map.update(result, :events, [], fn events ->
      Enum.reject(events, &auto_wait_event?/1)
    end)
  end

  defp auto_wait_event?(%{"type" => "wait_set", "wait" => %{"source" => "auto_wait"}}), do: true
  defp auto_wait_event?(_event), do: false

  defp batch_auto_wait(candidates) do
    chosen = Enum.min_by(candidates, &{&1.auto_wait_seconds, &1.index})
    ids = Enum.map(candidates, & &1.tool_call_id)
    names = candidates |> Enum.map(&to_string(&1.tool_name)) |> Enum.uniq() |> Enum.join(", ")

    provenance = %{
      source_message_ids:
        Enum.flat_map(candidates, &List.wrap(&1.provenance["trusted_origin_source_message_ids"])),
      trusted_origin: chosen.provenance["trusted_origin"],
      trusted_origins:
        candidates
        |> Enum.flat_map(&SalixAgent.ToolCallProvenance.origins(&1.provenance))
        |> Enum.uniq()
    }

    {chosen.index,
     Waits.build(
       "async tool call still running: " <> names,
       chosen.auto_wait_seconds,
       "auto_wait",
       %{
         "tool_call_id" => chosen.tool_call_id,
         "tool_call_ids" => ids,
         "tool_name" => chosen.tool_name,
         "session_id" => chosen.session_id
       }
     )
     |> put_async_trusted_origin(provenance)}
  end

  defp auto_wait_seconds_for_call(call) do
    name = call[:name] || call["name"]

    case find_entry(name) do
      nil -> @normal_auto_wait_seconds
      entry -> entry_auto_wait_seconds(entry)
    end
  end

  defp auto_wait(tool_call_id, call, timeout_seconds, session_id) do
    # The caller passes ctx.session_id into wait["session_id"] below; keeping it
    # inside the wait payload avoids a separate return channel for the event.
    Waits.build(
      "tool #{call[:name] || call["name"]} is still running",
      timeout_seconds,
      "auto_wait",
      %{
        "tool_call_id" => tool_call_id,
        "tool_name" => call[:name] || call["name"],
        "session_id" => session_id
      }
    )
  end

  defp required_session_id!(ctx) when is_map(ctx) do
    case Map.get(ctx, :session_id) do
      session_id when is_binary(session_id) ->
        session_id = String.trim(session_id)
        if session_id == "", do: raise("ctx.session_id is required"), else: session_id

      _ ->
        raise "ctx.session_id is required"
    end
  end

  defp format_timeout(ms) when rem(ms, 60_000) == 0, do: "#{div(ms, 60_000)}m"
  defp format_timeout(ms) when rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}s"
  defp format_timeout(ms), do: "#{ms}ms"

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp lookup(name) do
    case to_string(name || "") do
      "call" ->
        &__MODULE__.call/2

      "im_api." <> _ ->
        fn args, ctx ->
          SalixAgent.Tools.ImRouter.call_dynamic_operation(to_string(name), args, ctx)
        end

      "mcp." <> _ ->
        case find_entry(name) do
          nil ->
            fn args, ctx ->
              SalixAgent.Tools.MCP.call_dynamic_operation(to_string(name), args, ctx)
            end

          entry ->
            entry_fun(entry)
        end

      _ ->
        case find_entry(name) do
          nil -> nil
          entry -> entry_fun(entry)
        end
    end
  end

  @doc false
  def find_entry(name), do: Enum.find(registry(), &(entry_name(&1) == name))

  @doc false
  def entry_name({name, _desc, _fun, _auto_wait_seconds}), do: name
  def entry_name({name, _desc, _third, _fourth, _fifth}), do: name
  def entry_name({name, _desc, _schema, _fun, _auto_wait_seconds, _opts}), do: name

  @doc false
  def entry_description({_name, desc, _fun, _auto_wait_seconds}), do: desc
  def entry_description({_name, desc, _third, _fourth, _fifth}), do: desc
  def entry_description({_name, desc, _schema, _fun, _auto_wait_seconds, _opts}), do: desc

  @doc false
  def entry_schema({_name, _desc, schema, fun, _auto_wait_seconds})
      when is_map(schema) and is_function(fun, 2),
      do: schema

  def entry_schema({_name, _desc, schema, fun, _auto_wait_seconds, _opts})
      when is_map(schema) and is_function(fun, 2),
      do: schema

  def entry_schema(entry), do: SalixAgent.Tools.Schemas.schema(entry_name(entry)) || %{}

  @doc false
  def entry_auto_wait_seconds({_name, _desc, _fun, seconds}),
    do: normalize_auto_wait_seconds(seconds)

  def entry_auto_wait_seconds({_name, _desc, fun, seconds, _opts}) when is_function(fun, 2),
    do: normalize_auto_wait_seconds(seconds)

  def entry_auto_wait_seconds({_name, _desc, _schema, fun, seconds}) when is_function(fun, 2),
    do: normalize_auto_wait_seconds(seconds)

  def entry_auto_wait_seconds({_name, _desc, _schema, fun, seconds, _opts})
      when is_function(fun, 2),
      do: normalize_auto_wait_seconds(seconds)

  @doc false
  def entry_fun({_name, _desc, fun, _auto_wait_seconds}), do: fun
  def entry_fun({_name, _desc, fun, _auto_wait_seconds, _opts}) when is_function(fun, 2), do: fun

  def entry_fun({_name, _desc, _schema, fun, _auto_wait_seconds}) when is_function(fun, 2),
    do: fun

  def entry_fun({_name, _desc, _schema, fun, _auto_wait_seconds, _opts})
      when is_function(fun, 2),
      do: fun

  @doc false
  def entry_roles({_name, _desc, _fun, _auto_wait_seconds}), do: []

  def entry_roles({_name, _desc, fun, _auto_wait_seconds, opts}) when is_function(fun, 2),
    do: roles_from_opts(opts)

  def entry_roles({_name, _desc, _schema, fun, _auto_wait_seconds}) when is_function(fun, 2),
    do: []

  def entry_roles({_name, _desc, _schema, fun, _auto_wait_seconds, opts})
      when is_function(fun, 2),
      do: roles_from_opts(opts)

  @doc false
  def entry_runtimes({_name, _desc, _fun, _auto_wait_seconds}), do: []

  def entry_runtimes({_name, _desc, fun, _auto_wait_seconds, opts}) when is_function(fun, 2),
    do: runtimes_from_opts(opts)

  def entry_runtimes({_name, _desc, _schema, fun, _auto_wait_seconds})
      when is_function(fun, 2),
      do: []

  def entry_runtimes({_name, _desc, _schema, fun, _auto_wait_seconds, opts})
      when is_function(fun, 2),
      do: runtimes_from_opts(opts)

  @doc false
  def entry_safety({name, _desc, _fun, _auto_wait_seconds}), do: default_safety(name)

  def entry_safety({name, _desc, fun, _auto_wait_seconds, opts}) when is_function(fun, 2),
    do: safety_from_opts(opts) || default_safety(name)

  def entry_safety({name, _desc, _schema, fun, _auto_wait_seconds})
      when is_function(fun, 2),
      do: default_safety(name)

  def entry_safety({name, _desc, _schema, fun, _auto_wait_seconds, opts})
      when is_function(fun, 2),
      do: safety_from_opts(opts) || default_safety(name)

  defp roles_from_opts(opts) when is_list(opts) do
    opts
    |> Keyword.get(:roles, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp roles_from_opts(_opts), do: []

  defp runtimes_from_opts(opts) when is_list(opts) do
    opts
    |> Keyword.get(:runtimes, [])
    |> List.wrap()
    |> Enum.flat_map(fn
      value when value in [:internal, :external, :script] -> [value]
      "internal" -> [:internal]
      "external" -> [:external]
      "script" -> [:script]
      _unsupported -> []
    end)
  end

  defp runtimes_from_opts(_opts), do: []

  defp safety_from_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :safety) do
      safety when is_binary(safety) and safety != "" -> safety
      safety when is_atom(safety) and not is_nil(safety) -> Atom.to_string(safety)
      _missing -> nil
    end
  end

  defp safety_from_opts(_opts), do: nil

  defp default_safety(name) when name in @read_safety_tools, do: "read"
  defp default_safety(_name), do: nil

  @doc false
  def normalize_auto_wait_seconds(seconds) when is_integer(seconds) and seconds > 0, do: seconds

  def normalize_auto_wait_seconds(seconds),
    do: raise("invalid auto_wait_timeout_seconds: #{inspect(seconds)}")

  # ---- runtime meta tools ----

  @doc false
  def call(args, %{llm_tool_envelope: true}) do
    tool = args |> arg("_guidance_tool") |> String.trim()

    if tool == "call" do
      guidance_result(%{
        "status" => "guidance",
        "error" =>
          "call is the internal LLM tool envelope and cannot be nested; put the target business tool directly in the outer tool field",
        "tool" => "call",
        "next_action" =>
          "Retry with a single call envelope whose tool is the target business tool or runtime meta tool."
      })
    else
      call_guidance(args)
    end
  end

  def call(args, _ctx) do
    tool = args |> arg("_guidance_tool") |> String.trim()
    error = args |> arg("_guidance_error") |> String.trim()

    guidance_result(%{
      "status" => "guidance",
      "error" => if(error == "", do: "invalid tool envelope", else: error),
      "tool" => tool,
      "help_tool" => "help",
      "help_params" => %{"tool" => tool},
      "next_action" =>
        "Call canonical tools through the current runtime envelope. Use help through the same envelope when you need a tool manual or schema."
    })
  end

  defp call_guidance(args) do
    tool = args |> arg("_guidance_tool") |> String.trim()
    error = args |> arg("_guidance_error") |> String.trim()

    guidance_result(%{
      "status" => "guidance",
      "error" => if(error == "", do: "invalid call envelope", else: error),
      "tool" => tool,
      "help_tool" => "help",
      "help_params" => %{"tool" => tool},
      "next_action" =>
        "Read this tool's manual through help, then retry with params matching that schema."
    })
  end

  @doc false
  def help(args, ctx) do
    tool = args |> arg("tool") |> String.trim()
    help_target = if tool == "ifc", do: "help", else: tool

    cond do
      tool == "" ->
        help_guidance("tool is required", tool, "invalid_params")

      tool in SalixAgent.ToolDisclosure.discovery_namespaces() ->
        tools =
          get_in(ctx, [:tool_disclosure, "tools"])
          |> List.wrap()
          |> Enum.filter(fn entry ->
            String.starts_with?(entry["name"], tool <> ".") and
              SalixAgent.ToolDisclosure.helpable?(ctx, entry["name"])
          end)
          |> Enum.map(&Map.take(&1, ["name", "summary"]))
          |> Enum.sort_by(& &1["name"])

        Jason.encode!(%{"namespace" => tool, "tools" => tools})

      not SalixAgent.ToolDisclosure.helpable?(ctx, help_target) ->
        help_guidance("tool is not helpable in this session", tool, "not_callable")

      true ->
        case help_payload(tool, ctx) do
          {:ok, payload} -> Jason.encode!(payload)
          {:error, reason} -> help_guidance(reason, tool, "invalid_params")
        end
    end
  end

  defp help_payload("ifc", _ctx) do
    {:ok, %{"name" => "ifc", "manual" => SalixAgent.IFC.Help.manual()}}
  end

  defp help_payload(tool, ctx) do
    case SalixAgent.ToolDisclosure.find_disclosure_entry(ctx, tool) do
      nil ->
        {:error, "unknown tool: #{tool}"}

      %{"input_schema" => schema} = entry when is_map(schema) ->
        {:ok,
         %{
           "name" => tool,
           "summary" => entry["summary"] || "",
           "manual" => entry["manual"] || entry["summary"] || "",
           "input_schema" => schema,
           "examples" => entry["examples"] || %{}
         }}

      %{} ->
        {:error, "tool disclosure schema is missing"}
    end
  end

  @doc false
  def help_examples(tool, schema) do
    params = example_params_for_schema(schema)

    %{
      "internal_llm" => %{
        "tool" => "call",
        "arguments" => %{"tool" => tool, "params" => params}
      },
      "external_runtime" => %{"tool" => tool, "arguments" => params},
      "script" => %{"source" => script_example(tool, params)}
    }
  end

  # A complete script.run program that makes one salix.call and returns the
  # tool's content as the run's result (script.sdk explains the pieces).
  defp script_example(tool, params) do
    call = Jason.encode!(%{"tool" => tool, "args" => params})
    literal = call |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

    """
    #include "spinfoam.h"
    static const char CALL[] = "#{literal}";
    SF_MAIN sf_i64 main(void) {
      sf_handle call = sf_json_parse(CALL, sizeof(CALL) - 1);
      sf_handle reply = sf_host_call("salix.call", call, 20000);
      sf_drop(call);
      if (reply < 0) return reply;
      sf_handle out = sf_json_object();
      sf_handle value = sf_json_get(reply, "value");
      if (value >= 0) { sf_json_set(out, "value", value); sf_drop(value); }
      sf_handle stored = sf_host_call("script.result", out, 5000);
      sf_drop(out); sf_drop(reply);
      return stored < 0 ? stored : 0;
    }
    """
  end

  defp help_guidance(reason, tool, guidance_reason) do
    guidance_result(%{
      "status" => "guidance",
      "error" => reason,
      "tool" => tool,
      "guidance_reason" => guidance_reason
    })
  end

  # Guidance keeps its closed reason beside the content, as
  # guidance_tool_result/3 does, so a redacted failure record retains it.
  defp put_guidance_reason(result, "guidance", content) do
    case Jason.decode(content) do
      {:ok, %{"guidance_reason" => reason}} when is_binary(reason) ->
        Map.put(result, :guidance_reason, reason)

      _ ->
        result
    end
  end

  defp put_guidance_reason(result, _status, _content), do: result

  defp guidance_result(payload) when is_map(payload) do
    {:tool_status, "guidance", Jason.encode!(payload), []}
  end

  @doc false
  def validate_tool_params(target, args, ctx)

  def validate_tool_params(target, args, ctx) when is_map(args) do
    args = normalize_tool_params(target, args)

    case SalixAgent.ToolDisclosure.find_disclosure_entry(ctx, target) do
      %{"input_schema" => schema} when is_map(schema) ->
        validate_schema(args, schema)

      %{} ->
        {:error, "tool disclosure schema is missing"}

      nil ->
        {:error, "tool is not disclosed in this session"}
    end
  end

  def validate_tool_params(_target, _args, _ctx),
    do: {:error, "params must be an object"}

  defp normalize_tool_params("env.exec", args) when is_map(args) do
    case raw_arg(args, "description") do
      description when is_binary(description) ->
        args
        |> Map.delete(:description)
        |> Map.put("description", Schemas.normalize_exec_description(description))

      _other ->
        args
    end
  end

  defp normalize_tool_params(_target, args), do: args

  @doc false
  def guidance_tool_result(call, reason, target \\ nil) when is_map(call) do
    tool = guidance_tool_name(target, call)
    args = call[:args] || call["args"] || %{}
    guidance_reason = guidance_reason(call)

    content =
      Jason.encode!(%{
        "status" => "guidance",
        "error" => reason,
        "tool" => tool,
        "guidance_reason" => guidance_reason,
        "help_tool" => "help",
        "help_params" => %{"tool" => tool},
        "next_action" =>
          "Read this tool's manual through the current runtime envelope, then retry with params matching that schema."
      })

    %{
      id: tool_call_id(call),
      name: tool,
      content: content,
      error: false,
      status_hint: "guidance",
      input: Jason.encode!(args),
      output: content,
      guidance_reason: guidance_reason,
      duration_ms: 0,
      error_class: nil,
      error_message: nil,
      events: []
    }
  end

  # An envelope without a target (`'tool' is required`) names no tool. Its
  # guidance then belongs to the call the model made, so the result keeps a
  # valid tool name and returns to the model in the same round.
  defp guidance_tool_name(target, call) do
    [target, call[:name], call["name"]]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.find("call", &(&1 != ""))
  end

  @doc false
  def validate_schema(args, schema) when is_map(args) and is_map(schema) do
    props = map_schema_value(schema["properties"])
    required = list_schema_value(schema["required"])
    missing = missing_required_params(args, required, props)

    validation_errors =
      property_validation_errors(args, props) ++
        additional_property_validation_errors(args, props, schema) ++
        composition_validation_errors(args, schema)

    cond do
      missing != [] ->
        {:error,
         "missing required params: " <>
           Enum.map_join(missing, ", ", &describe_missing_param(args, &1))}

      validation_errors == [] ->
        :ok

      true ->
        {:error, "invalid params: " <> Enum.join(validation_errors, ", ")}
    end
  end

  defp map_schema_value(value) when is_map(value), do: value
  defp map_schema_value(_value), do: %{}

  defp list_schema_value(value) when is_list(value), do: value
  defp list_schema_value(_value), do: []

  defp missing_required_params(args, required, props) do
    required
    |> Enum.map(&to_string/1)
    |> Enum.filter(fn key ->
      value = schema_arg(args, key)
      prop = Map.get(props, key, %{})

      not schema_arg_present?(args, key) or
        (missing_param?(value, prop) and not property_allows_null?(prop))
    end)
  end

  # The model sent a blank string, not nothing. Saying so lets it correct the
  # value instead of resending the same call.
  defp describe_missing_param(args, key) do
    value = schema_arg(args, key)

    if schema_arg_present?(args, key) and is_binary(value),
      do: key <> " (empty string)",
      else: key
  end

  defp schema_arg_present?(args, key) do
    Map.has_key?(args, key) or
      case existing_atom_key(key) do
        nil -> false
        atom -> Map.has_key?(args, atom)
      end
  end

  defp existing_atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp property_allows_null?(%{"type" => "null"}), do: true

  defp property_allows_null?(%{"anyOf" => alternatives}) when is_list(alternatives),
    do: Enum.any?(alternatives, &match?(%{"type" => "null"}, &1))

  defp property_allows_null?(_property), do: false

  defp property_validation_errors(args, props) do
    props
    |> Enum.flat_map(fn {key, prop} ->
      key = to_string(key)
      value = schema_arg(args, key)

      if missing_param?(value, prop) do
        []
      else
        prop = map_schema_value(prop)

        type_error(key, value, prop) ++
          enum_error(key, value, prop) ++
          numeric_bound_errors(key, value, prop) ++
          string_length_errors(key, value, prop)
      end
    end)
  end

  defp additional_property_validation_errors(
         args,
         props,
         %{"additionalProperties" => false}
       ) do
    allowed_keys = props |> Map.keys() |> Enum.map(&to_string/1) |> MapSet.new()

    unknown_keys =
      args
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(allowed_keys, &1))
      |> Enum.sort()

    case unknown_keys do
      [] -> []
      keys -> ["unknown params: " <> Enum.join(keys, ", ")]
    end
  end

  defp additional_property_validation_errors(_args, _props, _schema), do: []

  defp type_error(key, value, prop) do
    if schema_type_matches?(value, prop["type"]) do
      []
    else
      [key <> " must be " <> to_string(prop["type"])]
    end
  end

  defp enum_error(key, value, %{"enum" => enum}) when is_list(enum) do
    if Enum.any?(enum, &(&1 == value)) do
      []
    else
      [key <> " must be one of " <> Enum.map_join(enum, ", ", &Jason.encode!/1)]
    end
  end

  defp enum_error(_key, _value, _prop), do: []

  defp numeric_bound_errors(key, value, prop) when is_number(value) do
    minimum = prop["minimum"]
    maximum = prop["maximum"]

    []
    |> maybe_add_error(is_number(minimum) and value < minimum, "#{key} must be >= #{minimum}")
    |> maybe_add_error(is_number(maximum) and value > maximum, "#{key} must be <= #{maximum}")
  end

  defp numeric_bound_errors(_key, _value, _prop), do: []

  defp string_length_errors(key, value, prop) when is_binary(value) do
    min_length = prop["minLength"]
    max_length = prop["maxLength"]
    length = String.length(value)

    []
    |> maybe_add_error(
      is_integer(min_length) and length < min_length,
      "#{key} length must be >= #{min_length}"
    )
    |> maybe_add_error(
      is_integer(max_length) and length > max_length,
      "#{key} length must be <= #{max_length}"
    )
  end

  defp string_length_errors(_key, _value, _prop), do: []

  defp maybe_add_error(errors, true, error), do: errors ++ [error]
  defp maybe_add_error(errors, _condition, _error), do: errors

  defp composition_validation_errors(args, %{"oneOf" => alternatives})
       when is_list(alternatives) do
    matches = Enum.count(alternatives, &schema_condition_matches?(args, &1))

    if matches == 1 do
      []
    else
      ["must match exactly one schema alternative"]
    end
  end

  defp composition_validation_errors(_args, _schema), do: []

  defp schema_condition_matches?(args, schema) when is_map(schema) do
    required_params_present?(args, list_schema_value(schema["required"])) and
      schema_properties_match?(args, map_schema_value(schema["properties"])) and
      any_of_matches?(args, schema["anyOf"]) and
      not_schema_does_not_match?(args, schema["not"])
  end

  defp schema_condition_matches?(_args, _schema), do: false

  defp required_params_present?(args, required) do
    Enum.all?(required, &schema_arg_present?(args, to_string(&1)))
  end

  defp schema_properties_match?(args, properties) do
    Enum.all?(properties, fn {key, property} ->
      key = to_string(key)

      not schema_arg_present?(args, key) or
        schema_property_matches?(schema_arg(args, key), map_schema_value(property))
    end)
  end

  defp schema_property_matches?(value, %{"anyOf" => alternatives})
       when is_list(alternatives) do
    Enum.any?(alternatives, &schema_property_matches?(value, map_schema_value(&1)))
  end

  defp schema_property_matches?(value, property) do
    schema_type_matches?(value, property["type"]) and
      case property["enum"] do
        enum when is_list(enum) -> Enum.any?(enum, &(&1 == value))
        _other -> true
      end
  end

  defp not_schema_does_not_match?(_args, nil), do: true

  defp not_schema_does_not_match?(args, schema) when is_map(schema) do
    not schema_condition_matches?(args, schema)
  end

  defp not_schema_does_not_match?(_args, _schema), do: true

  defp any_of_matches?(_args, nil), do: true

  defp any_of_matches?(args, alternatives) when is_list(alternatives),
    do: Enum.any?(alternatives, &schema_condition_matches?(args, &1))

  defp any_of_matches?(_args, _alternatives), do: false

  defp schema_arg(args, key) do
    case Map.fetch(args, key) do
      {:ok, value} ->
        value

      :error ->
        existing_atom_arg(args, key)
    end
  end

  defp existing_atom_arg(args, key) do
    atom = String.to_existing_atom(key)
    Map.get(args, atom)
  rescue
    ArgumentError -> nil
  end

  defp missing_param?(value, %{"type" => "string", "minLength" => 0}) when is_binary(value),
    do: false

  defp missing_param?(value, _property), do: missing_param?(value)

  defp missing_param?(value) when value in [nil, ""], do: true
  defp missing_param?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_param?(_value), do: false

  defp schema_type_matches?(_value, nil), do: true
  defp schema_type_matches?(value, "string"), do: is_binary(value)
  defp schema_type_matches?(value, "integer"), do: is_integer(value)
  defp schema_type_matches?(value, "number"), do: is_number(value)
  defp schema_type_matches?(value, "boolean"), do: is_boolean(value)
  defp schema_type_matches?(value, "array"), do: is_list(value)
  defp schema_type_matches?(value, "object"), do: is_map(value)
  defp schema_type_matches?(value, "null"), do: is_nil(value)
  defp schema_type_matches?(_value, _type), do: true

  defp example_params_for_schema(%{
         "properties" => props,
         "required" => required,
         "oneOf" => [first_alternative | _]
       })
       when is_map(props) and is_list(required) and is_map(first_alternative) do
    keys =
      (required ++ list_schema_value(first_alternative["required"]))
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    example_params(props, keys)
  end

  defp example_params_for_schema(%{"properties" => props, "required" => required})
       when is_map(props) and is_list(required) do
    required_keys = Enum.map(required, &to_string/1)

    optional_keys =
      props
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in required_keys))
      |> Enum.take(3)

    example_params(props, required_keys ++ optional_keys)
  end

  defp example_params_for_schema(%{"properties" => props}) when is_map(props) do
    props
    |> Enum.take(3)
    |> Enum.map(fn {key, prop} -> {to_string(key), example_value(prop, to_string(key))} end)
    |> Map.new()
  end

  defp example_params_for_schema(_schema), do: %{}

  defp example_params(props, keys) do
    keys
    |> Enum.map(fn key ->
      prop = Map.get(props, key, %{})
      {key, example_value(prop, key)}
    end)
    |> Map.new()
  end

  defp example_value(%{"default" => value}, _key), do: value
  defp example_value(%{"type" => "integer"}, _key), do: 1
  defp example_value(%{"type" => "number"}, _key), do: 1
  defp example_value(%{"type" => "boolean"}, _key), do: true
  defp example_value(%{"type" => "array"}, _key), do: []
  defp example_value(%{"type" => "object"}, _key), do: %{}
  defp example_value(_prop, key), do: "example " <> key

  # ---- Agent-visible file tools ----
  #
  # File paths route through SalixAgent.FileBackend. Normal paths are agent
  # workspace files; `/.runtime/compaction-recovery.md` is read-only runtime
  # context; `/.runtime/skills/...` is the session skill projection mount.

  @doc false
  def write_file(args, ctx) do
    path = required_arg(args, "path")
    content = arg(args, "content")

    # A full replacement: nothing of the old file survives, so the new content's
    # audience is the whole story (§8).
    case FileBackend.prepare_write(StorageAuthorization.replacing_content(ctx), path, content) do
      {:ok, event} ->
        {"wrote #{byte_size(content)} bytes to #{path}" <> rewrite_hint(content), journal(event)}

      {:error, :too_large} ->
        raise "file exceeds 10MB cap"

      {:error, reason} ->
        raise "write failed: #{inspect(reason)}"
    end
  end

  # Whole-file rewrites of files the model already read dominate Worker
  # output (staging 2026-09-14: 457 fs.write_file calls to 17 fs.edit_file),
  # and every one streams the entire file back out of the model. The tool
  # result is where the model is looking when it decides how to make the next
  # change, so the reminder goes there. It keys on the size of what was just
  # written — this round's own data — and says nothing about the old file:
  # its existence and size carry the old file's audience label, which a plain
  # write result does not (IFC.FileLabels).
  @rewrite_hint_bytes 4_096

  defp rewrite_hint(content) when byte_size(content) >= @rewrite_hint_bytes,
    do:
      " (a whole-file write of this size passes the entire file through the model; if this changed a file you had already read, use fs.edit_file for such changes)"

  defp rewrite_hint(_content), do: ""

  # A backend that applied its change when the tool ran (the Drive mount)
  # hands back no event; the journal records only what commit still applies.
  defp journal(nil), do: []
  defp journal(event), do: [event]

  @doc false
  def read_file(args, ctx) do
    path = required_arg(args, "path")
    labelled(read_file_content(args, ctx, path), [path], ctx)
  end

  defp read_file_content(args, ctx, path) do
    vision_query = arg(args, "vision_query") |> String.trim()

    cond do
      present_arg?(args, "offset") or present_arg?(args, "limit") ->
        raise "fs.read_file: use start_line/num_lines or tail_lines for paged text reads"

      true ->
        window = read_text_window_request(args)

        cond do
          window != nil and vision_query != "" ->
            raise "fs.read_file: start_line/num_lines/tail_lines cannot be used with vision_query"

          window != nil ->
            read_file_window(path, ctx, window)

          vision_query != "" and image_path?(path) ->
            read_file_vision(path, vision_query, ctx)

          true ->
            case read_any(ctx, path) do
              {:ok, body, truncated} -> format_read(path, body, ctx, truncated)
              {:error, :not_found} -> raise "no such file: #{path}"
              {:error, msg} when is_binary(msg) -> raise msg
              {:error, reason} -> raise "read failed: #{inspect(reason)}"
            end
        end
    end
  end

  # Body acquisition for read_file / read_file_vision. Returns
  # `{:ok, body, truncated}`; runtime and skill files share the same read
  # formatting as ordinary workspace files.
  defp read_any(ctx, path) do
    FileBackend.read(ctx, path)
  end

  defp read_file_window(path, ctx, window) do
    case read_any(ctx, path) do
      {:ok, body, truncated} -> format_read_window(path, body, window, truncated)
      {:error, :not_found} -> raise "no such file: #{path}"
      {:error, msg} when is_binary(msg) -> raise msg
      {:error, reason} -> raise "read failed: #{inspect(reason)}"
    end
  end

  defp put_optional_json(map, _key, nil), do: map
  defp put_optional_json(map, key, value), do: Map.put(map, key, value)

  defp format_read_window(path, body, window, source_truncated?) do
    if image_path?(path) do
      raise "fs.read_file: start_line/num_lines/tail_lines can only be used with text files"
    end

    case readable_text_body(path, body) do
      {:ok, view} -> format_text_window(path, view, window, source_truncated?)
      :binary -> unsupported_file!(path, body)
    end
  end

  defp format_text_window(
         path,
         %{body: body} = view,
         %{mode: :page, start_line: start_line, num_lines: num_lines},
         source_truncated?
       ) do
    lines = split_text_lines(body)
    total_lines = length(lines)
    page_lines = Enum.slice(lines, start_line - 1, num_lines)
    page_count = length(page_lines)

    end_line =
      if page_count == 0,
        do: min(start_line - 1, total_lines),
        else: start_line + page_count - 1

    next_start_line = if end_line < total_lines or source_truncated?, do: end_line + 1

    bounded = bound_text_content(Enum.join(page_lines, "\n"))

    %{
      "path" => path,
      "start_line" => start_line,
      "num_lines" => num_lines,
      "end_line" => end_line,
      "total_lines" => total_lines,
      "truncated" => not is_nil(next_start_line),
      "content_omitted" => bounded.content_omitted,
      "omitted_characters" => bounded.omitted_characters,
      "content" => bounded.content
    }
    |> put_text_view_sizes(view)
    |> put_optional_json("next_start_line", next_start_line)
    |> Jason.encode!()
  end

  defp format_text_window(
         path,
         %{body: body} = view,
         %{mode: :tail, tail_lines: tail_lines},
         source_truncated?
       ) do
    lines = split_text_lines(body)
    total_lines = length(lines)
    tail_count = min(tail_lines, total_lines)
    start_line = if tail_count == 0, do: total_lines + 1, else: total_lines - tail_count + 1
    page_lines = if tail_count == 0, do: [], else: Enum.take(lines, -tail_count)
    end_line = if tail_count == 0, do: total_lines, else: total_lines
    bounded = bound_text_content(Enum.join(page_lines, "\n"))

    %{
      "path" => path,
      "start_line" => start_line,
      "tail_lines" => tail_lines,
      "end_line" => end_line,
      "total_lines" => total_lines,
      "truncated" => tail_count < total_lines or source_truncated?,
      "content_omitted" => bounded.content_omitted,
      "omitted_characters" => bounded.omitted_characters,
      "content" => bounded.content
    }
    |> put_text_view_sizes(view)
    |> Jason.encode!()
  end

  defp split_text_lines(""), do: []

  defp split_text_lines(body) do
    lines = String.split(body, "\n", trim: false)

    if String.ends_with?(body, "\n") do
      Enum.drop(lines, -1)
    else
      lines
    end
  end

  defp read_text_window_request(args) do
    start_line_present? = present_arg?(args, "start_line")
    num_lines_present? = present_arg?(args, "num_lines")
    tail_lines_present? = present_arg?(args, "tail_lines")

    cond do
      tail_lines_present? and (start_line_present? or num_lines_present?) ->
        raise "fs.read_file: tail_lines cannot be used with start_line/num_lines"

      tail_lines_present? ->
        tail_lines = positive_integer_arg(args, "tail_lines", @read_page_default_lines)
        %{mode: :tail, tail_lines: min(tail_lines, @read_page_max_lines)}

      start_line_present? or num_lines_present? ->
        start_line = positive_integer_arg(args, "start_line", 1)
        num_lines = positive_integer_arg(args, "num_lines", @read_page_default_lines)

        %{
          mode: :page,
          start_line: start_line,
          num_lines: min(num_lines, @read_page_max_lines)
        }

      true ->
        nil
    end
  end

  # `read_file` returns model-consumable content only. Text is returned as
  # text; images are either passed through to multimodal models or described by
  # the auxiliary vision model; other binary formats require a dedicated reader.
  # Raw bytes must never reach the JSON-lines journal — Jason cannot encode
  # them and the commit would crash-loop.
  defp format_read(path, body, ctx, source_truncated?) do
    if image_path?(path) do
      if source_truncated?, do: raise("fs.read_file: image #{path} exceeds the 10MB read limit")
      format_image_read(path, body, ctx)
    else
      case readable_text_body(path, body) do
        {:ok, view} -> format_full_text_read(path, view, source_truncated?)
        :binary -> unsupported_file!(path, body)
      end
    end
  end

  defp format_full_text_read(path, %{body: body} = view, source_truncated?) do
    bounded = bound_text_content(body)

    if bounded.content_omitted or source_truncated? do
      %{
        "path" => path,
        "truncated" => source_truncated? or bounded.content_omitted,
        "source_truncated" => source_truncated?,
        "content_omitted" => bounded.content_omitted,
        "omitted_characters" => bounded.omitted_characters,
        "content" => bounded.content
      }
      |> put_text_view_sizes(view)
      |> Jason.encode!()
    else
      body
    end
  end

  defp put_text_view_sizes(map, view) do
    map = Map.put(map, "size_bytes", view.raw_size_bytes)

    if view.decoded? do
      Map.put(map, "decoded_size_bytes", byte_size(view.body))
    else
      map
    end
  end

  defp bound_text_content(content) do
    total_chars = String.length(content)

    if total_chars <= @read_text_output_max_chars do
      %{content: content, content_omitted: false, omitted_characters: 0}
    else
      split_omitted_text(content, total_chars)
    end
  end

  defp split_omitted_text(content, total_chars) do
    {head_chars, tail_chars, omitted_chars, marker} =
      omitted_split(total_chars, omission_marker(total_chars))

    %{
      content:
        String.slice(content, 0, head_chars) <>
          marker <>
          String.slice(content, total_chars - tail_chars, tail_chars),
      content_omitted: true,
      omitted_characters: omitted_chars
    }
  end

  defp omitted_split(total_chars, marker) do
    available = max(@read_text_output_max_chars - String.length(marker), 2)
    head_chars = div(available, 2)
    tail_chars = available - head_chars
    omitted_chars = total_chars - head_chars - tail_chars
    next_marker = omission_marker(omitted_chars)

    if String.length(next_marker) == String.length(marker) do
      {head_chars, tail_chars, omitted_chars, next_marker}
    else
      omitted_split(total_chars, next_marker)
    end
  end

  defp omission_marker(omitted_chars) do
    "\n[fs.read_file omitted #{omitted_chars} characters from the middle; content is not complete]\n"
  end

  # willow's isBinaryContent (NUL in the first 512 bytes), strengthened with a
  # UTF-8 validity check: Go's JSON encoder tolerates invalid UTF-8, Jason raises.
  defp binary_content?(body) do
    String.contains?(binary_part(body, 0, min(byte_size(body), 512)), <<0>>) or
      not String.valid?(body)
  end

  defp readable_text_body(path, body) do
    case readable_text_body(path, body, @record_stream_max_frames) do
      {:ok, view, _frames_used} -> {:ok, view}
      {:binary, _frames_used} -> :binary
      {:work_limit, _frames_used} -> :binary
    end
  end

  defp readable_text_body(path, body, frame_limit) do
    if binary_content?(body) do
      case decode_record_stream_text(path, body, frame_limit) do
        {:ok, decoded, frames_used} ->
          {:ok,
           %{
             body: decoded,
             raw_size_bytes: byte_size(body),
             decoded?: true
           }, frames_used}

        {:binary, frames_used} ->
          {:binary, frames_used}

        {:work_limit, frames_used} ->
          {:work_limit, frames_used}
      end
    else
      {:ok, %{body: body, raw_size_bytes: byte_size(body), decoded?: false}, 0}
    end
  end

  # Docker/Moby stdcopy multiplexes stdout/stderr with an 8-byte header:
  # stream id, three reserved NULs, and a big-endian uint32 payload size. One
  # observed Feishu attachment passed through a lossy text export that replaced
  # size bytes above 127 with U+FFFD. Preserve exact VFS bytes and unwrap only
  # for model-facing reads. Canonical frames validate their full declared size;
  # the lossy fallback can only bound each unknown original size by the segment
  # before the next header-shaped marker.
  defp decode_record_stream_text(path, body, frame_limit) do
    extension = path |> Path.extname() |> String.downcase()

    if extension in @record_stream_text_extensions do
      case validated_record_stream(decode_stdcopy_frames(body, [], 0, frame_limit)) do
        {:binary, canonical_frames} ->
          remaining_frames = frame_limit - canonical_frames

          if remaining_frames <= 0 do
            {:work_limit, canonical_frames}
          else
            body
            |> decode_lossy_stdcopy_frames([], 0, remaining_frames)
            |> validated_record_stream()
            |> add_record_stream_work(canonical_frames)
          end

        result ->
          result
      end
    else
      {:binary, 0}
    end
  end

  defp validated_record_stream({:ok, decoded, frames_used}) do
    if String.valid?(decoded) and not String.contains?(decoded, <<0>>) do
      {:ok, decoded, frames_used}
    else
      {:binary, frames_used}
    end
  end

  defp validated_record_stream({:error, frames_used}), do: {:binary, frames_used}
  defp validated_record_stream({:work_limit, frames_used}), do: {:work_limit, frames_used}

  defp add_record_stream_work({:ok, decoded, frames_used}, prior_frames),
    do: {:ok, decoded, prior_frames + frames_used}

  defp add_record_stream_work({:binary, frames_used}, prior_frames),
    do: {:binary, prior_frames + frames_used}

  defp add_record_stream_work({:work_limit, frames_used}, prior_frames),
    do: {:work_limit, prior_frames + frames_used}

  defp decode_stdcopy_frames("", acc, frame_count, _frame_limit) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), frame_count}
  end

  defp decode_stdcopy_frames(_body, _acc, frame_count, frame_limit)
       when frame_count >= frame_limit,
       do: {:work_limit, frame_count}

  defp decode_stdcopy_frames(
         <<stream, 0, 0, 0, payload_size::unsigned-big-32, rest::binary>>,
         acc,
         frame_count,
         frame_limit
       )
       when stream in [1, 2] and byte_size(rest) >= payload_size do
    <<payload::binary-size(^payload_size), remaining::binary>> = rest
    decode_stdcopy_frames(remaining, [payload | acc], frame_count + 1, frame_limit)
  end

  defp decode_stdcopy_frames(_body, _acc, frame_count, _frame_limit),
    do: {:error, frame_count}

  defp decode_lossy_stdcopy_frames("", acc, frame_count, _frame_limit) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), frame_count}
  end

  defp decode_lossy_stdcopy_frames(_body, _acc, frame_count, frame_limit)
       when frame_count >= frame_limit,
       do: {:work_limit, frame_count}

  defp decode_lossy_stdcopy_frames(
         <<stream, 0, 0, 0, 0, 0, 0, rest::binary>>,
         acc,
         frame_count,
         frame_limit
       )
       when stream in [1, 2] do
    {frame, remaining} = split_lossy_stdcopy_frame(rest)

    case decode_lossy_stdcopy_frame(frame) do
      {:ok, payload} ->
        decode_lossy_stdcopy_frames(remaining, [payload | acc], frame_count + 1, frame_limit)

      :error ->
        {:error, frame_count}
    end
  end

  defp decode_lossy_stdcopy_frames(_body, _acc, frame_count, _frame_limit),
    do: {:error, frame_count}

  defp split_lossy_stdcopy_frame(rest) do
    case :binary.match(rest, @record_stream_prefixes) do
      {position, _length} ->
        {binary_part(rest, 0, position), binary_part(rest, position, byte_size(rest) - position)}

      :nomatch ->
        {rest, ""}
    end
  end

  defp decode_lossy_stdcopy_frame(<<0xEF, 0xBF, 0xBD, payload::binary>>)
       when byte_size(payload) in 128..255 do
    {:ok, payload}
  end

  defp decode_lossy_stdcopy_frame(<<length, payload::binary>>)
       when byte_size(payload) == length do
    {:ok, payload}
  end

  defp decode_lossy_stdcopy_frame(_frame), do: :error

  defp format_image_read(path, body, ctx) do
    case image_read_mode(ctx) do
      :multimodal ->
        image_block(path, body)

      {:vision, cfg} ->
        describe_image(path, body, cfg)

      :unsupported ->
        raise "fs.read_file: image #{path} requires an image-capable model or configured vision_describer_config"
    end
  end

  defp image_read_mode(ctx) do
    with {:ok, media} when is_map(media) <- SalixAgent.MediaResolver.resolve(ctx.agent_id) do
      cond do
        SalixAgent.MediaResolver.supports_images?(media, ctx) ->
          :multimodal

        vision_configured?(media["vision_describer_config"]) ->
          {:vision, media["vision_describer_config"]}

        true ->
          :unsupported
      end
    else
      _ -> :unsupported
    end
  end

  defp image_block(path, body) do
    Jason.encode!([
      %{
        "type" => "image",
        "file_ref" => %{"environment_id" => "vfs", "path" => path},
        "file_name" => Path.basename(path),
        "mime_type" => image_mime(path),
        "size_bytes" => byte_size(body)
      },
      %{"type" => "text", "text" => "[Image: #{path}, #{byte_size(body)} bytes]"}
    ])
  end

  defp describe_image(path, body, cfg, opts \\ []) do
    with {:ok, preview, mime} <- SalixMedia.ImageInput.prepare(body, image_mime(path)),
         {:ok, %{description: answer}} <-
           SalixMedia.Vision.describe(
             "data:#{mime};base64," <> Base.encode64(preview),
             Keyword.put(opts, :config, cfg)
           ) do
      Jason.encode!(%{
        "path" => path,
        "mime_type" => image_mime(path),
        "size_bytes" => byte_size(body),
        "answer" => answer
      })
    else
      {:error, reason} ->
        raise "vision describe failed: #{inspect(reason)}"

      other ->
        raise "vision describe failed: #{inspect(other)}"
    end
  end

  defp unsupported_file!(path, body) do
    kind =
      case String.downcase(Path.extname(path)) do
        ".pdf" -> "pdf"
        "" -> "binary"
        ext -> String.trim_leading(ext, ".")
      end

    raise "fs.read_file: unsupported #{kind} file #{path} (#{byte_size(body)} bytes); add a dedicated reader for this format"
  end

  defp read_file_vision(path, query, ctx) do
    with {:ok, media} <- SalixAgent.MediaResolver.resolve(ctx.agent_id),
         cfg <- (media || %{})["vision_describer_config"],
         true <- vision_configured?(cfg) or SalixAgent.MediaResolver.supports_images?(media, ctx),
         {:ok, body, false} <- read_any(ctx, path) do
      if vision_configured?(cfg),
        do: describe_image(path, body, cfg, question: query),
        else: image_block(path, body)
    else
      false ->
        raise "vision_query requires an image-capable model or configured vision_describer_config"

      {:ok, _body, true} ->
        raise "vision_query: #{path} exceeds the 10MB read limit"

      {:error, :not_found} ->
        raise "no such file: #{path}"

      {:error, msg} when is_binary(msg) ->
        raise msg

      {:error, reason} ->
        raise "vision describe failed: #{inspect(reason)}"

      other ->
        raise "vision describe failed: #{inspect(other)}"
    end
  end

  defp vision_configured?(%{"endpoint" => e, "model" => m}),
    do: String.trim(to_string(e)) != "" and String.trim(to_string(m)) != ""

  defp vision_configured?(_), do: false

  defp image_path?(path) do
    String.downcase(Path.extname(path)) in [".jpg", ".jpeg", ".png", ".gif", ".webp"]
  end

  defp image_mime(path) do
    case String.downcase(Path.extname(path)) do
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  @doc false
  def list_files(args, ctx) do
    prefix = arg(args, "prefix")
    paths = FileBackend.list(ctx, prefix)
    labelled(Enum.join(paths, "\n"), paths, ctx)
  end

  @doc false
  def delete_file(args, ctx) do
    path = required_arg(args, "path")

    case FileBackend.prepare_delete(ctx, path) do
      {:ok, event} -> {"deleted #{path}", journal(event)}
      {:error, reason} -> raise "delete failed: #{inspect(reason)}"
    end
  end

  @doc false
  # Runs through `SalixAgent.ScriptRun`: the program is compiled by the
  # spinfoam child and executed once as a script object, preserving
  # completed host effects when the program fails. Its `salix.call` host
  # calls come back through SalixAgent.Tools so scripts and LLM tool
  # execution share disclosure, authorization, caps, and result semantics.
  # Returns `{content, events}` when host calls accumulated journal events.
  def script_run(args, ctx) do
    source = required_arg(args, "source")
    extra = raw_arg(args, "files") || %{}
    unless is_map(extra), do: raise("'files' must be an object of file name to content")

    files =
      extra
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> Map.put("main.c", source)

    case SalixAgent.Spinfoam.Build.validate_sources(files, "main.c") do
      :ok -> SalixAgent.ScriptRun.run(files, "main.c", %{}, ctx)
      {:error, message} -> raise "script.run: " <> message
    end
  end

  @doc false
  def edit_file(args, ctx) do
    path = required_arg(args, "path")
    old = required_arg(args, "old")
    new = arg(args, "new")

    case FileBackend.read(ctx, path) do
      {:ok, body, _truncated} ->
        case readable_text_body(path, body) do
          {:ok, %{decoded?: true}} ->
            raise "edit: decoded framed text view is read-only: #{path}"

          _ ->
            :ok
        end

        unless String.contains?(body, old), do: raise("edit: old text not found in #{path}")
        updated = String.replace(body, old, new, global: false)

        case FileBackend.prepare_write(ctx, path, updated) do
          {:ok, event} -> {"edited #{path}", journal(event)}
          {:error, reason} -> raise "edit failed: #{inspect(reason)}"
        end

      {:error, :not_found} ->
        raise "no such file: #{path}"

      {:error, reason} ->
        raise "read failed: #{inspect(reason)}"
    end
  end

  @doc false
  def copy_file(args, ctx) do
    from = required_arg(args, "from")
    to = required_arg(args, "to")

    case FileBackend.prepare_copy(ctx, from, to) do
      {:ok, events, _size} -> {"copied #{from} → #{to}", events}
      {:error, :not_found} -> raise "copy: no such file: #{from}"
      {:error, reason} -> raise "copy failed: #{inspect(reason)}"
    end
  end

  @doc false
  def move_file(args, ctx) do
    from = required_arg(args, "from")
    to = required_arg(args, "to")

    case FileBackend.prepare_move(ctx, from, to) do
      {:ok, events, _size} -> {"moved #{from} → #{to}", events}
      {:error, :not_found} -> raise "move: no such file: #{from}"
      {:error, reason} -> raise "move failed: #{inspect(reason)}"
    end
  end

  @doc false
  def grep(args, ctx) do
    {:ok, re} = Regex.compile(required_arg(args, "pattern"))
    prefix = arg(args, "prefix")
    paths = FileBackend.list(ctx, prefix)

    if length(paths) > @grep_max_files do
      raise "fs.grep: file budget exceeded (maximum #{@grep_max_files} files per request)"
    end

    initial = %{
      input_bytes_remaining: @grep_max_input_bytes,
      frames_remaining: @grep_max_frames,
      matches_rev: [],
      match_count: 0,
      output_bytes: 0,
      truncated?: false
    }

    case Enum.reduce_while(paths, {:ok, initial}, fn path, {:ok, state} ->
           grep_path(path, re, ctx, state)
         end) do
      {:ok, state} ->
        # Every file that was scanned, not only the ones that matched: an
        # absence of matches in a private file is still something learned from
        # it.
        labelled(format_grep_result(state), paths, ctx)

      {:error, reason} ->
        raise "fs.grep: #{reason}"
    end
  end

  defp grep_path(path, re, ctx, state) do
    case read_any(ctx, path) do
      # Truncated sources and unreadable files remain skipped. Complete bodies
      # count against one request-wide byte/frame budget before regex scanning.
      {:ok, body, false} ->
        body_size = byte_size(body)

        if body_size > state.input_bytes_remaining do
          {:halt,
           {:error,
            "input byte budget exceeded (maximum #{@grep_max_input_bytes} bytes per request)"}}
        else
          state = %{state | input_bytes_remaining: state.input_bytes_remaining - body_size}

          case readable_text_body(path, body, state.frames_remaining) do
            {:ok, view, frames_used} ->
              state = %{state | frames_remaining: state.frames_remaining - frames_used}

              case grep_text_lines(path, view.body, re, state, 1) do
                {:ok, next_state} -> {:cont, {:ok, next_state}}
                {:halt, next_state} -> {:halt, {:ok, next_state}}
              end

            {:binary, frames_used} ->
              {:cont, {:ok, %{state | frames_remaining: state.frames_remaining - frames_used}}}

            {:work_limit, _frames_used} ->
              {:halt,
               {:error,
                "frame work budget exceeded (maximum #{@grep_max_frames} frames per request)"}}
          end
        end

      _ ->
        {:cont, {:ok, state}}
    end
  end

  defp grep_text_lines(path, body, re, state, line_number) do
    case :binary.match(body, "\n") do
      {position, 1} ->
        line = binary_part(body, 0, position)
        remaining = binary_part(body, position + 1, byte_size(body) - position - 1)

        case grep_line(path, line, line_number, re, state) do
          {:ok, next_state} ->
            grep_text_lines(path, remaining, re, next_state, line_number + 1)

          {:halt, next_state} ->
            {:halt, next_state}
        end

      :nomatch ->
        grep_line(path, body, line_number, re, state)
    end
  end

  defp grep_line(path, line, line_number, re, state) do
    if Regex.match?(re, line) do
      add_grep_match(path, line, line_number, state)
    else
      {:ok, state}
    end
  end

  defp add_grep_match(_path, _line, _line_number, state)
       when state.match_count >= @grep_max_matches,
       do: {:halt, %{state | truncated?: true}}

  defp add_grep_match(path, line, line_number, state) do
    line_number_text = Integer.to_string(line_number)
    separator_bytes = if state.match_count == 0, do: 0, else: 1
    match_bytes = byte_size(path) + byte_size(line_number_text) + byte_size(line) + 2
    marker_bytes = byte_size(@grep_truncated_marker) + 1

    if state.output_bytes + separator_bytes + match_bytes + marker_bytes >
         @grep_max_output_bytes do
      {:halt, %{state | truncated?: true}}
    else
      match = path <> ":" <> line_number_text <> ":" <> line

      {:ok,
       %{
         state
         | matches_rev: [match | state.matches_rev],
           match_count: state.match_count + 1,
           output_bytes: state.output_bytes + separator_bytes + match_bytes
       }}
    end
  end

  defp format_grep_result(state) do
    matches = state.matches_rev |> Enum.reverse() |> Enum.join("\n")

    if state.truncated? do
      if matches == "",
        do: @grep_truncated_marker,
        else: matches <> "\n" <> @grep_truncated_marker
    else
      matches
    end
  end

  @doc false
  def glob(args, ctx) do
    pattern = required_arg(args, "pattern")
    re = glob_to_regex(pattern)

    matched = Enum.filter(FileBackend.list(ctx, ""), &Regex.match?(re, &1))
    labelled(Enum.join(matched, "\n"), matched, ctx)
  end

  @doc false
  def stat_file(args, ctx) do
    path = required_arg(args, "path")

    case FileBackend.stat(ctx, path) do
      {:ok, meta} -> labelled(Jason.encode!(meta), [path], ctx)
      {:error, :not_found} -> raise "no such file: #{path}"
      {:error, msg} when is_binary(msg) -> raise msg
      {:error, reason} -> raise "stat failed: #{inspect(reason)}"
    end
  end

  @doc false
  def web_search(args, _ctx) do
    query = arg(args, "query")
    if query == "", do: raise("web.search: missing query")

    api_key =
      Application.get_env(:salix_agent, :exa_api_key) ||
        raise "web.search: no Exa API key configured (:salix_agent, :exa_api_key)"

    body = %{query: query, numResults: 5, contents: %{text: %{maxCharacters: 1500}}}

    case Req.post("https://api.exa.ai/search",
           json: body,
           headers: [{"x-api-key", api_key}],
           receive_timeout: 30_000,
           retry: :transient
         ) do
      {:ok, %{status: 200, body: %{"results" => results}}} ->
        results
        |> Enum.map(fn r ->
          text = r["text"] || ""
          "### #{r["title"]}\n#{r["url"]}\n#{String.slice(text, 0, 1200)}"
        end)
        |> Enum.join("\n\n")

      {:ok, %{status: status}} ->
        raise "web.search: Exa returned #{status}"

      {:error, reason} ->
        raise "web.search: transport error #{inspect(reason)}"
    end
  end

  # Minimal glob → regex (`*` = any non-slash run, `**` = anything, `?` = one char).
  defp glob_to_regex(pattern) do
    escaped =
      pattern
      |> String.replace("**", "\0DS\0")
      |> String.replace("*", "\0S\0")
      |> String.replace("?", "\0Q\0")
      |> Regex.escape()
      |> String.replace("\0DS\0", ".*")
      |> String.replace("\0S\0", "[^/]*")
      |> String.replace("\0Q\0", ".")

    Regex.compile!("^" <> escaped <> "$")
  end

  defp arg(args, key), do: to_string(raw_arg(args, key) || "")

  defp raw_arg(args, key), do: args[key] || args[String.to_atom(key)]

  defp present_arg?(args, key) do
    case raw_arg(args, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp positive_integer_arg(args, key, default) do
    case integer_arg(args, key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> raise "fs.read_file: #{key} must be a positive integer"
    end
  end

  defp integer_arg(args, key, default) do
    case raw_arg(args, key) do
      nil -> default
      "" -> default
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer_arg(value)
      value -> value |> to_string() |> parse_integer_arg()
    end
  end

  defp parse_integer_arg(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> :invalid
    end
  end

  # Server-side mirror of the schema's `required` list (SalixAgent.Tools.Schemas):
  # an argument the schema marks required raises here when missing or blank, so
  # the contract the LLM sees and the one the dispatcher enforces stay aligned.
  defp required_arg(args, key) do
    case arg(args, key) do
      "" -> raise "'#{key}' is required"
      value -> value
    end
  end
end
