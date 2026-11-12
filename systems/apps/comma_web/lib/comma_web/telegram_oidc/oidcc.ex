defmodule CommaWeb.TelegramOIDC.Oidcc do
  @moduledoc false

  require Logger

  alias Oidcc.Token
  alias Oidcc.Token.Id

  @provider CommaWeb.TelegramOIDC.Oidcc.Provider
  @timeout_ms 10_000

  def request_opts do
    %{timeout: @timeout_ms, http_adapter: {CommaWeb.TelegramOIDC.HTTPAdapter, %{}}}
  end

  def exchange_authorization_code(code, opts) do
    with {:ok, %Token{id: %Id{claims: claims}}} <-
           Oidcc.retrieve_token(
             code,
             @provider,
             Keyword.fetch!(opts, :client_id),
             Keyword.fetch!(opts, :client_secret),
             %{
               nonce: Keyword.fetch!(opts, :nonce),
               pkce_verifier: Keyword.fetch!(opts, :pkce_verifier),
               preferred_auth_methods: [:client_secret_basic],
               redirect_uri: Keyword.fetch!(opts, :redirect_uri),
               request_opts: request_opts()
             }
           ) do
      {:ok, claims}
    else
      {:error, :provider_not_ready} ->
        {:error, :telegram_provider_unavailable}

      {:error, {:telegram_oidc_transport, _reason}} ->
        {:error, :telegram_provider_unavailable}

      {:error, {:invalid_json, _reason}} ->
        {:error, :telegram_provider_unavailable}

      {:error, :invalid_content_type} ->
        {:error, :telegram_provider_unavailable}

      {:error, {type, status, _body}} when type == :http_error and status >= 500 ->
        {:error, :telegram_provider_unavailable}

      {:error, reason} ->
        Logger.warning("Telegram authorization-code exchange rejected",
          event: "telegram_oidc_exchange_rejected",
          reason_class: rejection_class(reason)
        )

        {:error, :invalid_telegram_credential}

      _other ->
        {:error, :invalid_telegram_credential}
    end
  rescue
    exception ->
      Logger.error("Telegram authorization-code exchange raised unexpectedly",
        exception_module: inspect(exception.__struct__)
      )

      {:error, :telegram_provider_unavailable}
  catch
    :exit, _reason -> {:error, :telegram_provider_unavailable}
  end

  # Bounded classes only: a rejection can carry tokens, claims or response bytes.
  defp rejection_class({:http_error, status, %{"error" => error}})
       when is_integer(status) and is_binary(error),
       do: "http_error_#{status}_#{String.slice(error, 0, 64)}"

  defp rejection_class({:http_error, status, _body}) when is_integer(status),
    do: "http_error_#{status}"

  defp rejection_class(reason) when is_atom(reason), do: reason

  defp rejection_class(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp rejection_class(_reason), do: :other
end
