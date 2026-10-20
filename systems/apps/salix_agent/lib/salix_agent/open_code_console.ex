defmodule SalixAgent.OpenCodeConsole do
  @moduledoc """
  An OpenCode Go Profile signed in with the person's OpenCode Console account
  instead of a pasted key: the Console's device authorization grant (RFC 8628),
  which OpenCode documents for other clients. Its access token is taken by the
  Go gateway wherever a key is, so the Profile stays an `opencode-go` API key
  (`SalixAgent.AccountPool`); it lasts 30 days and is renewed with a refresh
  token that is spent when used (the access token before it stops working at
  once).

  The Console's base URL and Req options come from the `:opencode_console`
  setting of `:salix_agent` (`base_url`, `req_options`), for tests.
  """

  @base "https://opencode.ai/console"
  # The client the Console names on the page that approves a sign-in.
  @client_id "comma"
  @agent "comma"

  @type device :: %{
          device_code: String.t(),
          user_code: String.t(),
          url: String.t(),
          interval: pos_integer()
        }
  @type token :: %{access: String.t(), refresh: String.t(), expires_at: integer()}

  @doc "A code to sign in with: the page with the code filled in, and how often to ask."
  @spec start() :: {:ok, device()} | {:error, term()}
  def start do
    case post("/auth/device/code", %{"client_id" => @client_id, "supports_org_scope" => "true"}) do
      {:ok, 200,
       %{
         "device_code" => device_code,
         "user_code" => user_code,
         "verification_uri_complete" => page
       } = body}
      when is_binary(device_code) and is_binary(user_code) and is_binary(page) ->
        url = URI.merge(URI.parse(base()), page) |> URI.to_string()

        if String.starts_with?(url, "https://") or test_base?(),
          do:
            {:ok,
             %{
               device_code: device_code,
               user_code: user_code,
               url: url,
               interval: interval(body["interval"])
             }},
          else: {:error, :authorization_unavailable}

      _ ->
        {:error, :authorization_unavailable}
    end
  end

  @doc "Whether the code was approved: still waiting (`slow_down`: asked too often), signed in, or refused."
  @spec poll(String.t()) ::
          {:pending, boolean()} | {:ok, token()} | {:error, term()}
  def poll(device_code) do
    case post("/auth/device/token", %{
           "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
           "device_code" => device_code,
           "client_id" => @client_id
         }) do
      {:ok, 200, body} ->
        token(body)

      {:ok, _status, %{"error" => error}} when error in ["authorization_pending", "slow_down"] ->
        {:pending, error == "slow_down"}

      {:ok, _status, %{"error" => "expired_token"}} ->
        {:error, :authorization_expired}

      _ ->
        {:error, :authorization_unavailable}
    end
  end

  @doc "A new access token for a refresh token, which is spent: the one returned replaces it."
  @spec renew(String.t()) :: {:ok, token()} | {:error, :refused | :unavailable}
  def renew(refresh) do
    case post("/auth/device/token", %{
           "grant_type" => "refresh_token",
           "refresh_token" => refresh,
           "client_id" => @client_id
         }) do
      {:ok, 200, body} ->
        case token(body) do
          {:ok, token} -> {:ok, token}
          _ -> {:error, :unavailable}
        end

      {:ok, status, _} when status in [400, 401, 403] ->
        {:error, :refused}

      _ ->
        {:error, :unavailable}
    end
  end

  @doc "Whose account a token is, where the Console says."
  @spec email(String.t()) :: String.t() | nil
  def email(access) do
    case Req.get(base() <> "/api/user", req_options(headers: headers(access))) do
      {:ok, %{status: 200, body: %{"email" => email}}} when is_binary(email) and email != "" ->
        email

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp token(%{"access_token" => access, "refresh_token" => refresh, "expires_in" => seconds})
       when is_binary(access) and access != "" and is_binary(refresh) and refresh != "" and
              is_integer(seconds) and seconds > 0,
       do:
         {:ok,
          %{
            access: access,
            refresh: refresh,
            expires_at: SystemsClock.system_time(:second) + seconds
          }}

  defp token(_), do: {:error, :authorization_unavailable}

  defp interval(seconds) when is_integer(seconds) and seconds >= 5 and seconds <= 900,
    do: seconds

  defp interval(_), do: 5

  defp post(path, form) do
    case Req.post(base() <> path, req_options(form: form, headers: headers(nil))) do
      {:ok, %{status: status, body: body}} when is_map(body) -> {:ok, status, body}
      {:ok, %{status: status}} -> {:ok, status, %{}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp headers(nil), do: [{"accept", "application/json"}, {"user-agent", @agent}]
  defp headers(access), do: [{"authorization", "Bearer " <> access} | headers(nil)]

  defp req_options(opts) do
    [
      retry: false,
      redirect: false,
      receive_timeout: 20_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(config()[:req_options] || [])
  end

  defp base, do: config()[:base_url] || @base
  defp test_base?, do: config()[:base_url] != nil
  defp config, do: SystemsRuntime.get_env(:salix_agent, :opencode_console, [])
end
