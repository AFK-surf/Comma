defmodule SalixIM.TaskCardProjection do
  @moduledoc """
  Provider-neutral projection of one Task Conversation onto a native Task card.

  A Task card is a provider Participant with `role_label: "task_card"`. Its
  payload holds the projected title, lifecycle, latest public output and a
  bounded window of recent visible messages. Conversation lifecycle remains
  authoritative. Each provider adapter owns only its message address, write
  evidence and native layout: `SalixIM.SlackTaskCard`,
  `SalixIM.FeishuTaskCard` and `SalixIM.LarkTaskCard`.
  """

  alias SalixIM.{AgentModelLabel, ConversationMessage, Conversations, ConversationServer}

  import SalixIM.Provider.Util, only: [int_or: 2, str: 1]

  @projection_version 2
  @projections ~w(slack_task_card feishu_task_card lark_task_card)
  @providers ~w(slack feishu lark)
  @lifecycles ~w(active ready_for_review completed failed cancelled escalated)
  @terminal ~w(completed failed cancelled)
  @content_limit 2_500
  @timeline_entry_limit 1_200
  @timeline_details_limit 2
  @timeline_window_limit 3
  @initial_timeline_scan_limit 200

  def projection_version, do: @projection_version
  def lifecycles, do: @lifecycles

  @doc "True for any provider's Task-card projection payload."
  def projection?(payload) when is_map(payload), do: payload["projection"] in @projections
  def projection?(_payload), do: false

  @doc """
  Merge a delivery receipt into the Participant. A quarantined card keeps its
  payload: a late or in-flight write cannot clear the quarantine.
  """
  def merge_participant_receipt(
        %{"payload" => %{"projection" => projection, "blocked_reason" => reason}} = participant,
        _receipt
      )
      when projection in @projections and is_binary(reason) and reason != "",
      do: participant

  def merge_participant_receipt(participant, receipt), do: Map.merge(participant, receipt)

  def participant?(%{
        "actor_type" => "provider",
        "provider" => provider,
        "role_label" => "task_card"
      })
      when provider in @providers,
      do: true

  def participant?(_participant), do: false

  def output_message?(%{"actor_type" => "agent"} = message) do
    str(message["role_label"]) != "delegator" and
      timeline_message?(message)
  end

  def output_message?(_message), do: false

  def timeline_message?(%{"actor_type" => actor_type} = message)
      when actor_type in ["agent", "user", "provider_user"] do
    String.trim(ConversationMessage.text_content(message["content"])) != "" and
      get_in(message, ["metadata", "message_type"]) != "task_command" and
      nonempty_audience?(message["delivery_filter"]) and
      nonempty_audience?(message["mentions"])
  end

  def timeline_message?(_message), do: false

  @doc "The Conversation tail sequence that a new card has already projected."
  def tail_seq(conversation),
    do: max(int_or(conversation["message_tail_seq"] || conversation["message_count"], 0), 0)

  @doc """
  The projection fields of a new card, through the Conversation tail. The
  caller adds the provider address and the card identity.
  """
  def initial_payload(conversation) do
    tail_seq = tail_seq(conversation)

    with {:ok, output} <- initial_output(conversation),
         {:ok, recent_messages} <-
           recent_messages_through(
             conversation["agent_group_id"],
             conversation["conversation_id"],
             tail_seq
           ) do
      {:ok,
       %{
         "title" => title(conversation["title"]),
         "lifecycle" => lifecycle(conversation["status"], "active"),
         "projection_version" => @projection_version,
         "recent_messages" => recent_messages,
         "recent_messages_through_seq" => tail_seq,
         "render_repair_required" => true,
         "output" => output
       }
       |> put_model_label(
         AgentModelLabel.resolve(
           conversation["task_worker_agent_id"],
           task_session_model(conversation)
         )
       )
       |> Map.put("surface_kind", "task_card")}
    end
  end

  @doc """
  Rebuild the recent-message window through the delivery boundary. A missed
  or reordered delivery cannot leave the visible window stale.
  """
  def refresh(
        payload,
        %{"agent_group_id" => group_id, "conversation_id" => conversation_id} = rec
      ) do
    boundary_seq = int_or(rec["message_seq"] || rec["conversation_message_tail_seq"], -1)

    with true <- boundary_seq >= 0,
         {:ok, recent_messages} <-
           recent_messages_through(group_id, conversation_id, boundary_seq) do
      {:ok,
       payload
       |> Map.delete("details")
       |> Map.put("render_repair_required", false)
       |> Map.put("recent_messages", recent_messages)
       |> Map.put("recent_messages_through_seq", boundary_seq)}
    else
      false -> {:error, :invalid_task_card_projection_boundary}
      {:error, _reason} = error -> error
    end
  end

  def refresh(_payload, _rec), do: {:error, :invalid_task_card_projection_boundary}

  @doc "Apply one delivery record to the projection."
  def advance(payload, rec) do
    payload = normalize(payload)
    next_lifecycle = lifecycle(rec["conversation_status"], payload["lifecycle"])
    message_text = rec["message_content"] |> ConversationMessage.text_content() |> String.trim()
    metadata = rec["message_metadata"] || %{}
    recent_messages = append_recent_message(payload["recent_messages"], rec, message_text)

    next_output =
      cond do
        metadata["task_command"] == true ->
          ""

        payload["lifecycle"] in @terminal and next_lifecycle == payload["lifecycle"] ->
          payload["output"]

        rec["source_actor_type"] == "agent" and str(rec["source_role_label"]) != "delegator" and
            message_text != "" ->
          bounded_content(message_text)

        true ->
          payload["output"]
      end

    payload
    |> Map.put("title", title(rec["conversation_title"]))
    |> Map.put("lifecycle", next_lifecycle)
    |> Map.put("recent_messages", recent_messages)
    |> Map.put(
      "recent_messages_through_seq",
      max(
        int_or(payload["recent_messages_through_seq"], 0),
        max(int_or(rec["message_seq"] || rec["conversation_message_tail_seq"], 0), 0)
      )
    )
    |> Map.put("output", next_output)
    |> Map.put("surface_kind", "task_card")
  end

  @doc "Canonical recent-message window: valid entries, unique, ordered and bounded."
  def normalize(payload) do
    recent_messages =
      payload["recent_messages"]
      |> List.wrap()
      |> Enum.map(&normalize_recent_message/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1["seq"])
      |> Enum.sort_by(& &1["seq"])
      |> Enum.take(-@timeline_window_limit)

    payload
    |> Map.delete("details")
    |> Map.put("recent_messages", recent_messages)
    |> Map.put(
      "recent_messages_through_seq",
      max(int_or(payload["recent_messages_through_seq"], 0), 0)
    )
  end

  @doc "Model line and the earlier timeline entries, shown above the output."
  def details(payload) do
    [model_line(payload), timeline_details(payload)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> bounded_content()
  end

  @doc "The newest timeline entry, shown as the card output."
  def output(%{"recent_messages" => [_ | _] = messages}) do
    messages
    |> List.last()
    |> Map.fetch!("text")
    |> timeline_text()
  end

  def output(_payload), do: ""

  @doc "Display status and label for a lifecycle."
  def status("active"), do: {"in_progress", "Work in progress"}
  def status("ready_for_review"), do: {"complete", "Ready for review"}
  def status("completed"), do: {"complete", "Completed"}
  def status("failed"), do: {"error", "Failed"}
  def status("cancelled"), do: {"error", "Cancelled"}
  def status("escalated"), do: {"error", "Needs attention"}

  def title(value),
    do: value |> str() |> String.slice(0, 200) |> then(&if(&1 == "", do: "Task", else: &1))

  def bounded_content(value),
    do: value |> str() |> String.trim() |> String.slice(0, @content_limit)

  def lifecycle(value, fallback),
    do: if(str(value) in @lifecycles, do: str(value), else: fallback)

  defp initial_output(%{"task_public_output_message_id" => message_id} = conversation)
       when is_binary(message_id) do
    case Conversations.get_group_conversation_message(
           conversation["agent_group_id"],
           conversation["conversation_id"],
           message_id
         ) do
      {:ok, message} ->
        {:ok,
         message["content"]
         |> ConversationMessage.text_content()
         |> String.trim()
         |> bounded_content()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initial_output(_conversation), do: {:ok, ""}

  defp recent_messages_through(_group_id, _conversation_id, 0), do: {:ok, []}

  defp recent_messages_through(group_id, conversation_id, boundary_seq)
       when is_integer(boundary_seq) and boundary_seq > 0 do
    case Conversations.list_group_conversation_messages(group_id, conversation_id,
           after_seq: max(boundary_seq - @initial_timeline_scan_limit, 0),
           limit: @initial_timeline_scan_limit
         ) do
      {:ok, messages} ->
        {:ok,
         messages
         |> Enum.filter(&(int_or(&1["seq"], 0) <= boundary_seq))
         |> Enum.filter(&timeline_message?/1)
         |> Enum.take(-@timeline_window_limit)
         |> Enum.map(&recent_message/1)}

      {:error, _reason} = error ->
        error
    end
  end

  defp append_recent_message(recent_messages, rec, text) do
    message = if delivery_timeline_message?(rec, text), do: recent_message(rec, text)

    case message do
      nil ->
        recent_messages

      message ->
        recent_messages
        |> Enum.reject(&(&1["seq"] == message["seq"]))
        |> Kernel.++([message])
        |> Enum.sort_by(& &1["seq"])
        |> Enum.take(-@timeline_window_limit)
    end
  end

  defp recent_message(message) do
    %{
      "seq" => message["seq"],
      "role" => timeline_role(message["actor_type"], message["role_label"]),
      "text" => timeline_text(message["content"])
    }
  end

  defp recent_message(%{"message_seq" => seq} = rec, text)
       when is_integer(seq) and seq > 0 and text != "" do
    %{
      "seq" => seq,
      "role" => timeline_role(rec["source_actor_type"], rec["source_role_label"]),
      "text" => timeline_text(text)
    }
  end

  defp recent_message(_rec, _text), do: nil

  defp normalize_recent_message(%{"seq" => seq, "role" => role, "text" => text})
       when is_integer(seq) and seq > 0 and role in ["Router", "Worker", "User"] and
              is_binary(text) do
    case timeline_text(text) do
      "" -> nil
      text -> %{"seq" => seq, "role" => role, "text" => text}
    end
  end

  defp normalize_recent_message(_message), do: nil

  defp model_line(payload) do
    case str(payload["model_label"]) do
      "" -> ""
      label -> "Model: " <> label
    end
  end

  @doc """
  The Task Session's own model choice (`SalixAgent.ModelChoice`), kept on the
  Worker participant, or nil when the Session follows its Agent.
  """
  def task_session_model(%{
         "agent_group_id" => group_id,
         "conversation_id" => conversation_id,
         "task_worker_agent_id" => agent_id
       })
       when is_binary(agent_id) and agent_id != "" do
    with {:ok, %{"participant_id" => participant_id}} <-
           ConversationServer.get_group_conversation_agent_participant_identity(
             group_id,
             conversation_id,
             agent_id
           ),
         {:ok, participant} <-
           Conversations.get_group_conversation_participant(
             group_id,
             conversation_id,
             participant_id
           ) do
      get_in(participant, ["payload", "session_model"])
    else
      _ -> nil
    end
  end

  def task_session_model(_conversation), do: nil

  defp put_model_label(payload, ""), do: payload
  defp put_model_label(payload, label), do: Map.put(payload, "model_label", label)

  defp timeline_details(%{"recent_messages" => [_ | _] = messages}) do
    messages
    |> Enum.drop(-1)
    |> Enum.take(-@timeline_details_limit)
    |> Enum.map_join("\n\n", &"#{&1["role"]}: #{timeline_detail_text(&1["text"])}")
    |> bounded_content()
  end

  defp timeline_details(_payload), do: ""

  defp timeline_role("agent", "delegator"), do: "Router"
  defp timeline_role("agent", _role), do: "Worker"
  defp timeline_role(actor_type, _role) when actor_type in ["user", "provider_user"], do: "User"
  defp timeline_role(_actor_type, _role), do: "User"

  defp timeline_text(content) do
    content
    |> ConversationMessage.text_content()
    |> String.trim()
  end

  defp timeline_detail_text(content),
    do: content |> timeline_text() |> String.slice(0, @timeline_entry_limit)

  defp delivery_timeline_message?(rec, text) do
    rec["source_actor_type"] in ["agent", "user", "provider_user"] and text != "" and
      get_in(rec, ["message_metadata", "message_type"]) != "task_command"
  end

  defp nonempty_audience?(nil), do: true
  defp nonempty_audience?(%{"participant_ids" => [_ | _]}), do: true
  defp nonempty_audience?(_audience), do: false
end
