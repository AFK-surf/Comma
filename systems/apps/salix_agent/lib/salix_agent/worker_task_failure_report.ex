defmodule SalixAgent.WorkerTaskFailureReport do
  @moduledoc """
  Reports to a Task that its Worker stopped without a result.

  The kernel's runtime failure notice (`Session.Loop.guardNotice`) answers only
  a human source: its reply targets (`RoundQuery.replyTargets`) cover a person
  in a Comma chat or an IM provider. A Worker whose input is a Task message
  from its Router therefore stopped silently after a final model failure or a
  guard park. On staging on 2026-10-08 the Worker "Atlas" stopped this way six
  times, and its Router saw the failures only when it read the Task.

  After such a stop, when the input that started the activation came from an
  `agent_task` Conversation, this sends one message to that Conversation
  through the ordinary `im_api.internal.send_message` dispatch. A Worker report
  wakes the Router like any other. Sources the kernel answers itself are left
  to the kernel. The send is best effort: a failure is logged and changes
  nothing else.
  """

  require Logger

  alias SalixAgent.{GuardFailureReply, InternalSession, SessionToolDispatch}

  @send "im_api.internal.send_message"

  @doc """
  Send the report for `reason` (`:model` or `:guard`) when the activation's
  input came from a Task Conversation. `source_ids` are the activation's
  source ids, read before the failure acknowledged them. `detail` is the model
  failure metadata, or nil.
  """
  @spec maybe_send(term(), map() | nil, map(), [String.t()], :model | :guard, map() | nil) ::
          :sent | :skipped | :failed
  def maybe_send(session, config, runtime_context, source_ids, reason, detail \\ nil) do
    case task_origin(session, source_ids) do
      # A Router reads Task messages too; its failures stay with its own sources.
      {source_id, %{"conversation_id" => conversation_id} = origin}
      when is_map(config) and config.role == "worker" ->
        send_report(
          session,
          config,
          runtime_context,
          source_ids,
          source_id,
          origin,
          conversation_id,
          text(reason, detail, loop_state(origin, conversation_id))
        )

      _ ->
        :skipped
    end
  rescue
    error ->
      Logger.warning("worker_task_failure_report_failed reason=#{inspect(error.__struct__)}")
      :failed
  end

  defp send_report(session, config, runtime_context, source_ids, source_id, origin, cid, text) do
    session_id = InternalSession.session_id(session)

    ctx =
      session
      |> GuardFailureReply.context(config, runtime_context)
      |> Map.merge(%{
        source_message_id: source_id,
        source_message_ids: source_ids,
        trusted_origin: origin,
        trusted_origins: [origin]
      })

    call = %{
      id: "worker-task-failure:#{session_id}:#{SystemsRuntime.Proc.unique_integer([:positive])}",
      name: "call",
      args: %{
        "tool" => @send,
        "ifc" => %{"sources" => []},
        "params" => %{
          "connect_id" => "internal",
          "conversation_id" => cid,
          "content" => [%{"type" => "text", "text" => text}]
        }
      }
    }

    # Synchronous: a report that finished later would wake the stopped session.
    case SessionToolDispatch.execute([call], ctx) do
      [%{status: "completed"}] ->
        :sent

      results ->
        Logger.warning(
          "worker_task_failure_report_refused session_id=#{session_id} " <>
            "status=#{inspect(Enum.map(results, & &1[:status]))}"
        )

        :failed
    end
  end

  # The last Task message among the activation's sources, acknowledged or not.
  defp task_origin(session, source_ids) when is_list(source_ids) and source_ids != [] do
    session
    |> InternalSession.get(:messages)
    |> List.wrap()
    |> Enum.filter(fn message ->
      field(message, :role) == "user" and field(message, :source_message_id) in source_ids
    end)
    |> Enum.map(&{field(&1, :source_message_id), field(&1, :trusted_origin)})
    |> Enum.filter(fn {_id, origin} ->
      is_map(origin) and origin["provider"] == "internal" and
        origin["conversation_kind"] == "agent_task" and is_binary(origin["conversation_id"]) and
        origin["conversation_id"] != ""
    end)
    |> List.last()
  end

  defp task_origin(_session, _source_ids), do: nil

  @billing_stops ~w(model_unavailable quota_exhausted provider_quota_exhausted
                    insufficient_credits account_inactive missing_account)

  @idle " Nothing more will happen on this Task until it receives a new message."

  # A billing stop (`SalixAgent.AccountPool`, `SalixAgent.LLM.Error`,
  # `SalixAgent.BillingAvailability`) is not a provider outage: a retry fails
  # the same way. The report names the reason and what changes the outcome, as
  # the kernel's notice to a person does (`Session/Loop.lean` `noticeText`),
  # so the Router neither retries nor tells people the provider is down
  # (HyperShell, 2026-11-18).
  defp text(:model, %{} = detail, loop_state) do
    reason = field(detail, :reason)

    case field(detail, :error_class) do
      "billing_unavailable" when reason in @billing_stops ->
        "I stopped without a result: this Task cannot run (#{reason}" <>
          body(detail) <>
          "). This is not a temporary provider failure. " <> remedy(reason, detail, loop_state)

      _ ->
        generic(detail)
    end
  end

  defp text(:model, detail, _loop_state), do: generic(detail)

  defp text(:guard, _detail, _loop_state) do
    "I stopped without a result: the runtime ended this execution because my responses stopped making progress. " <>
      "Nothing more will happen on this Task until it receives a new message."
  end

  defp generic(detail) do
    "I stopped without a result: the model service could not continue this request" <>
      cause(detail) <> "." <> @idle
  end

  @verify_goal "If this conversation's original request is not already in your context, read this Task with im_api.internal.read_conversation first; never infer its goal from unrelated messages or notices. "

  @replace_loop_warning "If you create a replacement Loop Task, end this old Task so two Loops do not run. "

  # Leaving out the model does not avoid the stop: the swarm's or org's
  # default Task model may be the same model no account serves.
  defp remedy("model_unavailable", _detail, loop_state) do
    replace_warning = if loop_state, do: @replace_loop_warning, else: ""

    tail =
      if loop_state,
        do:
          "Otherwise tell the requester that an admin must enable an account that serves the model or change the default Task model. " <>
            loop_tail(loop_state),
        else:
          "Otherwise mark this Task failed and tell the requester " <>
            "that an admin must enable an account that serves the model or change the default Task model." <>
            @idle

    "No enabled account of this workspace serves this model, so every retry with it fails. " <>
      @verify_goal <>
      "Call agent.models and create a replacement Task with a model it lists or with its platform model " <>
      "({\"kind\":\"platform\",\"tier\":\"worker\"}) only after confirming this Task's goal and that it can be recreated. " <>
      "Leaving out the model may run the default Task model, " <>
      "which can be the same unserved model. " <>
      replace_warning <>
      tail
  end

  defp remedy("quota_exhausted", detail, loop_state) do
    reset =
      case get_in(detail, ["funding", "reset_at"]) do
        seconds when is_integer(seconds) ->
          " It resets at " <>
            (seconds |> DateTime.from_unix!() |> DateTime.to_iso8601()) <> "."

        _ ->
          " It resets on its own."
      end

    replace_warning = if loop_state, do: " " <> @replace_loop_warning, else: ""
    tail = if loop_state, do: loop_tail(loop_state), else: @idle

    "The workspace's own subscription for this model has reached its usage limit." <>
      reset <>
      " " <>
      @verify_goal <>
      "Create a replacement Task with another model that agent.models lists only after confirming this Task's goal, or send this Task a message after the reset." <>
      replace_warning <>
      tail
  end

  defp remedy("provider_quota_exhausted", _detail, loop_state) do
    replace_warning = if loop_state, do: @replace_loop_warning, else: ""

    tail =
      if loop_state,
        do: "or tell the requester to add funds with that provider. " <> loop_tail(loop_state),
        else:
          "or mark this Task failed and tell the requester to add funds with that provider." <>
            @idle

    "The provider account behind the workspace's own API key or subscription has run out, " <>
      "and Comma credits do not cover it; it does not refill by itself. " <>
      @verify_goal <>
      "Create a replacement Task with another model that agent.models lists only after confirming this Task's goal, " <>
      replace_warning <>
      tail
  end

  # Comma credits or the billing account (`SalixAgent.BillingAvailability`):
  # another model or a wait does not help.
  defp remedy(_denial, _detail, nil) do
    "The workspace's Comma credits or billing account cannot pay for this request; another model or a wait " <>
      "does not change that. Mark this Task failed and tell the requester to add credits or have an admin " <>
      "check the billing account." <> @idle
  end

  defp remedy(_denial, _detail, loop_state) do
    "The workspace's Comma credits or billing account cannot pay for this request; another model or a wait " <>
      "does not change that. Tell the requester to add credits or have an admin check the billing account. " <>
      loop_tail(loop_state)
  end

  defp loop_tail(:active) do
    "Keep this Loop Task active so its Background Loop stays scheduled; only mark it failed if " <>
      "the requester asks to stop the recurring Loop (ending the Task ends its Loop for good)."
  end

  defp loop_tail(:paused) do
    "This Task's Background Loop is currently paused rather than running, but has not ended. " <>
      "Keep this Loop Task active so it can be resumed once resolved; only mark it failed if " <>
      "the requester asks to stop the recurring Loop for good." <> @idle
  end

  defp loop_tail(:failed) do
    "This Task's Background Loop is currently stopped in a failed state rather than running, " <>
      "so nothing will run on its own once resolved until this Task receives instructions with " <>
      "im_api.internal.send_message to repair it; mark it failed if the recurring Loop should " <>
      "end for good." <> @idle
  end

  defp loop_tail(:pending) do
    "This Task's requested Background Loop is still pending (never created), so nothing will " <>
      "run on its own once resolved until this Task receives instructions again with " <>
      "im_api.internal.send_message, or mark it failed (which ends the requested Loop)." <> @idle
  end

  # One indexed read: an unended requested Loop is ended for good if the Router
  # marks the Task failed, so a single blocked run must not instruct the Router
  # to fail an active/paused Loop Task. Fails open to `:active` if the Loop
  # store is unavailable so a transient read fault never tells the Router to
  # destroy a running Loop.
  defp loop_state(%{"agent_group_id" => group_id}, conversation_id)
       when is_binary(group_id) and group_id != "" do
    case SalixAgent.Loops.task_loops(group_id, [conversation_id]) do
      {:ok, %{^conversation_id => %{"trigger" => %{}, "status" => "active"}}} -> :active
      {:ok, %{^conversation_id => %{"trigger" => %{}, "status" => "paused"}}} -> :paused
      {:ok, %{^conversation_id => %{"trigger" => %{}, "status" => "pending"}}} -> :pending
      {:ok, %{^conversation_id => %{"trigger" => %{}, "status" => "failed"}}} -> :failed
      {:ok, _other} -> nil
      {:error, _reason} -> :active
    end
  rescue
    _ -> :active
  catch
    _, _ -> :active
  end

  defp loop_state(_origin, _conversation_id), do: nil

  defp body(detail) do
    case field(detail, :body) do
      body when is_binary(body) and body != "" -> ": " <> String.slice(body, 0, 200)
      _ -> ""
    end
  end

  defp cause(%{} = detail) do
    case detail["message"] || detail[:message] do
      message when is_binary(message) and message != "" -> " (#{String.slice(message, 0, 200)})"
      _ -> ""
    end
  end

  defp cause(_detail), do: ""

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil
end
