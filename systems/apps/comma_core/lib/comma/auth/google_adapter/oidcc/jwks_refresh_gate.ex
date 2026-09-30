defmodule Comma.Auth.GoogleAdapter.Oidcc.JwksRefreshGate do
  @moduledoc """
  Bounds on-demand OIDC JWKS refreshes behind one adapter-wide cooldown.

  The gate intentionally keeps no per-`kid` state: attacker-controlled key IDs
  cannot create unbounded buckets, and concurrent callers share the current
  provider JWKS after at most one network refresh.
  """

  use GenServer

  alias Oidcc.ProviderConfiguration.Worker

  @default_cooldown_ms 30_000

  @type refresh_result :: {:ok, %JOSE.JWK{}} | {:error, :google_provider_unavailable}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec refresh(GenServer.server(), binary(), GenServer.server()) :: refresh_result()
  def refresh(provider, kid, server \\ __MODULE__)
      when is_binary(kid) and kid != "" do
    GenServer.call(server, {:refresh, provider, kid})
  catch
    :exit, _reason -> {:error, :google_provider_unavailable}
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       cooldown_ms: cooldown_ms(opts),
       next_refresh_at: nil
     }}
  end

  @impl true
  def handle_call({:refresh, provider, kid}, _from, state) do
    now = state.clock.()

    if refresh_allowed?(state.next_refresh_at, now) do
      result = refresh_and_read(provider, kid)
      next_refresh_at = state.clock.() + state.cooldown_ms
      {:reply, result, %{state | next_refresh_at: next_refresh_at}}
    else
      {:reply, read_jwks(provider), state}
    end
  end

  defp refresh_allowed?(nil, _now), do: true
  defp refresh_allowed?(next_refresh_at, now), do: now >= next_refresh_at

  defp refresh_and_read(provider, kid) do
    :ok = Worker.refresh_jwks_for_unknown_kid(provider, kid)
    read_jwks(provider)
  rescue
    _exception -> {:error, :google_provider_unavailable}
  catch
    :exit, _reason -> {:error, :google_provider_unavailable}
  end

  defp read_jwks(provider) do
    case Worker.get_jwks(provider) do
      %JOSE.JWK{} = jwks -> {:ok, jwks}
      _other -> {:error, :google_provider_unavailable}
    end
  rescue
    _exception -> {:error, :google_provider_unavailable}
  catch
    :exit, _reason -> {:error, :google_provider_unavailable}
  end

  defp cooldown_ms(opts) do
    case Keyword.get(opts, :cooldown_ms, @default_cooldown_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_cooldown_ms
    end
  end
end
