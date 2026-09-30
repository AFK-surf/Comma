defmodule SalixAgent.Tools.AsyncOps do
  @moduledoc """
  Runtime wait and background tool-call lifecycle tools.

  `defs/0` returns entries in the exact `@registry` shape of
  `SalixAgent.Tools` (`{name, description, fun, auto_wait_seconds}` with a
  2-arity `(args, ctx)` capture) so the orchestrator can append them to the
  dispatcher registry.
  Tools that change durable wait state return `{content, events}` using the
  runtime session event vocabulary:

    * `wait_set`   — `%{"type" => "wait_set", "session_id" => sid, "wait" => wait}`
    * `wait_clear` — `%{"type" => "wait_clear", "session_id" => sid}`
    * `async_tool_call_cancelled` — marks a background tool call cancelled

  `permission.request` and `location.request` create durable request records,
  mark the corresponding `tool_call_id` as running, and return an
  auto-wait event so the agent can be woken by completion or timeout.

  ## Session id

  These tools are scoped to the current runtime session. The dispatcher passes
  `ctx.session_id`; agent-supplied arguments cannot retarget another session.

  ## Documented simplifications vs willow (Go)

    * `permission.request` takes a single `capability` parameter (plus an
      optional `description`) instead of willow's `{environment, description,
      kind}` host-access flow — there is no session-grant table and no
      bridge/native-IM delivery surface. It creates a durable capability
      request through `SalixAgent.CapabilityRequestStore`; completion resolves
      the stored tool call through the owning runtime session actor.
    * `location.request` performs no bridge/native surface resolution; the host
      completion resolves the stored tool call through the capability
      request completion path and owning runtime session actor.
  """

  alias SalixAgent.{
    AsyncToolResults,
    CapabilityRequestStore,
    Control,
    ExternalSessionStore,
    InternalSessionStore,
    Runtime,
    Waits
  }

  alias SalixAgent.Tools.AsyncPolicy

  @wait_for_min_timeout 1
  @wait_for_recommended_timeout AsyncPolicy.wait_for_default_seconds()
  @wait_for_max_timeout AsyncPolicy.wait_for_max_seconds()

  @normal_auto_wait_seconds AsyncPolicy.normal_tool_auto_wait_seconds()
  @user_interaction_auto_wait_seconds AsyncPolicy.user_interaction_tool_auto_wait_seconds()
  @visible_request_opts [safety: "write"]
  @request_location_default_timeout @user_interaction_auto_wait_seconds
  @request_location_max_timeout 1800
  @result_page_chars AsyncToolResults.result_response_max_bytes()

  @doc "Tool defs in canonical registration order — append to the dispatcher registry."
  @spec defs() ::
          [
            {String.t(), String.t(), (map(), map() -> term()), pos_integer()}
            | {String.t(), String.t(), (map(), map() -> term()), pos_integer(), keyword()}
          ]
  def defs do
    [
      {"question.request",
       "Ask one essential question in the current Telegram chat. Provide choices to send native inline buttons; without choices, the user replies to the prompt with text. Delivery ends this activation; the answer arrives as a new input. Never poll for the user.",
       &__MODULE__.request_question/2, @normal_auto_wait_seconds, @visible_request_opts},
      {"permission.request",
       "Request temporary user permission for a protected capability. " <>
         "Creates a user-visible request and returns its request id. " <>
         "The tool sets an auto-wait because the user normally cannot answer within one tool call.",
       &__MODULE__.request_permission/2, @user_interaction_auto_wait_seconds,
       @visible_request_opts},
      {"location.request",
       "Ask for location when precise coordinates are needed; for city-level weather, ask for the city instead. " <>
         "Location requests are unavailable in Comma Telegram. Ask for a city in a text reply instead. " <>
         "In the internal host app, creates a location request with an auto-wait for the user's response.",
       &__MODULE__.request_location/2, @user_interaction_auto_wait_seconds,
       @visible_request_opts},
      {"tool_call.get_status", "Return the current status for a tool call by tool_call_id.",
       &__MODULE__.get_tool_call_status/2, @normal_auto_wait_seconds},
      {"tool_call.get_result",
       "Return a session-owned stored result by opaque result_ref or legacy tool_call_id. Results are returned as byte-bounded JSON result_page values; use next_offset to read later pages. If a legacy tool call is still running in the background, returns status=running.",
       &__MODULE__.get_tool_call_result/2, @normal_auto_wait_seconds},
      {"tool_call.cancel", "Cancel a background tool call that is no longer needed.",
       &__MODULE__.cancel_tool_call/2, @normal_auto_wait_seconds}
    ]
  end

  @doc false
  def wait_for_def do
    {"wait_for",
     "Pause the current task until later input, a timeout, or another future wake resumes you.\n\n" <>
       "Use this only for a concrete runtime-observable future condition, such as an already-running tool or delegated Task. " <>
       "If only essential user input or a user-managed connection is missing and no independent work can progress, ask once with end_turn outcome=blocked and an unsent question in reply; omit reply if the question was already sent. Do not poll for a person's reply, credentials, or a new request. " <>
       "Before calling wait_for, inspect every user message visible in the current turn; never wait for a condition already satisfied by current messages, including worker reports delivered together. " <>
       "Provide only the reason you are waiting. " <>
       "The default timeout is #{@wait_for_recommended_timeout} seconds. Only use longer waits, " <>
       "up to #{@wait_for_max_timeout} seconds, for clearly explained long-running monitoring or background work. " <>
       "While a Worker on one of your delegated Tasks is still working, the runtime keeps this wait open past its timeout on its own; the Worker's report, or a runtime notice that it stopped or failed, wakes you as Task input. Do not pick a timeout in order to check on a Worker. " <>
       "After waking, check the current task/monitoring state before deciding to wait again. If the same user-input blocker remains with no new facts, end the turn without another unchanged status message. " <>
       "In a Router, a generic wait without running tools may yield the current source as blocked when another provider request is queued; it does not claim completion or delivery. Keep ongoing follow-up in a durable Task or schedule, not only in a wait reason. " <>
       "A timeout wakes you with an explicit wait_timeout notification; it does not cancel background tool calls. " <>
       "Consecutive timeout wakes with no new input draw down a wait budget; once it is exhausted wait_for fails and you must conclude or ask for direction instead of waiting again.",
     &__MODULE__.wait_for/2, @normal_auto_wait_seconds}
  end

  # ---- tools ----

  @doc false
  def wait_for(args, ctx) do
    reason = arg(args, "reason")
    if reason == "", do: raise("'reason' is required")

    timeout = int_arg(args, "timeout_seconds") || @wait_for_recommended_timeout

    unless timeout >= @wait_for_min_timeout and timeout <= @wait_for_max_timeout do
      raise "'timeout_seconds' must be between #{@wait_for_min_timeout} and #{@wait_for_max_timeout} " <>
              "(use #{@wait_for_recommended_timeout} or less unless long-running monitoring really needs more)"
    end

    sid = session_id(args, ctx)
    check_wait_budget!(ctx.agent_id, sid)
    wait = Waits.build(reason, timeout, "wait_for")

    content =
      Jason.encode!(%{
        "status" => "waiting",
        "wait_id" => wait["wait_id"],
        "reason" => reason,
        "timeout_seconds" => wait["timeout_seconds"],
        "message" => "the session will wake on any notification or on wait timeout"
      })

    {content, [Waits.event(sid, wait)]}
  end

  # Self-wake circuit breaker: a raise here surfaces as an error tool result
  # with no wait_set event, so no timer is registered and the loop breaks.
  # Fails open when the transcript can't be read — the budget must never make
  # a legitimate wait flakier than the store.
  defp check_wait_budget!(agent_id, session_id) do
    cap = AsyncPolicy.wait_for_activation_cap()

    with true <- is_integer(cap) and cap > 0,
         {:ok, state} <- InternalSessionStore.read(agent_id, session_id),
         timeouts = SalixAgent.InternalSession.consecutive_timeouts(state),
         true <- timeouts >= cap do
      raise "wait budget exhausted: #{timeouts} consecutive wait timeouts woke this session " <>
              "with no new input in between; do not wait again — conclude with your best " <>
              "final result, report what is blocking you, or ask the user for direction"
    else
      _ -> :ok
    end
  end

  @doc false
  def request_question(args, ctx),
    do: SalixAgent.TelegramInteraction.request("question", args, ctx)

  def request_permission(args, %{trusted_origin: %{"provider" => "telegram"}} = ctx),
    do: SalixAgent.TelegramInteraction.request("permission", args, ctx)

  def request_permission(args, ctx) do
    cap = arg(args, "capability")
    if cap == "", do: raise("'capability' is required")

    description = arg(args, "description")
    sid = session_id(args, ctx)
    request_type = permission_request_type(cap)
    tool_call_id = tool_call_id(ctx)

    request =
      create_capability_request!(%{
        "source_agent_id" => ctx.agent_id,
        "source_session_id" => sid,
        "tool_call_id" => tool_call_id,
        "request_type" => request_type,
        "request_payload" => %{
          request_type =>
            %{"capability" => cap}
            |> put_optional_nonblank("description", description)
            |> put_optional_nonblank("reason", description)
        }
      })

    content =
      Jason.encode!(%{
        "status" => "running",
        "tool_call_id" => tool_call_id,
        "request_id" => request["request_id"],
        "capability" => cap,
        "auto_wait_seconds" => @user_interaction_auto_wait_seconds,
        "message" =>
          "permission request is pending; completion will arrive as a tool call notification"
      })

    {content,
     async_request_events(
       "permission.request",
       sid,
       tool_call_id,
       %{"capability" => cap, "description" => description},
       "permission: " <> cap,
       @user_interaction_auto_wait_seconds,
       request
     )}
  end

  @doc false
  def request_location(args, %{trusted_origin: %{"provider" => "telegram"}} = ctx),
    do: SalixAgent.TelegramInteraction.request("location", args, ctx)

  def request_location(args, ctx) do
    reason = arg(args, "reason")
    if reason == "", do: raise("missing required parameter: reason")

    timeout = int_arg(args, "timeout_seconds") || @request_location_default_timeout

    unless timeout >= 1 and timeout <= @request_location_max_timeout do
      raise "timeout_seconds must be between 1 and #{@request_location_max_timeout}"
    end

    sid = session_id(args, ctx)
    tool_call_id = tool_call_id(ctx)

    request =
      create_capability_request!(%{
        "source_agent_id" => ctx.agent_id,
        "source_session_id" => sid,
        "tool_call_id" => tool_call_id,
        "request_type" => "location",
        "request_payload" => %{"location" => %{"reason" => reason}},
        "expires_at" => System.system_time(:second) + timeout
      })

    content =
      Jason.encode!(%{
        "status" => "running",
        "message" => "location request is pending",
        "request_id" => request["request_id"],
        "tool_call_id" => tool_call_id,
        "auto_wait_seconds" => @user_interaction_auto_wait_seconds
      })

    {content,
     async_request_events(
       "location.request",
       sid,
       tool_call_id,
       %{"reason" => reason, "timeout_seconds" => timeout},
       "location",
       @user_interaction_auto_wait_seconds,
       request
     )}
  end

  @doc false
  def get_tool_call_status(args, ctx) do
    id = required_tool_call_id(args)

    case async_record(ctx, id) do
      nil ->
        Jason.encode!(%{"status" => "not_found", "tool_call_id" => id})

      record ->
        Jason.encode!(
          Map.take(record, [
            "tool_call_id",
            "tool_name",
            "status",
            "started_at",
            "updated_at",
            "completed_at",
            "cancelled_at",
            "auto_wait_seconds",
            "progress"
          ])
          |> Map.put(
            "has_result",
            Map.has_key?(record, "result") or Map.has_key?(record, "result_json")
          )
          |> Map.put("has_error", async_record_has_error?(record))
        )
    end
  end

  @doc false
  def get_tool_call_result(args, ctx) do
    locator = result_locator(args)

    case result_record(ctx, locator) do
      {:error, reason} ->
        raise "stored tool result lookup failed: #{inspect(reason)}"

      nil ->
        Jason.encode!(Map.merge(%{"status" => "not_found"}, locator_payload(locator)))

      record when is_map(record) ->
        if terminal_result_record?(record) do
          content = terminal_result_content(record, args, locator)
          result = apply_result_diagnostic_contract(record, content)

          nested_ifc =
            case record["result"] do
              %{"ifc" => %{} = ifc} -> ifc
              _ -> nil
            end

          case {result, record["ifc"] || nested_ifc} do
            {text, %{} = ifc} when is_binary(text) -> {:tool_ifc, text, [], ifc}
            _ -> result
          end
        else
          Jason.encode!(
            Map.merge(
              %{
                "status" => record["status"] || "running",
                "message" => "tool call has not completed yet"
              },
              locator_payload(locator)
            )
          )
        end
    end
  end

  defp terminal_result_content(record, args, locator) do
    cond do
      result_record?(record) and page_result?(record, args, locator) ->
        offset = non_negative_int_arg(args, "offset", 0)
        limit = positive_int_arg(args, "limit", @result_page_chars)

        if limit > @result_page_chars do
          raise "'limit' must be between 1 and #{@result_page_chars}"
        end

        record
        |> AsyncToolResults.result_page_envelope(offset, limit)
        |> Jason.encode!()

      true ->
        Jason.encode!(record)
    end
  end

  defp page_result?(record, args, locator) do
    Map.has_key?(record, "result_json") or match?({:result_ref, _}, locator) or
      has_arg?(args, "offset") or has_arg?(args, "limit") or
      byte_size(Jason.encode!(record)) > AsyncToolResults.result_response_max_bytes()
  end

  defp result_record?(record),
    do: Map.has_key?(record, "result_json") or Map.has_key?(record, "result")

  defp terminal_result_record?(record) do
    Map.has_key?(record, "result_json") or
      record["status"] in ["completed", "failed", "cancelled"]
  end

  @doc false
  def cancel_tool_call(args, ctx) do
    id = required_tool_call_id(args)
    reason = arg(args, "reason")
    sid = session_id(args, ctx)
    now = System.system_time(:millisecond)

    case async_record(ctx, id) do
      nil ->
        Jason.encode!(%{"status" => "not_found", "tool_call_id" => id})

      %{"status" => status} = record when status in ["completed", "failed", "cancelled"] ->
        apply_result_diagnostic_contract(record, Jason.encode!(record))

      record ->
        _ = cancel_provider_tool_call(record, ctx, id, reason)
        :ok = cancel_capability_request!(ctx, sid, id, reason)

        content =
          Jason.encode!(%{
            "status" => "cancelled",
            "tool_call_id" => id,
            "reason" => reason,
            "message" => "the tool call was cancelled"
          })

        event =
          %{
            "type" => "async_tool_call_cancelled",
            "session_id" => sid,
            "tool_call_id" => id,
            "cancelled_at" => now
          }
          |> put_optional_nonblank("cancel_reason", reason)

        events =
          [event] ++
            if clear_wait_after_cancel?(ctx, sid, id),
              do: [%{"type" => "wait_clear", "session_id" => sid}],
              else: []

        {content, events}
    end
  end

  # ---- helpers ----

  defp session_id(_args, ctx) do
    case Map.get(ctx, :session_id) do
      sid when is_binary(sid) and sid != "" ->
        sid

      _ ->
        raise "ctx.session_id is required"
    end
  end

  defp async_request_events(
         tool_name,
         sid,
         tool_call_id,
         input,
         reason,
         auto_wait_seconds,
         request
       ) do
    now = System.system_time(:millisecond)

    wait =
      Waits.build(reason, auto_wait_seconds, "auto_wait", %{
        "tool_call_id" => tool_call_id,
        "tool_name" => tool_name
      })

    [
      %{
        "type" => "async_tool_call_started",
        "session_id" => sid,
        "tool_call_id" => tool_call_id,
        "tool_name" => tool_name,
        "input" => Jason.encode!(input),
        "status" => "running",
        "completion_mode" => "external_callback",
        "started_at" => now,
        "auto_wait_seconds" => auto_wait_seconds
      }
      |> Map.merge(CapabilityRequestStore.execution_fields(request)),
      Waits.event(sid, wait)
    ]
  end

  defp required_tool_call_id(args) do
    id = arg(args, "tool_call_id")
    if id == "", do: raise("'tool_call_id' is required")
    id
  end

  defp async_record(ctx, id) do
    sid = session_id(%{}, ctx)
    agent_id = Map.get(ctx, :agent_id)

    case Runtime.get_async_tool_call(agent_id, sid, id) do
      {:ok, record} -> record
      {:error, _} -> nil
    end
  end

  defp result_record(ctx, {:tool_call_id, id}), do: async_record(ctx, id)

  defp result_record(ctx, {:result_ref, result_ref}) do
    sid = session_id(%{}, ctx)
    agent_id = Map.get(ctx, :agent_id)

    case InternalSessionStore.fetch_tool_result(agent_id, sid, result_ref) do
      {:ok, record} -> Map.put_new(record, "result_ref", result_ref)
      {:error, :not_found} -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  defp async_record_has_error?(record) do
    record["error"] == true or record["is_error"] == true or present?(record["error_class"]) or
      present?(record["error_message"])
  end

  defp result_locator(args) do
    tool_call_id = arg(args, "tool_call_id")
    result_ref = arg(args, "result_ref")

    case {tool_call_id, result_ref} do
      {"", ""} ->
        raise "exactly one of 'tool_call_id' or 'result_ref' is required"

      {id, ""} ->
        {:tool_call_id, id}

      {"", ref} ->
        {:result_ref, ref}

      {_id, _ref} ->
        raise "exactly one of 'tool_call_id' or 'result_ref' is required"
    end
  end

  defp locator_payload({:tool_call_id, id}), do: %{"tool_call_id" => id}
  defp locator_payload({:result_ref, ref}), do: %{"result_ref" => ref}

  defp apply_result_diagnostic_contract(record, content) do
    case AsyncToolResults.result_diagnostic_contract(record) do
      {:user_reportable, error_class, public_summary} ->
        {:tool_failure, content, error_class, "user_reportable", public_summary, []}

      {:model_only, error_class} ->
        {:tool_failure, content, error_class, "model_only", nil, []}

      :none ->
        content
    end
  end

  defp clear_wait_after_cancel?(ctx, sid, cancelled_id) do
    agent_id = Map.get(ctx, :agent_id)

    with {:ok, wait, calls} <- wait_and_async_calls(agent_id, sid),
         true <- auto_wait_for_tool?(wait, cancelled_id) do
      wait
      |> wait_tool_call_ids()
      |> Enum.reject(&(&1 == cancelled_id))
      |> Enum.any?(&running_tool_call?(calls, &1))
      |> Kernel.not()
    else
      _ -> false
    end
  end

  defp wait_and_async_calls(agent_id, sid) when is_binary(agent_id) and is_binary(sid) do
    with {:ok, agent} <- Control.get_record(agent_id) do
      case Control.runtime_kind(agent) do
        "external" ->
          with {:ok, session} <- ExternalSessionStore.get_session_record(agent_id, sid) do
            {:ok, session["wait"], session["async_tool_calls"] || %{}}
          end

        _ ->
          with {:ok, session} <- InternalSessionStore.read(agent_id, sid) do
            {:ok, SalixAgent.InternalSession.wait(session),
             SalixAgent.InternalSession.get(session, :async_tool_calls) || %{}}
          end
      end
    end
  end

  defp wait_and_async_calls(_agent_id, _sid), do: {:error, :invalid_scope}

  defp auto_wait_for_tool?(wait, tool_call_id) when is_map(wait) do
    wait["source"] == "auto_wait" and tool_call_id in wait_tool_call_ids(wait)
  end

  defp auto_wait_for_tool?(_wait, _tool_call_id), do: false

  defp wait_tool_call_ids(wait) when is_map(wait) do
    ids =
      case wait["tool_call_ids"] || wait[:tool_call_ids] do
        list when is_list(list) -> list
        id when is_binary(id) -> [id]
        _ -> []
      end

    (ids ++ List.wrap(wait["tool_call_id"] || wait[:tool_call_id]))
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp running_tool_call?(calls, tool_call_id) when is_map(calls) do
    case Map.get(calls, tool_call_id) || Map.get(calls, to_string(tool_call_id)) do
      %{"status" => "running"} -> true
      %{status: "running"} -> true
      %{status: :running} -> true
      _ -> false
    end
  end

  defp running_tool_call?(_calls, _tool_call_id), do: false

  defp arg(args, key) do
    (args[key] || args[String.to_atom(key)] || "") |> to_string() |> String.trim()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp int_arg(args, key) do
    case args[key] || args[String.to_atom(key)] do
      nil ->
        nil

      v when is_integer(v) ->
        v

      v when is_binary(v) ->
        case Integer.parse(v) do
          {i, ""} -> i
          _ -> raise "'#{key}' must be an integer"
        end

      _ ->
        raise "'#{key}' must be an integer"
    end
  end

  defp non_negative_int_arg(args, key, default) do
    value = int_arg(args, key)
    value = if is_nil(value), do: default, else: value
    if value < 0, do: raise("'#{key}' must be zero or greater")
    value
  end

  defp positive_int_arg(args, key, default) do
    value = int_arg(args, key)
    value = if is_nil(value), do: default, else: value
    if value < 1, do: raise("'#{key}' must be a positive integer")
    value
  end

  defp has_arg?(args, key),
    do: Map.has_key?(args, key) or Map.has_key?(args, String.to_atom(key))

  defp create_capability_request!(attrs) do
    case CapabilityRequestStore.create_capability_request(attrs) do
      {:ok, request} -> request
      {:error, reason} -> raise "create capability request: #{format_reason(reason)}"
    end
  end

  defp cancel_capability_request!(ctx, sid, tool_call_id, reason) do
    case CapabilityRequestStore.cancel_capability_request(
           Map.get(ctx, :agent_id),
           sid,
           tool_call_id,
           reason
         ) do
      {:ok, _request_or_not_found} -> :ok
      {:error, reason} -> raise "cancel capability request: #{format_reason(reason)}"
    end
  end

  defp cancel_provider_tool_call(
         %{"tool_name" => "mcp." <> _ = tool_name},
         ctx,
         tool_call_id,
         reason
       ) do
    SalixAgent.Tools.MCP.cancel_dynamic_operation(tool_name, ctx, tool_call_id, reason)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp cancel_provider_tool_call(_record, _ctx, _tool_call_id, _reason), do: :ok

  defp permission_request_type("computer_use_start"), do: "computer_use_start"
  defp permission_request_type("computer-use-start"), do: "computer_use_start"
  defp permission_request_type(_capability), do: "host_access"

  defp tool_call_id(ctx) do
    case Map.get(ctx, :tool_call_id) do
      id when is_binary(id) and id != "" -> id
      _ -> random_id()
    end
  end

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp put_optional_nonblank(map, _key, ""), do: map
  defp put_optional_nonblank(map, _key, nil), do: map
  defp put_optional_nonblank(map, key, value), do: Map.put(map, key, value)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
