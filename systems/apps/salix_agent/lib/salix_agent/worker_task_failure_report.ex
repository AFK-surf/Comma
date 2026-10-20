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
          text(reason, detail)
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

  defp text(:model, detail) do
    "I stopped without a result: the model service could not continue this request" <>
      cause(detail) <>
      ". Nothing more will happen on this Task until it receives a new message."
  end

  defp text(:guard, _detail) do
    "I stopped without a result: the runtime ended this execution because my responses stopped making progress. " <>
      "Nothing more will happen on this Task until it receives a new message."
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
