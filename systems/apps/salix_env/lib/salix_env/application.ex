defmodule SalixEnv.Application do
  @moduledoc """
  Remote-environment and transfer supervision. Starts the
  one-time-token registry and the mandatory transfer listener. The listener is
  mandatory on every node; the node fails to start if the bind fails, with no
  NATS fallback for body bytes.

  Connector bridge registries and managed cloud-VM carriers share this
  supervision tree with the cross-node byte-streaming substrate.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SalixEnv.Transfer.Tokens,
      {SalixEnv.ComputeReconciler,
       interval_ms: Application.get_env(:salix_env, :compute_reconcile_interval_ms, 5_000),
       start_sweeper?: Application.get_env(:salix_env, :compute_reconciler_start_sweeper?, true)},
      # Ephemeral per-node last-exec labels merged into device projections.
      SalixEnv.ExecActivity,
      # Per-node connector-socket directory: one entry per env_id whose
      # WebSocket is bridged on THIS node (SalixEnv.Bridge round trips through it).
      {Registry, keys: :unique, name: SalixEnv.Bridge.registry()},
      {Task.Supervisor,
       name: SalixEnv.ConnectorRemoteReadTaskSupervisor,
       max_children: connector_remote_read_stream_limit()},
      {Registry, keys: :unique, name: SalixEnv.VM.Providers.Cloudflare.AttachmentRegistry},
      SalixEnv.VM.Providers.Cloudflare.Attachments,
      {Bandit,
       plug: SalixEnv.Transfer.Server,
       port: SalixEnv.Transfer.port(),
       startup_log: false,
       http_options: [log_exceptions_with_status_codes: [], log_protocol_errors: false]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SalixEnv.Supervisor)
  end

  defp connector_remote_read_stream_limit do
    case Application.get_env(:salix_env, :connector_remote_read_stream_limit, 32) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 32
    end
  end
end
