defmodule Comma.Auth.OneTimeCredentials do
  @moduledoc """
  Short-lived credentials in the existing one-time Auth Challenge store.

  A stolen/replayed grant must not create another Auth Session. The Auth
  Challenge owner stores only its digest and consumes it atomically. Random
  credentials carry one explicit purpose and server-authored context, never
  caller-supplied account authority. Expiry and revocation checks fail closed.
  """

  def issue(purpose, context, ttl_seconds, peer) do
    id = purpose <> "_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = System.system_time(:second) + ttl_seconds

    challenge =
      Map.merge(context, %{
        "id" => id,
        "purpose" => purpose,
        "code_hash" => digest(id, secret),
        "expires_at" => expires_at,
        "attempts" => 0
      })

    with {:ok, fingerprint} <- fingerprint(purpose, peer),
         :ok <-
           store().reserve_attempt(challenge, ttl_seconds, %{
             ip_fingerprint: fingerprint,
             ip_request_limit: 50,
             ip_request_window_seconds: 900
           }) do
      {:ok, %{id: id, secret: secret, expires_at: expires_at}}
    else
      {:error, :rate_limited, _} = error -> error
      {:error, :auth_not_configured} = error -> error
      _ -> {:error, :auth_unavailable}
    end
  end

  def consume(purpose, id, secret)
      when is_binary(id) and byte_size(id) <= 200 and is_binary(secret) and
             byte_size(secret) <= 200 do
    with true <- String.starts_with?(id, purpose <> "_") and secret != "",
         {:ok, challenge} <- store().verify(id, digest(id, secret), 3),
         true <- challenge["purpose"] == purpose,
         true <- challenge["expires_at"] > System.system_time(:second) do
      {:ok, challenge}
    else
      {:error, reason} when reason in [:not_found, :invalid_code, :too_many_attempts] ->
        {:error, :invalid_one_time_credential}

      false ->
        {:error, :invalid_one_time_credential}

      _ ->
        {:error, :auth_unavailable}
    end
  end

  def consume(_purpose, _id, _secret), do: {:error, :invalid_one_time_credential}

  defp digest(id, secret),
    do: :crypto.hash(:sha256, id <> ":" <> secret) |> Base.encode16(case: :lower)

  defp fingerprint(purpose, peer) do
    case Application.get_env(:comma_core, :auth, [])[:rate_limit_secret] do
      secret when is_binary(secret) and secret != "" ->
        {:ok, :crypto.mac(:hmac, :sha256, secret, purpose <> ":" <> peer) |> Base.encode16()}

      _ ->
        {:error, :auth_not_configured}
    end
  end

  defp store,
    do:
      Application.get_env(:comma_core, :auth, [])[:challenge_store] ||
        Comma.AuthChallengeStore.Redis
end
