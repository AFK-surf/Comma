defmodule SalixIM.PrivateChatStatus do
  @moduledoc """
  Best-effort, source-scoped Telegram, WeChat and Signal activity. Runs outside inbound delivery;
  presentation failure must never turn accepted input into a webhook retry.
  """

  alias SalixIM.{ProviderConnects, PrivateChatStatusActor, PrivateChatStatusPlacement}

  @task_supervisor SalixIM.PrivateChatStatusTaskSupervisor

  def enabled?, do: Application.get_env(:salix_im, :private_chat_status, true) != false

  def record_inbound(group_id, metadata, source_id, agent_id, session_id) do
    if enabled?() and private_source?(metadata) do
      dispatch(fn ->
        start_projection(group_id, metadata, source_id, agent_id, session_id)
      end)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp private_source?(%{"provider" => "wechat", "wechat_id" => peer}),
    do: is_binary(peer) and peer != ""

  defp private_source?(metadata),
    do: metadata["provider"] in ["telegram", "signal"] and metadata["chat_type"] == "private"

  defp start_projection(group_id, metadata, source_id, agent_id, session_id) do
    with {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             group_id,
             metadata["connect_id"],
             metadata["provider"]
           ),
         true <- managed_surface?(connect),
         {:ok, pid} <-
           PrivateChatStatusPlacement.ensure_started(agent_id, connect, metadata) do
      PrivateChatStatusActor.activate(pid, source_id, session_id)
    else
      false -> :ignored
      _ -> :dropped
    end
  end

  # Comma owns the Telegram and WeChat connects it presents. A Signal connect is
  # the Group's own; its peer binding authorizes the surface
  # (`SalixIM.SignalStatusTransport`).
  defp managed_surface?(%{"provider" => "signal"}), do: true
  defp managed_surface?(connect), do: connect["managed_by"] == "comma_product"

  # Telegram clears native status when a reply lands. The actor continues to
  # read Session Activity because a reply does not establish completion.
  def provider_reply_sent(agent_id, connect, params) do
    if enabled?() and connect["managed_by"] == "comma_product" do
      dispatch(fn ->
        target = %{
          "chat_type" => "private",
          "chat_id" => to_string(params["chat_id"]),
          "message_thread_id" => to_string(params["message_thread_id"])
        }

        with {:ok, pid} <- PrivateChatStatusPlacement.ensure_started(agent_id, connect, target) do
          PrivateChatStatusActor.reply_sent(pid)
        else
          _ -> :dropped
        end
      end)
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp dispatch(fun) do
    context = SystemsObservability.Context.capture()

    case Task.Supervisor.start_child(@task_supervisor, fn ->
           SystemsObservability.Context.run(context, fn -> guarded(fun) end)
         end) do
      {:ok, _} -> :ok
      _ -> observe_dispatch(:dropped)
    end
  rescue
    _ -> observe_dispatch(:dropped)
  catch
    _, _ -> observe_dispatch(:dropped)
  end

  defp guarded(fun) do
    case fun.() do
      :ok -> observe_dispatch(:dispatched)
      :ignored -> observe_dispatch(:ignored)
      _ -> observe_dispatch(:dropped)
    end
  rescue
    _ -> observe_dispatch(:dropped)
  catch
    _, _ -> observe_dispatch(:dropped)
  end

  defp observe_dispatch(outcome) do
    :telemetry.execute([:salix, :operation, :stop], %{duration: 0}, %{
      component: "salix_im",
      operation: "private_chat_status_start",
      surface: "comma",
      outcome: outcome
    })
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def ensure_local(agent_id, connect, metadata) do
    key = PrivateChatStatusActor.key(connect, metadata)

    case Registry.lookup(SalixIM.PrivateChatStatusRegistry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               SalixIM.PrivateChatStatusFleetSup,
               {PrivateChatStatusActor, agent_id: agent_id, connect: connect, metadata: metadata}
             ) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end
end
