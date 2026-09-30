defmodule SalixSignal.CallMedia do
  @moduledoc """
  1:1 call media (CRS-13): relay credentials (`Relays`), one media
  connection per remote device (`Connection`), the Opus codec (`Opus`), the
  receive jitter buffer (`JitterBuffer`) and the bridge to the voice call
  core (`SalixSignal.Carrier`).

  The call-signaling layer (CRS-12) starts connections here and carries
  their parameters and ICE candidates in call messages.
  """

  alias SalixSignal.CallMedia.Connection
  alias SalixSignal.CallMedia.TLSRelay

  @doc """
  Starts a media connection under `SalixSignal.CallMedia.Supervisor` on this
  node. See `SalixSignal.CallMedia.Connection.start_link/1` for options.
  """
  @spec start_connection(keyword() | map()) :: DynamicSupervisor.on_start_child()
  def start_connection(opts) do
    opts = Map.new(opts)

    with {:ok, servers, relay} <- prepare_relay(opts) do
      opts = Map.merge(opts, %{ice_servers: servers, tls_relay: relay, relay_only: relay != nil})

      case DynamicSupervisor.start_child(SalixSignal.CallMedia.Supervisor, {Connection, opts}) do
        {:ok, _} = result ->
          result

        error ->
          TLSRelay.stop(relay)
          error
      end
    end
  end

  # Direct connections without a relay are used by local protocol tests.
  defp prepare_relay(%{ice_servers: [], relay_only: false}), do: {:ok, [], nil}

  defp prepare_relay(opts),
    do: TLSRelay.prepare(opts[:ice_servers] || [], opts[:turn_tls] || [])
end
