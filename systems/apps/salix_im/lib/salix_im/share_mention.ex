defmodule SalixIM.ShareMention do
  @moduledoc """
  A person's message to the Group's Router that names people of their People
  for a shared task (`[name](comma:share/<user id>)`: the composer's @ shared
  task mention) starts one shared task with all of them, the rest of the
  message its first message, without the Router's turn
  (`SalixIM.Ports.Collaborations`, owned by the product). Each person named is
  invited to it as from People.

  As for a model mention (`SalixIM.ModelMentionTask`), the committed message
  is delivered to no participant and is the at-most-once receipt: one shared
  task per message. It carries words only: files the message attached stay in
  the Router chat, and the answer says so. A message that also names people
  for Task requests starts nothing and sends nothing: the answer asks for two
  messages, so no half of it runs.

  The Router then answers in the chat with the Task and is told that it
  started and with whom, never its words: no Router reads a shared task.
  """

  require Logger

  alias SalixIM.{ConversationMessage, ModelMentionTask}
  alias SalixIM.Ports.Collaborations

  @mention ~r/\[([^\]\n]{1,200})\]\(comma:share\/([A-Za-z0-9][A-Za-z0-9_-]{0,127})\)/u
  @request ~r/\[([^\]\n]{1,200})\]\(comma:request\/([A-Za-z0-9][A-Za-z0-9_-]{0,127})\)/u
  @upload ~r/\(workspace file: \/uploads\/[^)]+\)/

  @type person :: %{id: String.t(), name: String.t()}
  @type mention :: %{
          people: [person(), ...],
          text: String.t(),
          files: non_neg_integer(),
          requests: non_neg_integer()
        }

  @doc """
  The people a message names for a shared task, in order and each once, their
  names as written, the text without the mentions (request mentions too), how
  many files the message carries and how many request mentions it has.
  `:none` when it names nobody for a shared task.
  """
  @spec parse(String.t(), term()) :: {:ok, mention()} | :none
  def parse(text, content \\ nil)

  def parse(text, content) when is_binary(text) do
    case Regex.scan(@mention, text) do
      [] ->
        :none

      found ->
        rest =
          text
          |> String.replace(@mention, "")
          |> String.replace(@request, "")
          |> String.trim()

        uploads = length(Regex.scan(@upload, rest))

        {:ok,
         %{
           people:
             found
             |> Enum.map(fn [_whole, name, id] -> %{id: id, name: String.trim(name)} end)
             |> Enum.uniq_by(& &1.id),
           text: rest |> String.replace(@upload, "") |> String.trim(),
           files: uploads + length(ConversationMessage.local_file_refs(content)),
           requests: length(Regex.scan(@request, text))
         }}
    end
  end

  def parse(_text, _content), do: :none

  @doc """
  Starts the shared task the committed message `message_id` of `user_id` asks
  for in the Router conversation `conversation`, and answers in it.
  """
  @spec start(String.t(), map(), String.t(), String.t() | nil, mention()) :: :ok
  def start(group_id, conversation, message_id, user_id, mention) do
    {reply, context} =
      cond do
        mention.requests > 0 ->
          {[
             text(
               "A collaboration and requests cannot share a message: nothing was started or sent. " <>
                 "Send them as two messages."
             )
           ], nil}

        mention.text == "" ->
          {[text("Write what to work on with #{names(mention.people)} after the names.")], nil}

        true ->
          group_id
          |> deliver(conversation, message_id, user_id, mention)
          |> answer(mention)
      end

    ModelMentionTask.answer(
      group_id,
      conversation["conversation_id"],
      conversation["router_agent_id"],
      "share-mention:" <> message_id,
      reply
    )

    if context,
      do:
        ModelMentionTask.tell_router(
          group_id,
          "share-mention:" <> message_id,
          context,
          "shared_task"
        )

    :ok
  end

  defp deliver(group_id, conversation, message_id, user_id, mention)
       when is_binary(user_id) and user_id not in ["", "current"] do
    Collaborations.start_from_router(
      group_id,
      user_id,
      Enum.map(mention.people, & &1.id),
      mention.text,
      key(conversation["conversation_id"], message_id)
    )
  end

  defp deliver(_group_id, _conversation, _message_id, _user_id, _mention),
    do: {:error, :host_unknown}

  defp answer({:ok, %{"task_id" => task_id} = task}, mention) do
    ref =
      %{
        "type" => "conversation_ref",
        "conversation_id" => task_id,
        "kind" => "agent_task",
        "presentation" => "inline"
      }
      |> then(fn block ->
        case task["group_id"] do
          group_id when is_binary(group_id) and group_id != "" ->
            Map.put(block, "group_id", group_id)

          _ ->
            block
        end
      end)

    {[
       text(
         "Started a collaboration with #{names(mention.people)}. " <>
           "They are invited to it in their Inbox." <> files_note(mention)
       ),
       ref
     ],
     "The person started a collaboration with #{names(mention.people)} directly from Home " <>
       "(conversation #{task_id}), so you were not asked. You cannot read it: what is said in it " <>
       "belongs to its people. This is context only, not a request."}
  end

  defp answer({:error, reason}, mention) do
    Logger.info("salix shared task from Home not started reason=#{inspect(reason)}")

    {[text("Could not start a collaboration with #{names(mention.people)}: #{refusal(reason)}")],
     nil}
  end

  # One shared task per message, whatever its ids look like (a request id
  # takes letters, digits, `_` and `-`).
  defp key(conversation_id, message_id) do
    "router-share-" <>
      (:crypto.hash(:sha256, "#{conversation_id}\n#{message_id}")
       |> Base.url_encode64(padding: false))
  end

  defp text(words), do: %{"type" => "text", "text" => words}

  defp names([%{name: name}]), do: name

  defp names(people) do
    {init, [last]} = people |> Enum.map(& &1.name) |> Enum.split(-1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp files_note(%{files: 0}), do: ""
  defp files_note(%{files: 1}), do: " It carries words only: the file stays here."
  defp files_note(%{files: count}), do: " It carries words only: the #{count} files stay here."

  defp refusal(:billing_unavailable), do: "not enough credits."

  defp refusal(reason) when reason in [:forbidden, :host_unknown],
    do: "only the Workspace's owner can start one from here."

  defp refusal(reason) when reason in [:not_found, :not_contact],
    do: "they are no longer among your People."

  defp refusal(_reason), do: "try again shortly."
end
