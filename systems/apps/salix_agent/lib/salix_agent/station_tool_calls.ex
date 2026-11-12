defmodule SalixAgent.StationToolCalls do
  @moduledoc """
  Salix registry tools called back from a Task's own station (`task.tools`,
  `task.tool_call`, `SalixWeb.StationTasks`): the agent in a Task's sandbox
  reaches Salix through the station's connection, as the Task's Worker.

  There is no grant of its own. A call is executed as the Task's Worker Agent
  through `SalixAgent.SessionToolDispatch`, the authorization boundary an
  internal round and a Loop use, with the Worker's own tool disclosure: the
  station calls what the Worker could call in Salix, as a Worker running on
  the Group's Cloud VM or a Station does, and nothing more: `env.*` (with
  `credential_env`), `preview.*` and the rest. `im_api.internal.task.create` makes one
  sandbox Task, with this Task as its parent and the Group's Router taking
  its result; a Task a Worker created creates none
  (`SalixIM.Provider.Internal`).

  The call carries a sealed origin (`SalixAgent.IFC.station_origin/3`): the
  kernel's delegated-principal wrapper around the Task's requester (the
  person whose Task it is), keyed `station:` and the device, with the Task
  conversation's label, so a decision and its archive row say which station
  acted for whom. Under audit or enforce the activation wire is built from
  that origin alone, with no Session items, since the Worker of a station
  Task has no Session here; a Task with no requester is refused before any
  dispatch (`no_requester`), the fail-closed reading.

  Returning a result to the sandbox is itself an egress: the Group's one Task
  Worker holds every Task's files, and a read never filters inside Salix. So
  a labelled result is for the sandbox only when the Task's requester is a
  reader of its label, by the kernel's reading of the Group's facts
  (`SalixIFC.reader?/3`); a result for someone else, an agent-private one (a
  read that labelled nothing) or one whose readers are unknown is not
  (`label_not_this_task`), nor is one the dispatcher did not label at all
  (`label_unknown`), a tool's own failure text excepted. The verdict is
  archived as an IFC decision, and the Group's mode decides as it does for a
  round: under enforce the refusal stands and the prepared writes are
  dropped; under audit it is recorded and the result goes back all the same.

  Bounds: at most #{4} calls in flight per station, arguments at most 1 MiB,
  a result at most 1 MiB (cut, and said so). The connection answers a call
  within the tool's own timeout (`deadline_ms/2`, at most 19 minutes), so a
  long `env.exec` returns its output; one it did not answer is reported to
  the station as timed out, and may still have taken effect. Every call is
  archived as the Worker's tool call (`SalixAgent.Tools`) and logged with its
  Task, session, tool, duration and result size. A write to the Worker's
  files (`fs.*`) is committed to its workspace as a round would commit it
  (`SalixAgent.WorkspaceEvents`); a Drive write (`/drive/...`) takes effect as
  the tool runs.
  """

  require Logger

  alias SalixAgent.{IFC, SessionToolDispatch, ToolDisclosure, Tools}

  @registry SalixAgent.StationToolCalls.Registry
  @max_in_flight 4
  @max_args_bytes 1024 * 1024
  @max_result_bytes 1024 * 1024
  # The station waits 20 minutes for a call (`SALIX_TOOL_CALL_TIMEOUT`); the
  # connection answers before that.
  @answer_slop_ms 5_000
  @max_call_ms 19 * 60_000

  @task_create "im_api.internal.task.create"

  @type ref :: %{
          required(:tenant_id) => String.t(),
          required(:group_id) => String.t(),
          required(:agent_id) => String.t(),
          required(:conversation_id) => String.t(),
          required(:device_id) => String.t(),
          required(:session) => String.t(),
          # The person whose Task it is: its Comma owner (`owner_user_id`),
          # else the provider user who asked for it (`ifc_requester`, an
          # encoded principal); and the Task conversation's IFC label.
          optional(:requester) => String.t() | nil,
          optional(:principal) => String.t() | nil,
          optional(:label) => [String.t()] | nil
        }

  @doc "The Registry that counts a station's calls in flight (a child of `SalixAgent.Application`)."
  def registry, do: @registry

  @doc "How many calls one station may have in flight."
  def max_in_flight, do: @max_in_flight

  @doc """
  How long the station's connection gives a call of `tool` with `args`: the
  tool's own timeout (`SalixAgent.Tools.tool_timeout_ms/2`, an `env.exec`'s
  `timeout` included) and a margin, at most 19 minutes.
  """
  @spec deadline_ms(term(), term()) :: pos_integer()
  def deadline_ms(tool, args) when is_binary(tool) do
    args = if is_map(args), do: args, else: %{}
    min(Tools.tool_timeout_ms(tool, args) + @answer_slop_ms, @max_call_ms)
  end

  def deadline_ms(_tool, _args), do: @answer_slop_ms + 30_000

  @doc """
  The tools the station's agent may call: the Worker's callable disclosure,
  each with its name, description and input schema.
  """
  @spec tools(ref()) :: [map()]
  def tools(ref) do
    ctx = tool_ctx(ref)

    (get_in(ctx, [:tool_disclosure, "tools"]) || [])
    |> Enum.filter(&(&1["callable"] == true))
    |> Enum.map(fn entry ->
      name = entry["name"]

      %{
        "name" => name,
        "description" => description(entry),
        "input_schema" => ToolDisclosure.entry_schema(entry) || %{}
      }
    end)
  end

  defp description(%{"name" => name} = entry) do
    case Tools.find_entry(name) do
      nil -> to_string(entry["summary"] || "")
      found -> Tools.entry_description(found)
    end
  end

  @doc """
  Calls `tool` with `args` as the Task's Worker. `{:ok, result}` with the tool's
  answer (`tool`, `error`, `content`, and `truncated` when cut), or
  `{:refused, error, message}` when the call is not made at all.
  """
  @spec call(ref(), String.t(), map()) :: {:ok, map()} | {:refused, String.t(), String.t()}
  def call(ref, tool, args) when is_binary(tool) and is_map(args) do
    started = SystemsClock.monotonic_time()

    result =
      with :ok <- check_args(args),
           :ok <- check_requester(ref),
           {:ok, slot} <- take_slot(ref.device_id) do
        execute(ref, tool, args, slot)
      end

    duration = SystemsClock.monotonic_time() - started

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "station_tool_call",
      "station",
      outcome(result),
      duration
    )

    Logger.info("station tool call",
      station_tool_call: tool,
      task: ref.conversation_id,
      session: ref.session,
      device_id: ref.device_id,
      outcome: outcome(result),
      duration_ms: System.convert_time_unit(duration, :native, :millisecond),
      result_bytes: result_bytes(result)
    )

    result
  end

  defp check_args(args) do
    if byte_size(Jason.encode!(args)) <= @max_args_bytes,
      do: :ok,
      else:
        {:refused, "args_too_large",
         "arguments are at most 1 MiB; give larger content as a file of a post"}
  end

  # Under audit or enforce the call needs the Task's requester to act for;
  # a Task with none is refused here rather than at every effect.
  defp check_requester(ref) do
    if IFC.mode_for(ref.tenant_id, ref.group_id) == :off or not is_nil(origin(ref)),
      do: :ok,
      else: {:refused, "no_requester", "this Task has no requester to act for"}
  end

  # The calling process holds a duplicate-key registration (its own slot, a
  # ref) while the call runs; one killed on timeout releases its slot with its
  # process. It registers first and counts after, so two calls admitted at
  # once cannot both pass a count taken before either registered.
  defp take_slot(device_id) do
    slot = SystemsRuntime.Proc.make_ref()

    with {:ok, _} <- SystemsRuntime.Registry.register(@registry, device_id, slot),
         true <- length(SystemsRuntime.Registry.lookup(@registry, device_id)) <= @max_in_flight do
      {:ok, slot}
    else
      _over_or_failed ->
        release_slot(device_id, slot)

        {:refused, "too_many_calls",
         "this station has #{@max_in_flight} calls in flight; wait for one to answer"}
    end
  end

  defp release_slot(device_id, slot),
    do: SystemsRuntime.Registry.unregister_match(@registry, device_id, slot)

  defp execute(ref, tool, args, slot) do
    call = %{
      id:
        "station:" <>
          ref.device_id <>
          ":" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
      name: tool,
      args: args
    }

    with [result] <- SessionToolDispatch.execute([call], tool_ctx(ref, call)),
         :ok <- readable(ref, result, call),
         {:ok, result} <- commit(ref, result) do
      content = to_string(result[:content] || result["content"] || "")
      error? = result[:error] == true or result["error"] == true
      {content, truncated?} = bounded(content)

      {:ok,
       %{"tool" => tool, "error" => error?, "content" => content}
       |> then(&if(truncated?, do: Map.put(&1, "truncated", true), else: &1))}
    else
      {:refused, _error, _message} = refused ->
        refused

      {:error, reason} ->
        {:ok,
         %{
           "tool" => tool,
           "error" => true,
           "content" => "the result was not kept: #{inspect(reason) |> String.slice(0, 256)}"
         }}

      other ->
        {:ok,
         %{
           "tool" => tool,
           "error" => true,
           "content" => "tool dispatch returned #{inspect(other) |> String.slice(0, 256)}"
         }}
    end
  rescue
    exception ->
      {:ok,
       %{
         "tool" => tool,
         "error" => true,
         "content" => "tool raised: " <> Exception.message(exception)
       }}
  catch
    kind, value ->
      {:ok,
       %{
         "tool" => tool,
         "error" => true,
         "content" => "tool #{kind}: #{inspect(value) |> String.slice(0, 256)}"
       }}
  after
    release_slot(ref.device_id, slot)
  end

  # Returning a result to the sandbox is an egress: the content leaves Salix
  # for a machine with the internet, where the Task's requester reads it. A
  # read never filters inside Salix (§7), so the gate is here: a labelled
  # result goes back only when the requester is a reader of its label, by the
  # kernel's own reading of the Group's facts (`SalixIFC.reader?/3`); anything
  # else, agent-private (an unlabelled read) and unknown included, is a
  # refusal. The verdict is archived as an IFC decision like a round's
  # (`SalixAgent.IFC.Check`), and then the mode decides, as it does there:
  # under enforce the refusal stands and the prepared writes are dropped;
  # under audit it is recorded and the result goes back all the same, since
  # audit changes no outcome. A Group with the check off labels nothing and
  # is not affected.
  defp readable(ref, result, call) do
    case IFC.mode_for(ref.tenant_id, ref.group_id) do
      :off ->
        :ok

      mode ->
        verdict = reader_verdict(ref, result, call)
        archive_verdict(ref, call, mode, verdict)

        case {mode, verdict} do
          {_mode, :ok} ->
            :ok

          {:audit, _refused} ->
            :ok

          {:enforce, refused} ->
            discard(result)
            refused
        end
    end
  end

  # The answer to a Task creation names the Task this call made for this
  # Task's requester (its parent's owner), and no record's content: it is the
  # sandbox's to read, whatever label the dispatcher gave the call.
  defp reader_verdict(_ref, _result, %{name: @task_create}), do: :ok
  defp reader_verdict(ref, result, _call), do: reader_verdict(ref, result)

  defp reader_verdict(ref, result) do
    case Map.get(result, :ifc) || Map.get(result, "ifc") do
      %{"label" => encoded} when is_list(encoded) ->
        label = SalixIFC.Codec.decode_label(encoded, SalixIFC.Label.new([:agent_private]))

        if SalixIFC.Label.public?(label) or reader?(ref, label, encoded),
          do: :ok,
          else:
            {:refused, "label_not_this_task",
             "this content is not for this Task's requester to read; it stays in Salix"}

      _unlabelled ->
        # A result the dispatcher did not label (a refusal before dispatch)
        # carries no data, but no audience either: only a tool's own failure
        # text goes back, since it is the tool's, not a record's.
        if result[:error] == true or result["error"] == true,
          do: :ok,
          else:
            {:refused, "label_unknown",
             "this result carries no audience label; it stays in Salix"}
    end
  end

  defp archive_verdict(ref, call, mode, verdict) do
    SalixAgent.EventArchive.Emit.ifc_decision(
      %{
        agent_id: ref.agent_id,
        tenant_id: ref.tenant_id,
        group_id: ref.group_id,
        session_id: "station:" <> ref.device_id <> ":" <> ref.session
      },
      %{
        "tool" => call.name,
        "tool_call_id" => call.id,
        "mode" => Atom.to_string(mode),
        "effect" => "station_result",
        "outcome" =>
          case verdict do
            :ok -> "allow"
            {:refused, error, _message} -> error
          end
      }
    )
  end

  defp reader?(ref, label, encoded) do
    case person(ref) do
      nil ->
        false

      person ->
        request = %{
          "tenant_id" => ref.tenant_id,
          "group_id" => ref.group_id,
          "agent_id" => ref.agent_id,
          "requester" => SalixIFC.Codec.encode_principal!(person),
          "destination" => %{"kind" => "agent_private"},
          "atoms" => encoded,
          "trusted_origin" => origin(ref),
          "now" => SystemsClock.system_time(:millisecond)
        }

        case IFC.resolve(request) do
          {:ok, reply} ->
            SalixIFC.reader?(person, label, SalixIFC.Codec.decode_facts(reply)) == true

          {:error, _} ->
            false
        end
    end
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp discard(result) do
    (result[:events] || result["events"] || [])
    |> Enum.each(&SalixAgent.AgentWorkspace.discard_prepared_write/1)
  end

  # A tool's workspace events (`vfs_write`...) are committed to the Worker's
  # workspace as a round commits them (`SalixAgent.WorkspaceEvents`), behind an
  # operation id of this station session's; session events are dropped, since
  # the Worker of a station Task has no Session here.
  defp commit(ref, result) do
    SalixAgent.WorkspaceEvents.commit_result(
      ref.agent_id,
      "station:" <> ref.device_id <> ":" <> ref.session,
      result,
      "station-tool-call"
    )
  end

  # The cut lands on a character boundary: a byte cut inside a multi-byte
  # character makes the reply unencodable.
  defp bounded(content) when byte_size(content) <= @max_result_bytes, do: {content, false}

  defp bounded(content) do
    cut = binary_part(content, 0, @max_result_bytes)
    {trim_partial_char(cut), true}
  end

  defp trim_partial_char(binary) do
    if String.valid?(binary),
      do: binary,
      else: trim_partial_char(binary_part(binary, 0, byte_size(binary) - 1))
  end

  # The Worker's context, as its own round builds it (`SalixAgent.RoundConfig`):
  # its tool disclosure, plugin projection and skills, the sealed station
  # origin, and under audit or enforce the activation wire from that origin.
  defp origin(ref), do: IFC.station_origin(ref.device_id, person(ref), ref[:label])

  @doc "The sealed origin a call from `ref` carries: who it acts for."
  def origin_of(ref), do: origin(ref)

  # The person the Task belongs to: its Comma owner, else the person who asked
  # for it in a provider chat (`principal`, encoded).
  defp person(ref) do
    cond do
      is_binary(ref[:requester]) and ref[:requester] != "" ->
        {:comma_user, ref[:requester]}

      is_binary(ref[:principal]) ->
        case SalixIFC.Codec.decode_principal(ref[:principal]) do
          {:ok, {:provider_user, _connect, _user} = person} -> person
          {:ok, {:comma_user, _user} = person} -> person
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp tool_ctx(ref, call \\ nil) do
    origin = origin(ref)
    role = agent_role(ref.agent_id)
    ifc_mode = IFC.mode_for(ref.tenant_id, ref.group_id)

    station = %{
      station_device_id: ref.device_id,
      task_conversation_id: ref.conversation_id
    }

    %{
      agent_id: ref.agent_id,
      tenant_id: ref.tenant_id,
      group_id: ref.group_id,
      role: role,
      runtime_kind: :internal,
      round_id: "station:" <> ref.device_id <> ":" <> ref.session,
      ifc_mode: ifc_mode,
      defer_tool_observations: true
    }
    |> Map.merge(station)
    |> Map.merge(worker_config(ref, role, station))
    |> then(fn ctx ->
      if origin,
        do: Map.merge(ctx, %{trusted_origin: origin, trusted_origins: [origin]}),
        else: ctx
    end)
    |> then(fn ctx ->
      if ifc_mode == :off or is_nil(call),
        do: ctx,
        else: Map.put(ctx, :ifc, activation_wire(ref, origin, call))
    end)
  end

  # What the Worker's own internal round discloses and projects. Without its
  # configuration the station has no tools (fail closed).
  defp worker_config(ref, role, station) do
    case SalixAgent.RoundConfig.build_runtime_session_config(ref.agent_id, role, %{
           session_context: station
         }) do
      {:ok, config} ->
        Map.take(config, [
          :tool_disclosure,
          :plugin_projection,
          :plugin_projection_revision,
          :skill_projection_revision
        ])

      {:error, reason} ->
        Logger.warning("station tool call: no Worker configuration",
          task: ref.conversation_id,
          device_id: ref.device_id,
          reason: inspect(reason)
        )

        %{tool_disclosure: %{"tools" => []}}
    end
  end

  # The activation wire a round would carry, from a Session of one input: the
  # call itself, as the request the Task's requester made through this
  # station, sealed with the origin. The kernel finds the request item there
  # (`ifc.request`), as it finds a delivered Message in a Worker's Session;
  # nothing else is in it, since the Worker of a station Task has no Session
  # here. One that cannot be built authorizes nothing (fail closed).
  defp activation_wire(_ref, nil, _call), do: nil

  defp activation_wire(ref, origin, call) do
    source = "station-call:" <> call.id

    state =
      struct(SalixAgent.InternalSession.State, %{
        agent_id: ref.agent_id,
        session_id: "station:" <> ref.device_id <> ":" <> ref.session,
        messages: [
          %{
            id: 1,
            role: "user",
            content: String.slice(call.name <> " " <> Jason.encode!(call.args), 0, 2_000),
            source_message_id: source,
            trusted_origin: origin
          }
        ]
      })

    IFC.Context.build(state,
      source_message_id: source,
      source_message_ids: [source],
      trusted_origin: origin
    )
  rescue
    _ -> nil
  catch
    _kind, _reason -> nil
  end

  defp agent_role(agent_id) do
    case SalixAgent.Control.get(agent_id) do
      {:ok, agent} -> agent["role"]
      _ -> nil
    end
  end

  defp outcome({:ok, %{"error" => true}}), do: "error"
  defp outcome({:ok, _}), do: "ok"
  defp outcome({:refused, _, _}), do: "refused"

  defp result_bytes({:ok, %{"content" => content}}), do: byte_size(content)
  defp result_bytes(_), do: 0
end
