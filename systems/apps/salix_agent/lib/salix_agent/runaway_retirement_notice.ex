defmodule SalixAgent.RunawayRetirementNotice do
  @moduledoc """
  Tells the model which request the runaway guard ended.

  Runaway retirement (`runtime_runaway_retired`) ends the current activation as
  failed without calling the model or sending anything, so its person gets no
  reply. One Router session serves every conversation of a workspace, and the
  next activation is often another person's. A model that still remembers the
  unfinished request then does it inside that activation, where every effect
  belongs to the new source: on production on 2026-11-02 a Router created the
  retired Lark request's Task while handling another person's message, and the
  Task card was published in that other person's chat.

  The first activation after a retirement gets one runtime message naming the
  retired request's chat and sender, telling the model to ask that person to
  send it again instead of carrying the work into the current request.
  """

  alias SalixAgent.InternalSession
  require SalixAgent.InternalSession

  @doc "`{messages, state}` for the activation about to run."
  @spec prepare(term(), map()) :: {[map()], map()}
  def prepare(session, known) do
    previous = known["runaway_retirement"] || %{}

    with true <- InternalSession.is_session(session),
         %{} = retired <- latest_retirement(session),
         hwm when is_integer(hwm) <- retired["settled_ack_hwm"],
         true <- hwm > (previous["announced_hwm"] || 0) do
      {[payload(retired, origins(session, retired))], %{"announced_hwm" => hwm}}
    else
      _ -> {[], previous}
    end
  end

  defp latest_retirement(session) do
    session
    |> InternalSession.get(:events)
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.find_value(fn fact ->
      if value(fact, :kind) == "runtime_runaway_retired" and is_map(value(fact, :event)),
        do: value(fact, :event)
    end)
  end

  # The retired transcript stays in the session until compaction archives it.
  defp origins(session, retired) do
    sources = List.wrap(retired["source_message_ids"])

    session
    |> InternalSession.get(:messages)
    |> List.wrap()
    |> Enum.flat_map(fn message ->
      origin = value(message, :trusted_origin)

      if value(message, :role) == "user" and value(message, :source_message_id) in sources and
           is_map(origin),
         do: [origin],
         else: []
    end)
    |> Enum.uniq_by(&describe/1)
  end

  defp payload(retired, origins) do
    sources = List.wrap(retired["source_message_ids"])

    who =
      case Enum.map(origins, &describe/1) do
        [] -> "source_message_id " <> Enum.join(sources, ", ")
        described -> Enum.join(described, "; ")
      end

    %{
      "runtime_message_id" => "runaway-retired:#{retired["settled_ack_hwm"]}",
      "runtime_message_type" => "runaway_retirement",
      "content_kind" => "model_context",
      "summary" => "the runtime ended an earlier request as failed",
      "content" =>
        "The runtime ended an earlier request as failed after " <>
          "#{retired["consecutive_unsettled_rounds"] || "several"} consecutive rounds that did not settle: " <>
          who <>
          ". That person got no reply. Do not do that request's work in the current request: " <>
          "a Task, card or message created now belongs to the current request's person and chat. " <>
          "Send that person one short message in their own chat saying their request was not completed " <>
          "and asking them to send it again, then handle the current request.",
      "created_at" => SystemsClock.system_time(:second),
      "source_refs" => %{"providers" => ["runaway_retirement"]}
    }
  end

  defp describe(origin) do
    context = origin["provider_context"] || %{}

    [
      origin["provider"],
      field("connect_id", context["connect_id"]),
      field("chat", context["chat_id"] || context["channel_id"]),
      field("thread", context["thread_ts"] || context["root_message_id"]),
      field("message", context["message_id"] || context["message_ts"]),
      field("sender", context["sender_open_id"] || context["user_id"] || context["from_user_id"]),
      field("source_message_id", origin["source_message_id"])
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp field(_name, value) when value in [nil, ""], do: nil
  defp field(name, value), do: "#{name}=#{value}"
end
