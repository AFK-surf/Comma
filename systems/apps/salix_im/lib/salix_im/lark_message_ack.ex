defmodule SalixIM.LarkMessageAck do
  @moduledoc """
  Marks a delivered Feishu or Lark message for the bot with the `OnIt`
  reaction at ingress.

  Feishu and Lark show nothing while a message waits for the Router's turn,
  so a message queued behind other work looked unanswered for minutes. The
  reaction is added as soon as ingress has handed the message on, off the
  callback process, and never affects delivery. Only a message addressed to
  the bot is marked: one of a private chat, or one that mentions the bot. A
  thread reply that does not mention the bot is not marked.
  """

  require Logger

  alias SalixIM.Provider.{Feishu, Lark}

  import SalixIM.Provider.Util, only: [str: 1]

  @task_supervisor SalixIM.LarkMessageAckTasks
  @emoji_type "OnIt"

  @spec acknowledge(:feishu | :lark, map(), term()) :: :ok
  def acknowledge(provider, connect, message_id)
      when provider in [:feishu, :lark] and is_map(connect) do
    message_id = str(message_id)

    if message_id != "" do
      case SystemsRuntime.TaskSupervisor.start_child(@task_supervisor, fn ->
             add_reaction(provider, connect, message_id)
           end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("#{provider} message ack not started: #{inspect(reason)}")
      end
    end

    :ok
  catch
    :exit, reason ->
      Logger.warning("#{provider} message ack not started: #{inspect(reason)}")
      :ok
  end

  def acknowledge(_provider, _connect, _message_id), do: :ok

  defp add_reaction(provider, connect, message_id) do
    {module, api} =
      case provider do
        :feishu -> {Feishu, "feishu.add_reaction"}
        :lark -> {Lark, "lark.add_reaction"}
      end

    case module.call(nil, connect, api, %{"message_id" => message_id, "emoji_type" => @emoji_type}) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("#{provider} message ack failed: #{inspect(reason)}")
    end
  end
end
