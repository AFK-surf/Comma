defmodule SalixSignal.Account.Attributes do
  @moduledoc """
  Account attributes and identity of a registered account (CRS-02 §5).

  `PUT /v1/accounts/attributes/` replaces every stored value (CRS-02 §5,
  CRS-15 §3.3). An update without `registrationLock` clears the lock, and
  one without `spqr` removes that capability.
  `SalixSignalProto.Registration.account_attributes/1` always adds `spqr`;
  the caller passes the lock token and the other values it wants to keep.
  """

  alias SalixSignal.Account.Transport
  alias SalixSignal.Service.Response
  alias SalixSignalProto.Registration

  @doc """
  Replaces the account attributes. `attributes` are the inputs of
  `SalixSignalProto.Registration.account_attributes/1`.
  """
  @spec update(Transport.t(), Registration.attributes()) :: :ok | {:error, term()}
  def update(transport, attributes) do
    body = Registration.account_attributes(attributes)

    case Transport.request(transport, "PUT", "/v1/accounts/attributes/", json: body) do
      {:ok, %Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Response{status: 422}} -> {:error, :invalid_request}
      {:ok, response} -> {:error, Transport.error(response)}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @doc "The account's IDs, number and username state (`GET /v1/accounts/whoami`)."
  @spec whoami(Transport.t()) :: {:ok, Registration.account()} | {:error, term()}
  def whoami(transport) do
    case Transport.request(transport, "GET", "/v1/accounts/whoami", []) do
      {:ok, %Response{status: 200} = response} ->
        response |> Transport.json_object() |> Registration.parse_account()

      {:ok, response} ->
        {:error, Transport.error(response)}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end
end
