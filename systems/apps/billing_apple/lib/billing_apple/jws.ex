defmodule BillingApple.JWS do
  @moduledoc """
  Reads the payload of an App Store JWS value.

  It does not check the signature. Values that come from the App Store Server
  API arrive over TLS from Apple, which is the authority. Values in a
  notification are only hints: `BillingApple.Transactions` reads the
  transaction again from the App Store Server API before it records anything.
  """

  @spec payload(String.t()) :: {:ok, map()} | {:error, :invalid_jws}
  def payload(jws) when is_binary(jws) do
    with [_header, payload, _signature] <- String.split(jws, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :invalid_jws}
    end
  end

  def payload(_value), do: {:error, :invalid_jws}
end
