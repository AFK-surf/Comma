defmodule SalixIM.LarkBotMenu do
  @moduledoc """
  A tap on the custom menu of a Feishu or Lark bot
  (`application.bot.menu_v6`).

  An app admin sets the menu of a bot in the developer console, and gives
  each item an `event_key`. A tap in a person's private chat with the bot
  sends this event. It names the person and the key, and no chat or message.

  `parse/3` makes the Router input of a tap, for `SalixIM.ProviderHTTP`
  (Feishu) and `SalixIM.LarkInbound` (Lark):

    * `status`, `compact`, `help` (and any other key that
      `SalixIM.ControlCommand` reads as a command) run that control command.
      The answer goes to the person in a private message
      (`ControlCommand` replies to `sender_open_id` when a `p2p` event names
      no chat).
    * `newgpttask` and `newclaudetask` ask the Router to create a task with a
      Codex or Claude worker. Text after the key (`newgpttask: <task>` or
      `newgpttask <task>`) is the task; without it the Router asks the person
      what to create.
    * Any other key is the person's request to act on that key.

  The receipt of a tap is `menu:<event_id>`, and its source message ID is
  `im_provider:<provider>:<connect_id>:menu:<event_id>`.
  """

  alias SalixIM.{ControlCommand, ProviderRecipientIdentity}

  @workers %{"newgpttask" => "Codex", "newclaudetask" => "Claude"}

  @type t :: %{
          event_id: String.t(),
          receipt: String.t(),
          source_message_id: String.t(),
          open_id: String.t(),
          union_id: String.t(),
          user_id: String.t(),
          event_key: String.t(),
          content: String.t(),
          trusted_source_text: String.t(),
          command_text: String.t() | nil,
          metadata: map()
        }

  @doc "The event type of a tap on a bot's menu."
  @spec event_type() :: String.t()
  def event_type, do: "application.bot.menu_v6"

  @doc "The open_id of the person who tapped, or `\"\"`."
  @spec operator_open_id(map()) :: String.t()
  def operator_open_id(envelope) when is_map(envelope) do
    envelope |> map("event") |> map("operator") |> ids() |> Map.fetch!("open_id")
  end

  def operator_open_id(_envelope), do: ""

  @doc """
  The Router input of a tap for `provider` (`"feishu"` or `"lark"`), or
  `{:error, :invalid_envelope}` when the event names no event, key or person.
  """
  @spec parse(String.t(), map(), map()) :: {:ok, t()} | {:error, :invalid_envelope}
  def parse(provider, connect, envelope)
      when provider in ["feishu", "lark"] and is_map(connect) and is_map(envelope) do
    header = map(envelope, "header")
    event = map(envelope, "event")
    operator = map(event, "operator")
    ids = ids(operator)
    event_id = text(header["event_id"])
    event_key = text(event["event_key"])
    open_id = ids["open_id"]

    if event_id == "" or event_key == "" or open_id == "" do
      {:error, :invalid_envelope}
    else
      source_message_id = "im_provider:#{provider}:#{connect["connect_id"]}:menu:#{event_id}"
      {request, command_text} = request(provider, event_key, open_id)

      metadata =
        %{
          "provider" => provider,
          "connect_id" => connect["connect_id"],
          "app_name" => text(connect["app_name"]),
          "tenant_key" => first_present([header["tenant_key"], connect["tenant_key"]]),
          "chat_type" => "p2p",
          "sender_open_id" => open_id,
          "sender_union_id" => ids["union_id"],
          "sender_user_id" => ids["user_id"],
          "sender_name" => text(operator["operator_name"]),
          "sender_type" => "user",
          "bot_mentioned" => true,
          "event_type" => "#{provider}.bot_menu",
          "menu_event_key" => event_key,
          "source_sent_at_ms" => sent_at_ms(event["timestamp"] || header["create_time"]),
          "source_actor_type" => "provider_user"
        }
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
        |> Map.new()
        |> ProviderRecipientIdentity.put(connect)

      {:ok,
       %{
         event_id: event_id,
         receipt: "menu:" <> event_id,
         source_message_id: source_message_id,
         open_id: open_id,
         union_id: ids["union_id"],
         user_id: ids["user_id"],
         event_key: event_key,
         content: "#{label(provider)} bot menu tap from #{open_id}:\n" <> request,
         trusted_source_text: request,
         command_text: command_text,
         metadata: metadata
       }}
    end
  end

  def parse(_provider, _connect, _envelope), do: {:error, :invalid_envelope}

  # The request a key stands for, and the command text when it is a control
  # command.
  defp request(provider, event_key, open_id) do
    key = event_key |> String.trim_leading("/") |> String.trim()
    command = "<salix-command>" <> key <> "</salix-command>"

    cond do
      match?({:ok, _}, ControlCommand.parse(command)) ->
        {"/" <> key, command}

      task = task_command(key) ->
        {task_request(provider, task, open_id), nil}

      true ->
        {"The user tapped the custom menu item #{inspect(event_key)} of this bot in their " <>
           "private chat with it. Act on it as their request. #{reply_hint(provider, open_id)}",
         nil}
    end
  end

  defp task_command(key) do
    case Regex.run(~r/\A(newgpttask|newclaudetask)(?:[:\s]\s*(.*))?\z/si, key) do
      [_all, name | rest] -> {Map.fetch!(@workers, String.downcase(name)), text(Enum.at(rest, 0))}
      nil -> nil
    end
  end

  defp task_request(provider, {worker, ""}, open_id),
    do:
      "The user tapped the menu item to create a #{worker} task in their private chat with this bot. " <>
        "Ask them briefly what task to create. #{reply_hint(provider, open_id)} " <>
        "When they answer, create the task using a #{worker} worker."

  defp task_request(_provider, {worker, content}, open_id),
    do:
      "Create a task using a #{worker} worker and send the task link to #{open_id} " <>
        "via direct message. Task content: " <> content

  defp reply_hint(provider, open_id),
    do:
      "This tap names no chat: send your reply with #{provider}.send_message, " <>
        "user_id #{inspect(open_id)} and user_id_type \"open_id\"."

  defp label("feishu"), do: "Feishu"
  defp label("lark"), do: "Lark"

  # The person who tapped. Lark sends `operator.operator_id`; an older shape
  # puts the IDs on `operator` itself.
  defp ids(operator) do
    nested = map(operator, "operator_id")

    Map.new(~w(open_id union_id user_id), fn key ->
      {key, first_present([nested[key], operator[key]])}
    end)
  end

  # Lark sends the time of a tap in seconds or milliseconds, as a number or a
  # string of digits.
  defp sent_at_ms(value) when is_integer(value) and value > 0,
    do: if(value < 10_000_000_000, do: value * 1000, else: value)

  defp sent_at_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> sent_at_ms(number)
      _other -> nil
    end
  end

  defp sent_at_ms(_value), do: nil

  defp first_present(values), do: values |> Enum.map(&text/1) |> Enum.find("", &(&1 != ""))

  defp map(value, key) when is_map(value) do
    case value[key] do
      %{} = nested -> nested
      _other -> %{}
    end
  end

  defp map(_value, _key), do: %{}

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
