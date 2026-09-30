defmodule Comma.Auth.GoogleAdapter do
  @moduledoc "Boundary for exchanging or validating Google credentials and returning verified claims."

  @callback exchange_authorization_code(String.t(), keyword()) ::
              {:ok, map()} | {:error, :invalid_google_credential | :google_provider_unavailable}

  @callback verify_id_token(String.t(), keyword()) ::
              {:ok, map()} | {:error, :invalid_google_credential | :google_provider_unavailable}
end
