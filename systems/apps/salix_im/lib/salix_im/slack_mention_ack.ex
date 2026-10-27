defmodule SalixIM.SlackMentionAck do
  @moduledoc """
  Marks a delivered Slack @-mention with :eyes: at ingress.

  Slack shows "is thinking..." only once the Router's turn starts, so a
  mention queued behind other work looked unanswered for minutes. The
  reaction is sent as soon as ingress has handed the message on, off the
  callback process, and never affects delivery. Messages that do not mention
  the app (thread replies, DMs) are not marked.
  """

  require Logger

  alias SalixIM.Provider.Slack

  import SalixIM.Provider.Util, only: [str: 1]

  @task_supervisor SalixIM.SlackMentionAckTasks
  @reaction "eyes"
  @request_options [timeout_ms: 4_000, pool_retries: 0]

  def acknowledge(connect, channel_id, message_ts) when is_map(connect) do
    channel_id = str(channel_id)
    message_ts = str(message_ts)

    if channel_id != "" and message_ts != "" do
      case SystemsRuntime.TaskSupervisor.start_child(@task_supervisor, fn ->
             add_reaction(connect, channel_id, message_ts)
           end) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("slack mention ack not started: #{inspect(reason)}")
      end
    end

    :ok
  catch
    :exit, reason ->
      Logger.warning("slack mention ack not started: #{inspect(reason)}")
      :ok
  end

  def acknowledge(_connect, _channel_id, _message_ts), do: :ok

  defp add_reaction(connect, channel_id, message_ts) do
    case Slack.call(
           nil,
           connect["tenant_id"],
           connect,
           "slack.add_reaction",
           %{"channel" => channel_id, "ts" => message_ts, "name" => @reaction},
           request_options: @request_options
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> Logger.warning("slack mention ack failed: #{inspect(reason)}")
    end
  end
end
