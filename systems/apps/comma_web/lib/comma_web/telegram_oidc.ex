defmodule CommaWeb.TelegramOIDC do
  @moduledoc "Telegram OIDC Authorization Code + PKCE flow for Comma account linking."

  alias Comma.TelegramLinks

  @authorization_endpoint "https://oauth.telegram.org/auth"
  @default_issuer "https://oauth.telegram.org"
  @scope "openid profile telegram:bot_access"
  @random_bytes 32

  def configured? do
    config = config()

    config[:oidc_enabled] == true and
      Enum.all?([:client_id, :client_secret, :public_base_url], &nonblank?(config[&1]))
  end

  def start(user, session, workspace_id, environment \\ nil) do
    if configured?() do
      # A fixed presentation destination travels inside the single-use state.
      # It is not an arbitrary redirect URI and grants no binding authority.
      state = return_environment(environment) <> "." <> random_url_token()
      nonce = random_url_token()
      verifier = random_url_token()

      with {:ok, workspace, _attempt} <-
             TelegramLinks.create_oidc_attempt(user, session, workspace_id, %{
               "state" => state,
               "nonce" => nonce,
               "pkce_verifier" => verifier
             }) do
        {:ok,
         %{
           "authorization_url" => authorization_url(state, nonce, verifier),
           "expires_in_seconds" => 600,
           "workspace_id" => workspace["id"]
         }}
      end
    else
      {:error, :telegram_oidc_unavailable}
    end
  end

  def complete(code, state) when is_binary(code) and is_binary(state) do
    config = config()

    with true <- configured?(),
         true <- nonblank?(code) and nonblank?(state),
         {:ok, %{attempt: attempt, user: user, workspace: workspace}} <-
           TelegramLinks.take_oidc_attempt(state),
         {:ok, claims} <-
           adapter().exchange_authorization_code(code,
             client_id: config[:client_id],
             client_secret: config[:client_secret],
             nonce: attempt.nonce,
             pkce_verifier: attempt.pkce_verifier,
             redirect_uri: redirect_uri()
           ),
         {:ok, identity} <- telegram_identity(claims) do
      {:ok, %{identity: identity, user: user, workspace: workspace, attempt: attempt}}
    else
      false -> {:error, :invalid_telegram_oidc_callback}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_telegram_oidc_callback}
    end
  end

  def complete(_code, _state), do: {:error, :invalid_telegram_oidc_callback}

  def return_environment(value) when value in ["dev", "staging", "prod"], do: value
  def return_environment(_), do: "prod"

  def callback_environment(state) when is_binary(state),
    do: state |> String.split(".", parts: 2) |> hd() |> return_environment()

  def callback_environment(_), do: "prod"

  def child_specs do
    config = config()

    if configured?() and adapter() == CommaWeb.TelegramOIDC.Oidcc do
      [
        {CommaWeb.TelegramOIDC.ProviderOwner,
         %{
           issuer: config[:issuer] || @default_issuer,
           name: CommaWeb.TelegramOIDC.Oidcc.Provider,
           provider_configuration_opts: %{
             request_opts: CommaWeb.TelegramOIDC.Oidcc.request_opts()
           }
         }}
      ]
    else
      []
    end
  end

  defp authorization_url(state, nonce, verifier) do
    endpoint = config()[:authorization_endpoint] || @authorization_endpoint

    query =
      URI.encode_query(%{
        "client_id" => config()[:client_id],
        "code_challenge" => pkce_challenge(verifier),
        "code_challenge_method" => "S256",
        "nonce" => nonce,
        "redirect_uri" => redirect_uri(),
        "response_type" => "code",
        "scope" => @scope,
        "state" => state
      })

    endpoint <> "?" <> query
  end

  defp telegram_identity(claims) when is_map(claims) do
    # OIDC sub is an opaque authentication subject, not the Bot API peer id.
    id = claims["id"] |> normalize_id()
    username = claims["preferred_username"] |> normalize_username()

    if id == "" or not nonblank?(claims["sub"]) do
      {:error, :invalid_telegram_identity}
    else
      {:ok, %{"id" => id, "username" => username}}
    end
  end

  defp telegram_identity(_claims), do: {:error, :invalid_telegram_identity}

  defp adapter, do: config()[:oidc_adapter] || CommaWeb.TelegramOIDC.Oidcc

  defp redirect_uri,
    do:
      String.trim_trailing(config()[:public_base_url], "/") <>
        "/v1/comma/integrations/telegram/connect/callback"

  defp pkce_challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp random_url_token,
    do: :crypto.strong_rand_bytes(@random_bytes) |> Base.url_encode64(padding: false)

  defp normalize_id(value) when is_integer(value) and value > 0, do: Integer.to_string(value)

  defp normalize_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> Integer.to_string(id)
      _ -> ""
    end
  end

  defp normalize_id(_value), do: ""

  defp normalize_username(value) when is_binary(value) do
    case value |> String.trim() |> String.trim_leading("@") do
      "" -> nil
      username -> username
    end
  end

  defp normalize_username(_value), do: nil
  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
  defp config, do: Application.get_env(:comma_web, :telegram, [])
end
