defmodule CommaWeb.WeChatLinkWatch do
  @moduledoc """
  Polls one WeChat QR attempt a Router started from the chat
  (`CommaWeb.ChannelLinkTools`), the way the Settings page polls it while it
  is open: every 3 seconds, until the attempt connects (the poll activates it
  and `CommaWeb.WeChatIntegration` tells the waiting Router), WeChat asks for
  a verification code (the Router's call returns so it can ask the user; the
  call that brings the code starts a new watch), or the attempt ends or runs
  out (the Router's call fails). One process per attempt, under
  `CommaWeb.ChannelLinkWatches`; it is not restarted, and an attempt whose
  watcher is lost ends as its request expires.
  """

  use SystemsRuntime.Server
  require Logger

  alias CommaWeb.WeChatIntegration

  @poll_ms 3_000

  def start(attrs) when is_map(attrs) do
    SystemsRuntime.DynamicSupervisor.start_child(
      CommaWeb.ChannelLinkWatches,
      %{id: __MODULE__, start: {__MODULE__, :start_link, [attrs]}, restart: :temporary}
    )
  end

  def start_link(attrs), do: SystemsRuntime.Server.start_link(__MODULE__, attrs)

  @impl true
  def init(attrs) do
    with {:ok, user} <- Comma.Accounts.get_user(attrs.user_id) do
      SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll, @poll_ms)
      # A watch without a code has no :verify_code key, so a code challenge is news.
      attrs = if is_nil(attrs[:verify_code]), do: Map.delete(attrs, :verify_code), else: attrs
      {:ok, Map.merge(attrs, %{user: user, task: nil})}
    else
      _ -> {:stop, :normal}
    end
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    %{user: user, workspace_id: workspace_id, attempt_id: attempt_id} = state
    verify_code = state[:verify_code]

    task =
      SystemsRuntime.Task.async(fn ->
        WeChatIntegration.poll_connect(user, %{}, workspace_id, attempt_id, verify_code)
      end)

    {:noreply, %{state | task: task}}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])
    state = %{state | task: nil}

    case result do
      {:ok, %{"connection_active" => true}} ->
        {:stop, :normal, state}

      {:ok, %{"login_status" => "need_verifycode"}} when not is_map_key(state, :verify_code) ->
        CommaWeb.ChannelLinkTools.verification_code_required(state.waiting, state.attempt_id)
        {:stop, :normal, state}

      {:error, reason}
      when reason in [:wechat_login_expired, :invalid_wechat_connection_attempt] ->
        fail(state, reason)

      _pending_or_transient ->
        if SystemsClock.system_time(:second) >= state.expires_at do
          fail(state, :wechat_login_expired)
        else
          SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll, @poll_ms)
          {:noreply, state}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    Logger.warning("wechat link poll crashed: #{inspect(reason)}")
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll, @poll_ms)
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp fail(state, reason) do
    CommaWeb.ChannelLinkTools.failed(state.waiting, to_string(reason))
    {:stop, :normal, state}
  end
end
