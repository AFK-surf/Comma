defmodule SalixIM.RequestMention do
  @moduledoc """
  A person's message to the Group's Router that names people they may ask
  for Tasks (`[name](comma:request/<grant id>)`: the composer's @ request
  mention) sends each of them the rest of the message as a Task request of
  their own, without the Router's turn (`SalixIM.Ports.TaskRequests`, owned
  by the product). Each recipient decides alone and, accepting, makes a Task
  in their own Workspace.

  As for a model mention (`SalixIM.ModelMentionTask`), the committed message
  is delivered to no participant and is the at-most-once receipt: each
  request is sent once per message. A request carries words only: files the
  message attached stay in the Router chat, and the answer says so.

  The Router then answers in the chat whom the request went to and whom it
  did not, and is told what happened without a round of its own (`no_wake`).
  """

  alias SalixIM.{ConversationMessage, ModelMentionTask}
  alias SalixIM.Ports.TaskRequests

  @mention ~r/\[([^\]\n]{1,200})\]\(comma:request\/([A-Za-z0-9][A-Za-z0-9_-]{0,127})\)/u
  @upload ~r/\(workspace file: \/uploads\/[^)]+\)/

  @type recipient :: %{grant: String.t(), name: String.t()}
  @type mention :: %{
          recipients: [recipient(), ...],
          text: String.t(),
          files: non_neg_integer()
        }

  @doc """
  The people a message names, in order and each once (by grant), their names
  as written, the text without the request mentions and how many files the
  message carries. `:none` when it names nobody.
  """
  @spec parse(String.t(), term()) :: {:ok, mention()} | :none
  def parse(text, content \\ nil)

  def parse(text, content) when is_binary(text) do
    case Regex.scan(@mention, text) do
      [] ->
        :none

      found ->
        rest = text |> String.replace(@mention, "") |> String.trim()
        uploads = length(Regex.scan(@upload, rest))

        {:ok,
         %{
           recipients:
             found
             |> Enum.map(fn [_whole, name, grant] -> %{grant: grant, name: String.trim(name)} end)
             |> Enum.uniq_by(& &1.grant),
           text: rest |> String.replace(@upload, "") |> String.trim(),
           files: uploads + length(ConversationMessage.local_file_refs(content))
         }}
    end
  end

  def parse(_text, _content), do: :none

  @doc """
  Sends the requests the committed message `message_id` of `user_id` asks for
  in the Router conversation `conversation`, one to each person it names, and
  answers in it.
  """
  @spec send_request(String.t(), map(), String.t(), String.t() | nil, mention()) :: :ok
  def send_request(group_id, conversation, message_id, user_id, mention) do
    {reply, context} =
      if mention.text == "" do
        {"Write what you are asking #{names(mention.recipients)} for after the names.", nil}
      else
        mention.recipients
        |> Enum.map(&{&1, deliver(group_id, conversation, message_id, user_id, mention, &1)})
        |> answer(mention)
      end

    ModelMentionTask.answer(
      group_id,
      conversation["conversation_id"],
      conversation["router_agent_id"],
      "request-mention:" <> message_id,
      [%{"type" => "text", "text" => reply}]
    )

    if context,
      do:
        ModelMentionTask.tell_router(
          group_id,
          "request-mention:" <> message_id,
          context,
          "task_request"
        )

    :ok
  end

  defp deliver(group_id, conversation, message_id, user_id, mention, recipient)
       when is_binary(user_id) and user_id not in ["", "current"] do
    TaskRequests.send_from_router(
      group_id,
      user_id,
      recipient.grant,
      mention.text,
      key(conversation["conversation_id"], message_id, recipient.grant)
    )
  end

  defp deliver(_group_id, _conversation, _message_id, _user_id, _mention, _recipient),
    do: {:error, :requester_unknown}

  # What went and what did not, for the person; what went, for the Router.
  defp answer(results, mention) do
    sent = for {recipient, {:ok, sent}} <- results, do: {recipient, sent}
    refused = for {recipient, {:error, reason}} <- results, do: {recipient, reason}

    went =
      case sent do
        [] ->
          ""

        _ ->
          "Sent the request to #{names(Enum.map(sent, &elem(&1, 0)))}. " <>
            if(length(sent) == 1,
              do: "They decide whether and how it runs.",
              else: "Each decides alone whether and how it runs."
            ) <> accepted_note(sent) <> files_note(mention)
      end

    not_went =
      Enum.map_join(refused, " ", fn {recipient, reason} ->
        "Could not send it to #{recipient.name}: #{refusal(reason)}"
      end)

    reply = [went, not_went] |> Enum.reject(&(&1 == "")) |> Enum.join(" ")

    context =
      if sent != [],
        do:
          "The person sent #{names(Enum.map(sent, &elem(&1, 0)))} a Task request directly from Home by naming them, " <>
            "so you were not asked: \"#{mention.text}\". Each recipient decides whether it runs. " <>
            "This is context only, not a request."

    {reply, context}
  end

  # One request per message and person, whatever their ids look like.
  defp key(conversation_id, message_id, grant) do
    "router-mention:" <>
      (:crypto.hash(:sha256, "#{conversation_id}\n#{message_id}\n#{grant}")
       |> Base.url_encode64(padding: false))
  end

  defp names([%{name: name}]), do: name

  defp names(recipients) do
    {init, [last]} = recipients |> Enum.map(& &1.name) |> Enum.split(-1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp accepted_note(sent) do
    case for({recipient, %{"status" => "accepted"}} <- sent, do: recipient) do
      [] -> ""
      [one] -> " #{one.name} accepts requests automatically: it is a Task now."
      auto -> " #{names(auto)} accept requests automatically: theirs are Tasks now."
    end
  end

  defp files_note(%{files: 0}), do: ""
  defp files_note(%{files: 1}), do: " A request carries words only: the file stays here."

  defp files_note(%{files: count}),
    do: " A request carries words only: the #{count} files stay here."

  defp refusal(:task_request_daily_limit), do: "you have sent them all you may today."
  defp refusal(:task_request_pending_limit), do: "too many of your requests to them still wait."

  defp refusal(reason) when reason in [:not_found, :no_grant],
    do: "you may no longer send them requests."

  defp refusal(:requester_unknown), do: "only the Workspace's owner can send requests from here."
  defp refusal(_reason), do: "try again shortly."
end
