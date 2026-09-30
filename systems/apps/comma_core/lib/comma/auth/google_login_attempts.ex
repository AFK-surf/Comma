defmodule Comma.Auth.GoogleLoginAttempts do
  @moduledoc "One-time, nonce-bound state issued before starting Google Identity Services."

  @purpose "google_login_attempt"
  @default_ttl_seconds 300
  @max_attempts 2
  @default_ip_request_limit 500
  @default_ip_request_window_seconds 15 * 60

  @spec create(String.t(), map()) :: {:ok, map()} | {:error, :google_not_configured | term()}
  def create(platform \\ "web", attrs \\ %{})

  def create(platform, attrs) when platform in ["web", "electron"] and is_map(attrs) do
    with {:ok, client_id} <- client_id(platform),
         {:ok, ip_fingerprint} <- ip_fingerprint(attrs),
         attempt_id <- random_id(platform),
         nonce <- random_nonce(),
         challenge <- %{
           "id" => attempt_id,
           "purpose" => @purpose,
           "platform" => platform,
           "client_id" => client_id,
           "code_hash" => state_hash(attempt_id, nonce),
           "attempts" => 0
         },
         :ok <-
           store().reserve_attempt(
             challenge,
             ttl_seconds(),
             request_limit_options(ip_fingerprint)
           ) do
      {:ok,
       %{
         "attempt_id" => attempt_id,
         "client_id" => client_id,
         "nonce" => nonce,
         "platform" => platform
       }}
    end
  end

  def create(_platform, _attrs), do: {:error, :google_not_configured}

  @spec consume(map(), String.t()) :: {:ok, map()} | {:error, :invalid_google_attempt | term()}
  def consume(attrs, expected_platform)
      when is_map(attrs) and expected_platform in ["web", "electron"] do
    # Protocol anchor: tla/google_desktop_auth/GoogleDesktopAuth.tla
    attempt_id = trim(value(attrs, "attempt_id"))
    nonce = trim(value(attrs, "nonce"))

    with true <- attempt_id != "" and nonce != "",
         true <- platform_attempt_id?(attempt_id, expected_platform),
         {:ok, challenge} <-
           store().verify(attempt_id, state_hash(attempt_id, nonce), @max_attempts),
         true <- challenge["purpose"] == @purpose,
         true <- challenge["platform"] == expected_platform,
         true <- challenge["client_id"] == client_id_for(challenge["platform"]) do
      {:ok, Map.put(challenge, "nonce", nonce)}
    else
      {:error, reason} when reason in [:not_found, :invalid_code, :too_many_attempts] ->
        {:error, :invalid_google_attempt}

      false ->
        {:error, :invalid_google_attempt}

      {:error, _reason} = error ->
        error
    end
  end

  def consume(_attrs, _expected_platform), do: {:error, :invalid_google_attempt}

  defp client_id(platform) do
    case {client_id_for(platform), platform_configured?(platform)} do
      {value, true} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :google_not_configured}
    end
  end

  defp platform_configured?("web"), do: true

  defp platform_configured?("electron") do
    case google_config()[:electron_client_secret] do
      value when is_binary(value) -> String.trim(value) != ""
      _other -> false
    end
  end

  defp client_id_for("web"), do: google_config()[:web_client_id] |> normalize_client_id()

  defp client_id_for("electron"),
    do: google_config()[:electron_client_id] |> normalize_client_id()

  defp client_id_for(_platform), do: nil

  defp normalize_client_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_client_id(_value), do: nil

  defp random_id(platform),
    do: "gla_#{platform}_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp platform_attempt_id?(attempt_id, platform),
    do: String.starts_with?(attempt_id, "gla_#{platform}_")

  defp random_nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp ip_fingerprint(attrs) do
    peer =
      case trim(value(attrs, "remote_ip")) do
        "" -> "unknown"
        value -> value
      end

    case get_in(auth_config(), [:rate_limit_secret]) do
      secret when is_binary(secret) and secret != "" ->
        {:ok,
         :crypto.mac(:hmac, :sha256, secret, "google_attempt_peer:" <> peer)
         |> Base.url_encode64(padding: false)}

      _missing ->
        {:error, :auth_not_configured}
    end
  end

  defp request_limit_options(ip_fingerprint) do
    %{
      ip_fingerprint: ip_fingerprint,
      ip_request_limit: positive_config(:ip_request_limit, @default_ip_request_limit),
      ip_request_window_seconds:
        positive_config(:ip_request_window_seconds, @default_ip_request_window_seconds)
    }
  end

  defp positive_config(key, default) do
    case get_in(auth_config(), [key]) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp state_hash(id, nonce) do
    :crypto.hash(:sha256, id <> ":" <> nonce)
    |> Base.encode16(case: :lower)
  end

  defp store do
    get_in(auth_config(), [:challenge_store]) || Comma.AuthChallengeStore.Redis
  end

  defp ttl_seconds,
    do: google_config()[:attempt_ttl_seconds] || @default_ttl_seconds

  defp google_config, do: Application.get_env(:comma_core, :google_auth, [])
  defp auth_config, do: Application.get_env(:comma_core, :auth, [])
  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_atom(key)))
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
