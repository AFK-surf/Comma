defmodule Comma.Auth.GoogleAdapter.Fake do
  @moduledoc false

  @behaviour Comma.Auth.GoogleAdapter

  @impl true
  def exchange_authorization_code(authorization_code, opts) do
    if pid = Application.get_env(:comma_core, :google_adapter_fake_exchange_pid) do
      send(pid, {:google_authorization_code_exchange, authorization_code, opts})
    end

    verify_fake_credential(authorization_code, opts)
  end

  @impl true
  def verify_id_token(credential, opts) do
    verify_fake_credential(credential, opts)
  end

  defp verify_fake_credential(credential, opts) do
    credentials = Application.get_env(:comma_core, :google_adapter_fake_credentials, %{})

    case Map.get(credentials, credential) do
      claims when is_map(claims) ->
        if claims["nonce"] == Keyword.get(opts, :nonce) and
             claims["aud"] == Keyword.get(opts, :client_id) do
          {:ok, claims}
        else
          {:error, :invalid_google_credential}
        end

      :provider_unavailable ->
        {:error, :google_provider_unavailable}

      _other ->
        {:error, :invalid_google_credential}
    end
  end
end
