defmodule SalixAgent.Loops.Capabilities do
  @moduledoc """
  The host-call surface of a background Loop, and its execution.

  A spinfoam guest reaches the outside world only through `host.call`. There
  is no per-Loop grant: the program is the Agent's own, so a Loop may call
  every capability on this closed allowlist that its creating Agent may call
  itself, and nothing else. The allowlist is:

    * `agent.notify` — wake the Loop's target Session through the ordinary
      delivery path (`SalixAgent.deliver/3`). Requires `dedup_key`; the
      per-Loop notification budget applies.
    * `loop.state.put` / `loop.state.get` — the bounded checkpoint the Loop
      is reloaded from. `put` is fenced by incarnation.
    * `loop.ack` — record that an external event was processed.
    * `loop.log` — a bounded diagnostic line.
    * every registry tool classified `safety: "read"`, every external
      environment tool (`env.*`, `device.*`: `env.exec`, `env.copy`, the
      process tools, computer use, Android), every SSH tool (`ssh.*`), and the HTTP API request tool
      `web.http_request` and `composio.execute`, plus `decide` for typed decisions — executed through
      `SalixAgent.SessionToolDispatch`, the same authorization boundary an
      internal round and the JavaScript host use, with the Loop's Agent,
      Session and sealed origin as the context. That dispatch applies the
      Agent's own tool disclosure, so a Loop cannot reach further than the
      Agent that wrote it. Journal events a tool returns are discarded: a
      Loop owns no Session revision.

  Environment tools, SSH tools, `composio.execute`, and `web.http_request` are the Loop's hands on the
  outside world: a Loop can run a command on a connected device, tail or
  feed a process, copy files, and poll or post to an HTTP JSON API, on its
  own schedule and without a model round. Other write tools (messaging,
  memory, the workspace, schedules) stay off the allowlist: a Loop that
  needs one notifies the model, which performs it in a normal round under
  the usual tool authorization.

  spinfoam receives the complete Loop allowlist and rejects other names.
  This module rechecks that allowlist and the current incarnation before
  dispatch. The Agent's tool disclosure and IFC checks remain authoritative.
  """

  alias SalixAgent.{IFC, Loops, SessionToolDispatch, ToolDisclosure, Tools}
  alias SalixAgent.Loops.Reconciler

  # `arguments` was the exact-equality pin spinfoam applied per capability;
  # without grants every entry is unconstrained.
  @unconstrained %{}

  @notify "agent.notify"
  @state_put "loop.state.put"
  @state_get "loop.state.get"
  @ack "loop.ack"
  @log "loop.log"
  @builtin [@notify, @state_put, @state_get, @ack, @log]

  # The external environment surface (`SalixAgent.Tools.Peers`): every tool
  # that acts on a connected device or its environments.
  @environment_prefixes ~w(env. device.)

  # External calls admitted alongside environment tools. These use public-egress IFC.
  # decide returns typed judgments without granting access to the selected source.
  @external_request_tools ~w(web.http_request decide composio.execute)

  @max_notify_bytes 8 * 1024
  @max_dedup_bytes 128
  @max_log_bytes 1024
  @default_result_bytes 16 * 1024

  @type loop_ref :: %{
          required(:loop_id) => String.t(),
          required(:incarnation) => integer(),
          required(:agent_id) => String.t(),
          required(:session_id) => String.t(),
          required(:tenant_id) => String.t(),
          required(:group_id) => String.t(),
          required(:ifc) => map(),
          optional(:name) => String.t() | nil
        }

  @doc "The built-in capability names."
  @spec builtin() :: [String.t()]
  def builtin, do: @builtin

  @doc "Every registry tool a Loop may call as a read."
  @spec read_tool_names() :: [String.t()]
  def read_tool_names do
    Tools.registry()
    |> Enum.filter(&(Tools.entry_safety(&1) == "read"))
    |> Enum.map(&Tools.entry_name/1)
    |> Enum.reject(&(&1 in ["help"]))
  end

  @doc "Every external environment tool a Loop may call: the `env.*` and `device.*` entries."
  @spec environment_tool_names() :: [String.t()]
  def environment_tool_names do
    Tools.registry()
    |> Enum.map(&Tools.entry_name/1)
    |> Enum.filter(fn name ->
      Enum.any?(@environment_prefixes, &String.starts_with?(name, &1))
    end)
  end

  @doc "The external request tools a Loop may call, including all registered `ssh.*` tools."
  @spec external_request_tool_names() :: [String.t()]
  def external_request_tool_names do
    registered = Tools.registry() |> Enum.map(&Tools.entry_name/1)
    Enum.filter(registered, &(&1 in @external_request_tools or String.starts_with?(&1, "ssh.")))
  end

  @doc "The complete allowlist."
  @spec allowed_names() :: [String.t()]
  def allowed_names,
    do:
      Enum.uniq(
        @builtin ++
          read_tool_names() ++
          environment_tool_names() ++
          external_request_tool_names() ++
          ["im_api.internal.read_conversation"]
      )

  @doc "The whole Loop allowlist, constrained by the Agent's authorization at dispatch."
  @spec load_capabilities() :: [map()]
  def load_capabilities do
    Enum.map(allowed_names(), &%{"name" => &1, "arguments" => @unconstrained})
  end

  # ---- execution -----------------------------------------------------------

  @doc """
  Execute one capability for a running Loop. Returns the JSON result spinfoam
  hands the guest, or an error message.
  """
  @spec call(loop_ref(), String.t(), map(), pos_integer() | nil) ::
          {:ok, term()} | {:error, String.t()}
  def call(loop, capability, arguments, max_result_bytes \\ nil) do
    started = System.monotonic_time()
    arguments = if is_map(arguments), do: arguments, else: %{}

    result =
      with :ok <- check_allowed(capability),
           :ok <- check_incarnation(loop) do
        execute(loop, capability, arguments, max_result_bytes || @default_result_bytes)
      end

    emit("loop_host_call", result_outcome(result), System.monotonic_time() - started)
    result
  end

  # Every capability, read or write, is refused once the Loop has moved to a
  # newer incarnation or left `active`: a stale object on a superseded node
  # sees nothing and changes nothing. Mutations keep their own atomic guard
  # on top of this check.
  defp check_incarnation(loop) do
    if Loops.current_incarnation?(loop.loop_id, loop.incarnation),
      do: :ok,
      else: {:error, "loop incarnation #{loop.incarnation} is no longer current"}
  end

  # Salix's own check of the closed allowlist; spinfoam applies the same list
  # in the guest. A tool on the list still passes the Agent's disclosure in
  # `SessionToolDispatch`.
  defp check_allowed(capability) do
    if capability in allowed_names(),
      do: :ok,
      else: {:error, "capability not available to loops: " <> capability}
  end

  defp execute(loop, @notify, arguments, _max) do
    content = to_string(arguments["content"] || arguments["text"] || "")
    dedup = to_string(arguments["dedup_key"] || "")

    cond do
      content == "" ->
        {:error, "content is required"}

      byte_size(content) > @max_notify_bytes ->
        {:error, "content exceeds #{@max_notify_bytes} bytes"}

      dedup == "" ->
        {:error, "dedup_key is required"}

      byte_size(dedup) > @max_dedup_bytes ->
        {:error, "dedup_key exceeds #{@max_dedup_bytes} bytes"}

      true ->
        notify(loop, content, dedup)
    end
  end

  defp execute(loop, @state_put, arguments, _max) do
    state = Map.get(arguments, "state", arguments)

    case Loops.put_checkpoint(loop.loop_id, loop.incarnation, state) do
      :ok ->
        {:ok, %{"status" => "stored"}}

      {:error, :stale_incarnation} ->
        {:error, "stale incarnation"}

      {:error, :checkpoint_too_large} ->
        {:error, "checkpoint exceeds #{Loops.max_checkpoint_bytes()} bytes"}

      {:error, reason} ->
        {:error, "checkpoint unavailable: #{inspect(reason)}"}
    end
  end

  defp execute(loop, @state_get, _arguments, _max) do
    case Loops.get_checkpoint(loop.loop_id) do
      {:ok, state} -> {:ok, %{"state" => state}}
      {:error, reason} -> {:error, "checkpoint unavailable: #{inspect(reason)}"}
    end
  end

  defp execute(loop, @ack, arguments, _max) do
    event_id = to_string(arguments["event_id"] || "")

    case Loops.ack_event(loop.loop_id, loop.incarnation, event_id) do
      :ok -> {:ok, %{"status" => "acked", "event_id" => event_id}}
      {:error, :invalid_event_id} -> {:error, "event_id is required"}
      {:error, reason} -> {:error, "ack unavailable: #{inspect(reason)}"}
    end
  end

  defp execute(loop, @log, arguments, _max) do
    message = arguments["message"] || arguments["text"] || arguments
    encoded = if is_binary(message), do: message, else: Jason.encode!(message)

    CommaLog.log("loop_log", %{
      agent_id: loop.agent_id,
      loop_id: loop.loop_id,
      incarnation: loop.incarnation,
      message: String.slice(encoded, 0, @max_log_bytes)
    })

    {:ok, %{"status" => "logged"}}
  end

  defp execute(loop, tool_name, arguments, max_result_bytes) do
    with :ok <- check_tool_destination(tool_name, arguments),
         :ok <- authorize_source(loop.loop_id, tool_name, arguments) do
      execute_tool(loop, tool_name, arguments, max_result_bytes)
    end
  end

  # Workspace and skill writes need a Session journal commit, which Loops do not own.
  defp check_tool_destination("ssh.download", arguments) do
    if SalixAgent.DriveMount.matches?(arguments["destination"]),
      do: :ok,
      else:
        {:error,
         "Loop SSH downloads require a /drive destination. Use a normal round for workspace downloads."}
  end

  defp check_tool_destination(_tool_name, _arguments), do: :ok

  defp execute_tool(loop, tool_name, arguments, max_result_bytes) do
    call = %{
      id: "loop:" <> loop.loop_id <> ":" <> Integer.to_string(System.unique_integer([:positive])),
      name: tool_name,
      args: arguments
    }

    ctx = tool_ctx(loop)

    case SessionToolDispatch.execute([call], ctx) do
      [result] ->
        content = to_string(result[:content] || result["content"] || "")
        error? = result[:error] == true or result["error"] == true

        # A Loop owns no Session revision, so journal events the tool
        # returned are dropped here, deliberately.
        content =
          cond do
            tool_name != "decide" ->
              bounded_content(content, max_result_bytes)

            byte_size(
              Jason.encode!(%{"tool" => tool_name, "error" => error?, "content" => content})
            ) > max_result_bytes ->
              Jason.encode!(%{"error" => %{"code" => "result_too_large"}})

            true ->
              content
          end

        payload = %{
          "tool" => tool_name,
          "error" => error?,
          "content" => content
        }

        if error? do
          {:error, "tool failed: " <> String.slice(content, 0, 512)}
        else
          # Revocation during a read must not return its result to a product Loop.
          with :ok <- authorize_source(loop.loop_id, tool_name, arguments), do: {:ok, payload}
        end

      other ->
        {:error, "tool dispatch returned #{inspect(other) |> String.slice(0, 256)}"}
    end
  rescue
    exception -> {:error, "tool raised: " <> Exception.message(exception)}
  catch
    kind, value -> {:error, "tool #{kind}: #{inspect(value) |> String.slice(0, 256)}"}
  end

  # Result bodies are bounded by spinfoam (16 KiB encoded); leave headroom
  # for the envelope keys.
  defp bounded_content(content, max_result_bytes) do
    budget = max(max_result_bytes - 256, 256)

    if byte_size(content) <= budget,
      do: content,
      else:
        binary_part(content, 0, budget) <> "\n…[truncated #{byte_size(content) - budget} bytes]"
  end

  defp tool_ctx(loop) do
    origin = origin(loop)
    role = agent_role(loop.agent_id)
    ifc_mode = IFC.mode_for(loop.tenant_id, loop.group_id)

    base = %{
      agent_id: loop.agent_id,
      session_id: loop.session_id,
      tenant_id: loop.tenant_id,
      group_id: loop.group_id,
      role: role,
      runtime_kind: :internal,
      loop_id: loop.loop_id,
      round_id: "loop:" <> loop.loop_id <> ":" <> Integer.to_string(loop.incarnation),
      ifc_mode: ifc_mode,
      defer_tool_observations: true
    }

    base
    |> Map.put(
      :tool_disclosure,
      ToolDisclosure.materialize_prepared(
        role,
        :internal,
        base,
        SalixAgent.Tools.ImRouter.internal_read_disclosure_entries(base),
        []
      )
    )
    |> then(fn ctx ->
      if origin,
        do: Map.merge(ctx, %{trusted_origin: origin, trusted_origins: [origin]}),
        else: ctx
    end)
    |> then(fn ctx ->
      if ifc_mode == :off, do: ctx, else: Map.put(ctx, :ifc, activation_wire(loop, origin))
    end)
  end

  # Under audit or enforce the check needs the activation wire a round would
  # carry: the Loop's target Session labelled with the Loop's sealed origin
  # as the requesting command. A Session that cannot be read yields no wire,
  # which the check reads as "nothing authorized" (fail closed).
  defp activation_wire(_loop, nil), do: nil

  defp activation_wire(loop, origin) do
    case SalixAgent.InternalSessionStore.read(loop.agent_id, loop.session_id) do
      {:ok, session} -> IFC.Context.build(session, trusted_origin: origin)
      _ -> nil
    end
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

  # ---- notification --------------------------------------------------------

  defp notify(loop, content, dedup) do
    case Loops.admit_notification(loop.loop_id, loop.incarnation) do
      :ok ->
        deliver_notification(loop_record(loop), content, dedup)

      {:error, :rate_limited} ->
        {:error, "rate_limited"}

      {:error, :budget_paused} ->
        {:error, "notification budget exhausted; loop paused"}

      {:error, :stale_incarnation} ->
        {:error, "stale incarnation"}

      {:error, reason} ->
        {:error, "notification refused: #{inspect(reason)}"}
    end
  end

  @doc """
  Deliver a Loop notification into its target Session. `record` is the Loop
  row (or a loop ref). The source id is `loop:<id>:<dedup_key>`, so a retry
  after a timeout dedupes on the delivery ledger.
  """
  @spec deliver_notification(map(), String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def deliver_notification(record, content, dedup) do
    started = System.monotonic_time()
    loop_id = record["id"] || record[:loop_id]
    agent_id = record["agent_id"] || record[:agent_id]
    session_id = record["session_id"] || record[:session_id]
    name = record["name"] || record[:name]
    ifc = record["ifc"] || record[:ifc] || %{}
    label = if name in [nil, ""], do: loop_id, else: "#{name} (#{loop_id})"

    payload =
      %{
        content: "Background loop #{label}:\n" <> content,
        session_id: session_id,
        kind: "loop",
        role: "user",
        source_sent_at_ms: System.system_time(:millisecond)
      }
      |> put_origin(IFC.loop_origin(loop_id, ifc["creator"], ifc["label"]))

    result =
      with :ok <- authorize_source(loop_id) do
        SalixAgent.deliver(agent_id, payload,
          source_message_id: "loop:" <> loop_id <> ":" <> dedup,
          create: false,
          session_check: :staging,
          surface: "loop"
        )
      end

    outcome =
      case result do
        {:ok, :created} -> "ok"
        {:ok, :duplicate} -> "already"
        {:error, :missing_session_id} -> "unroutable"
        {:error, _} -> "error"
      end

    emit("loop_notify", outcome, System.monotonic_time() - started)

    case result do
      {:ok, :created} ->
        {:ok, %{"status" => "queued"}}

      {:ok, :duplicate} ->
        {:ok, %{"status" => "duplicate"}}

      {:error, reason} when reason in [:missing_session_id, :invalid_session_id] ->
        Loops.mark_undeliverable(loop_id)
        {:error, "target session is not deliverable"}

      {:error, reason} ->
        if undeliverable_target?(reason), do: Loops.mark_undeliverable(loop_id)
        {:error, "delivery failed: " <> (inspect(reason) |> String.slice(0, 256))}
    end
  end

  defp authorize_source(loop_id, capability \\ "agent.notify", args \\ %{}) do
    with {:ok, row} <- SalixStore.Loops.get(loop_id) do
      case Application.get_env(:salix_agent, :loop_authorization_adapter) do
        nil ->
          if is_map(row["config"]["comma_proactive"]) or is_map(row["config"]["comma_mail"]),
            do: {:error, :proactive_authorization_unavailable},
            else: :ok

        module ->
          module.authorize(row, capability, args)
      end
    end
  end

  # The archived-target refusal and a retired session are permanent for
  # this Loop; storage trouble and timeouts are not.
  defp undeliverable_target?({:bad_request, "agent is archived"}), do: true
  defp undeliverable_target?(:not_found), do: true
  defp undeliverable_target?(_), do: false

  defp put_origin(payload, nil), do: payload
  defp put_origin(payload, origin), do: Map.put(payload, :trusted_origin, origin)

  defp origin(loop) do
    ifc = loop.ifc || %{}
    IFC.loop_origin(loop.loop_id, ifc["creator"], ifc["label"])
  end

  defp loop_record(loop) do
    %{
      "id" => loop.loop_id,
      "agent_id" => loop.agent_id,
      "session_id" => loop.session_id,
      "name" => loop[:name],
      "ifc" => loop.ifc
    }
  end

  @doc false
  def release_after_pause(agent_id, loop_id), do: Reconciler.release_loop(agent_id, loop_id)

  defp result_outcome({:ok, _}), do: "ok"
  defp result_outcome({:error, "rate_limited"}), do: "over_budget"
  defp result_outcome({:error, "stale incarnation"}), do: "rejected"
  defp result_outcome({:error, "capability not available to loops: " <> _}), do: "rejected"
  defp result_outcome({:error, _}), do: "error"

  defp emit(operation, outcome, duration) do
    Salix.Telemetry.emit_operation("salix_agent", operation, "loop", outcome, duration)
  end
end
