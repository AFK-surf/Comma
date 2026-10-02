defmodule Comma.Notifications.APNs do
  @moduledoc "APNs HTTP/2 transport. Req owns HTTP/TLS and JOSE owns ES256 signing."

  alias Comma.Notifications.APNs.{ProviderToken, Transport}

  @hosts %{
    "sandbox" => "https://api.sandbox.push.apple.com",
    "production" => "https://api.push.apple.com"
  }

  # The product owns this allowlist. Profile configuration may narrow it but
  # cannot grant a client authority to send to an arbitrary Apple application.
  @bundle_ids ~w(surf.comma.ios surf.comma.ios.dev)

  # Listener admission needs at least one configured environment, not a global
  # topic or both environments. Registration still checks the selected profile.
  def configured? do
    Enum.any?(~w(sandbox production), fn environment ->
      case profile(environment) do
        {:ok, config} -> Enum.any?(config[:allowed_bundle_ids] || [], &(&1 in @bundle_ids))
        _ -> false
      end
    end)
  end

  def registration_bundle(environment, requested_bundle) do
    with {:ok, config} <- profile(environment),
         {:ok, bundle} <- validated_bundle(config, requested_bundle),
         {:ok, _} <- ProviderToken.get(config) do
      {:ok, bundle}
    end
  catch
    :exit, _ -> {:error, :push_unavailable}
  end

  defp profile(environment) when environment in ["sandbox", "production"] do
    config = Application.get_env(:comma_core, :apns, [])
    profiles = config[:profiles] || %{}
    selected = profiles[environment]

    if is_list(selected) and
         Enum.all?(
           [:team_id, :key_id, :private_key],
           &(is_binary(selected[&1]) and selected[&1] != "")
         ) do
      {:ok, selected ++ Keyword.take(config, [:plug])}
    else
      {:error, :push_unavailable}
    end
  end

  defp profile(_), do: {:error, :invalid_push_registration}

  defp validated_bundle(config, requested_bundle) do
    # Only an operator's explicit historical mapping can authorize old callers
    # and nullable rows. Never infer identity from token or APNs environment.
    bundle = if is_nil(requested_bundle), do: config[:legacy_bundle_id], else: requested_bundle

    if bundle in @bundle_ids and bundle in (config[:allowed_bundle_ids] || []) do
      {:ok, bundle}
    else
      {:error, :invalid_push_registration}
    end
  end

  def send(target, payload) do
    started = System.monotonic_time()
    result = do_send(target, payload)

    CommaProduct.Telemetry.emit_operation(
      :apns_delivery,
      outcome(result),
      System.monotonic_time() - started
    )

    result
  end

  defp do_send(target, payload) do
    with {:ok, config} <- profile(target.environment),
         {:ok, bundle} <- validated_bundle(config, target.bundle_id),
         {:ok, provider_token} <- ProviderToken.get(config) do
      host = @hosts[target.environment]
      activity = target.kind in ["live_activity", "push_to_start"]
      topic = bundle <> if(activity, do: ".push-type.liveactivity", else: "")

      headers = [
        {"authorization", "bearer " <> provider_token},
        {"apns-topic", topic},
        {"apns-push-type", if(activity, do: "liveactivity", else: "alert")},
        {"apns-priority", if(activity and payload["aps"]["alert"] == nil, do: "5", else: "10")},
        {"apns-expiration", Integer.to_string(System.system_time(:second) + 120)}
      ]

      options = [
        url: host <> "/3/device/" <> target.token,
        headers: headers,
        json: payload,
        retry: false,
        redirect: false,
        receive_timeout: 5_000
      ]

      # Tests replace only Req's transport adapter; URL, headers, JSON and errors
      # pass through the same production request construction.
      options = options ++ Keyword.take(config, [:plug])

      Transport.post(host, options)
    else
      _ -> {:error, :push_unavailable}
    end
  rescue
    _ -> {:error, :push_unavailable}
  catch
    :exit, _ -> {:error, :push_unavailable}
  end

  defp outcome(:ok), do: :ok
  defp outcome({:error, :push_unavailable}), do: :unavailable
  defp outcome({:error, :invalid_token}), do: :rejected
  defp outcome(_), do: :error
end

defmodule Comma.Notifications.APNs.ProviderToken do
  @moduledoc "Per-signing-identity APNs provider JWT cache; no request owns Apple signing material."
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def get(config), do: GenServer.call(__MODULE__, {:get, config}, 5_000)
  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:get, config}, _from, cached) do
    now = System.system_time(:second)
    identity = {config[:team_id], config[:key_id], config[:private_key]}

    # Switching sandbox/production must reuse each independently signed JWT.
    # Expiry and a small rotation bound prevent retaining old key material.
    cached = Map.filter(cached, fn {_identity, entry} -> now - entry.issued_at < 2_400 end)

    case cached[identity] do
      %{token: token} = entry ->
        next = Map.put(cached, identity, %{entry | used_at: System.monotonic_time()})
        {:reply, {:ok, token}, next}

      nil ->
        case sign(config, now) do
          {:ok, token} ->
            next =
              Map.put(cached, identity, %{
                issued_at: now,
                used_at: System.monotonic_time(),
                token: token
              })
              |> Enum.sort_by(fn {_identity, entry} -> entry.used_at end, :desc)
              |> Enum.take(8)
              |> Map.new()

            {:reply, {:ok, token}, next}

          {:error, _} = error ->
            {:reply, error, cached}
        end
    end
  end

  defp sign(config, now) do
    # Apple authorizes this independently issued developer key for the app topic.
    # A missing/invalid key fails closed to push_unavailable, never fake delivery.
    token =
      config[:private_key]
      |> JOSE.JWK.from_pem()
      |> JOSE.JWT.sign(
        %{"alg" => "ES256", "kid" => config[:key_id]},
        %{"iss" => config[:team_id], "iat" => now}
      )
      |> JOSE.JWS.compact()
      |> elem(1)

    {:ok, token}
  rescue
    _ -> {:error, :push_unavailable}
  end
end
