defmodule SalixIM.SlackRouterStatus do
  @moduledoc false

  require Logger

  alias SalixIM.SlackRouterStatusActor
  alias SalixIM.SlackRouterStatusPlacement
  alias SalixStore.{CasRecord, Keys}

  import SalixIM.Provider.Util, only: [str: 1]

  @task_supervisor SalixIM.SlackRouterStatusTaskSupervisor

  def record_router_inbound(connect, message, router_agent_id, session_id) when is_map(connect) do
    dispatch("router inbound", fn ->
      start_and_cast(connect, router_agent_id, session_id, fn pid ->
        SlackRouterStatusActor.activate(pid, connect, message, router_agent_id, session_id)
      end)
    end)
  end

  def record_router_inbound(_connect, _message, _router_agent_id, _session_id), do: :ok

  def record_conversation_inbound(connect, message, worker_agent, conversation_id)
      when is_map(connect) and is_map(worker_agent) do
    worker_agent_id = str(worker_agent["agent_id"])

    dispatch("conversation inbound", fn ->
      start_and_cast(connect, worker_agent_id, conversation_id, fn pid ->
        SlackRouterStatusActor.activate_conversation(
          pid,
          connect,
          message,
          worker_agent_id,
          conversation_id
        )
      end)
    end)
  end

  def record_conversation_inbound(_connect, _message, _worker_agent, _conversation_id), do: :ok

  def provider_reply_sent(connect_id, channel_id, thread_ts) do
    connect_id = str(connect_id)
    channel_id = str(channel_id)
    thread_ts = str(thread_ts)

    if connect_id != "" and channel_id != "" and thread_ts != "" do
      dispatch("provider reply", fn ->
        with {:ok, window} <- CasRecord.get(window_key(connect_id)),
             owner_agent_id when owner_agent_id != "" <- str(window["agent_id"]),
             {:ok, pid} <- SlackRouterStatusPlacement.ensure_started(owner_agent_id, connect_id) do
          SlackRouterStatusActor.provider_reply_sent(pid, channel_id, thread_ts)
        else
          {:error, :not_found} -> :ok
          reason -> Logger.warning("slack status provider reply skipped: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  def ensure_actor_local(connect_id, owner_agent_id \\ nil) do
    connect_id = str(connect_id)

    if connect_id == "",
      do: {:error, :connect_id_required},
      else: start_actor(connect_id, owner_agent_id)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp start_and_cast(connect, owner_agent_id, source_id, fun) do
    connect_id = str(connect["connect_id"])
    owner_agent_id = str(owner_agent_id)
    source_id = str(source_id)

    if connect_id == "" or owner_agent_id == "" or source_id == "" do
      Logger.warning("slack status inbound ignored: missing window identity")
    else
      case SlackRouterStatusPlacement.ensure_started(owner_agent_id, connect_id) do
        {:ok, pid} -> fun.(pid)
        {:error, reason} -> Logger.warning("slack status actor unavailable: #{inspect(reason)}")
      end
    end
  end

  defp start_actor(connect_id, owner_agent_id) do
    case Registry.lookup(
           SalixIM.SlackRouterStatusRegistry,
           SlackRouterStatusActor.key(connect_id)
         ) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               SalixIM.SlackRouterStatusFleetSup,
               {SlackRouterStatusActor,
                connect_id: connect_id, owner_agent_id: str(owner_agent_id)}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp dispatch(label, fun) do
    if Process.whereis(@task_supervisor) do
      case Task.Supervisor.start_child(@task_supervisor, fn -> run(label, fun) end) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.warning("slack status #{label} not dispatched: #{inspect(reason)}")
      end
    end

    :ok
  catch
    :exit, reason ->
      Logger.warning("slack status #{label} not dispatched: #{inspect(reason)}")
      :ok
  end

  defp run(label, fun) do
    fun.()
  rescue
    error -> Logger.warning("slack status #{label} failed: #{Exception.message(error)}")
  catch
    kind, reason -> Logger.warning("slack status #{label} failed: #{inspect({kind, reason})}")
  end

  defp window_key(connect_id), do: Keys.ctl_im_slack_router_status_window(connect_id)
end
