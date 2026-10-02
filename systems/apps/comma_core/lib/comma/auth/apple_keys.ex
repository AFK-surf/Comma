defmodule Comma.Auth.AppleKeys do
  @moduledoc """
  Shared, bounded cache of Apple's official Sign in with Apple public keys.

  JOSE verifies the signature; Apple controls the expected key through its
  HTTPS endpoint. Token headers cannot select another URL or algorithm.
  Missing or unavailable keys deny login instead of trusting client claims.
  """
  use GenServer

  @url "https://appleid.apple.com/auth/keys"
  @ttl_ms 3_600_000
  @refresh_cooldown_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(_opts), do: {:ok, %{keys: [], fetched_at: nil, attempted_at: nil}}

  def key(kid) when is_binary(kid) and byte_size(kid) in 1..200 do
    GenServer.call(__MODULE__, {:key, kid}, 6_000)
  catch
    :exit, _ -> {:error, :apple_provider_unavailable}
  end

  def key(_kid), do: {:error, :invalid_apple_credential}

  def handle_call({:key, kid}, _from, state) do
    now = System.monotonic_time(:millisecond)
    fresh = is_integer(state.fetched_at) and now - state.fetched_at < @ttl_ms
    existing = if fresh, do: find_key(state.keys, kid)

    cond do
      existing != nil ->
        {:reply, {:ok, existing}, state}

      is_integer(state.attempted_at) and now - state.attempted_at < @refresh_cooldown_ms ->
        {:reply,
         {:error, if(fresh, do: :invalid_apple_credential, else: :apple_provider_unavailable)},
         state}

      true ->
        next = %{state | attempted_at: now}
        started = System.monotonic_time()
        result = fetch_keys()

        CommaProduct.Telemetry.emit_operation(
          :apple_jwks,
          if(match?({:ok, _}, result), do: :ok, else: :unavailable),
          System.monotonic_time() - started
        )

        case result do
          {:ok, keys} ->
            next = %{next | keys: keys, fetched_at: now}

            reply =
              case find_key(keys, kid) do
                nil -> {:error, :invalid_apple_credential}
                key -> {:ok, key}
              end

            {:reply, reply, next}

          _ ->
            {:reply, {:error, :apple_provider_unavailable}, next}
        end
    end
  end

  defp fetch_keys do
    opts = Application.get_env(:comma_core, :apple_auth, [])[:request_options] || []

    with {:ok, %{status: 200, body: body}} <-
           Req.get(
             @url,
             Keyword.merge(opts,
               connect_options: [timeout: 5_000],
               receive_timeout: 5_000,
               retry: false,
               redirect: false,
               decode_body: false,
               compressed: false,
               into: &collect_bounded/2
             )
           ),
         true <- is_binary(body) and byte_size(body) <= 65_536,
         {:ok, %{"keys" => keys}} <- Jason.decode(body),
         true <- is_list(keys) and length(keys) in 1..8,
         true <- Enum.all?(keys, &is_map/1) do
      {:ok, keys}
    else
      _ -> {:error, :apple_provider_unavailable}
    end
  rescue
    _ -> {:error, :apple_provider_unavailable}
  end

  defp collect_bounded({:data, data}, {request, response}) do
    if is_binary(response.body) and byte_size(response.body) + byte_size(data) <= 65_536,
      do: {:cont, {request, %{response | body: response.body <> data}}},
      else: {:halt, {request, %{response | body: nil}}}
  end

  defp find_key(keys, kid) do
    Enum.find(keys, fn key ->
      key["kid"] == kid and key["kty"] == "RSA" and key["use"] == "sig" and
        key["alg"] == "RS256" and is_binary(key["n"]) and byte_size(key["n"]) <= 2_048 and
        is_binary(key["e"]) and byte_size(key["e"]) <= 32
    end)
  end
end
