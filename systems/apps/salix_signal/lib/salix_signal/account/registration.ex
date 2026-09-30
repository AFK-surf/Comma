defmodule SalixSignal.Account.Registration do
  @moduledoc """
  Primary-device registration of a phone number (CRS-02 §3).

  Order of work, so that no crash loses an account:

  1. `new_account/2` makes the device password, both identity key pairs,
     their registration IDs and their first signed EC and last-resort KEM
     pre-keys. The caller stores the result durably.
  2. `register/4` sends `POST /v1/registration` with a verified session or a
     recovery password. On success the service has replaced any earlier
     account on the number (CRS-02 §3.5): its old devices are signed out and
     its queued messages and one-time pre-keys are deleted.
  3. The caller stores the returned account IDs, then publishes one-time
     pre-keys with `SalixSignal.Account.PreKeyService.maintain/5` using
     `credentials/2`.

  A registration can need several calls (CRS-02 §3.4). Comma always sends
  `skipDeviceTransfer: true`, so 409 does not occur for its requests. A 423
  means the number has an active registration lock; the error carries the
  remaining lock time and the SVR2 credentials of the lock.
  """

  alias SalixSignal.Account.{KemSupport, Transport}
  alias SalixSignal.Service.{Credentials, Response}
  alias SalixSignalProto.{Keys, Registration}
  alias SalixSignalProto.PreKeys.Store

  defmodule NewAccount do
    @moduledoc """
    Everything a registration sends, with the private keys it needs later.
    All of it is owned durable data: losing it means registering the number
    again, which peers see as a new identity (CRS-03 §3.4).
    """
    @enforce_keys [:number, :password, :aci, :pni, :registration_id, :pni_registration_id]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            number: String.t(),
            password: String.t(),
            aci: Store.t(),
            pni: Store.t(),
            registration_id: pos_integer(),
            pni_registration_id: pos_integer()
          }

    defimpl Inspect do
      def inspect(%{number: number}, _opts),
        do: "#SalixSignal.Account.Registration.NewAccount<#{number}>"
    end
  end

  @type error ::
          :session_not_verified
          | :recovery_password_rejected
          | :device_transfer_available
          | :invalid_request
          | {:registration_locked,
             %{time_remaining_ms: non_neg_integer() | nil, svr2_credentials: map() | nil}}
          | :second_factor_required
          | {:rate_limited, non_neg_integer() | nil}
          | :client_deprecated
          | {:unavailable, non_neg_integer()}
          | {:http_error, non_neg_integer()}
          | {:transport, term()}

  @doc """
  New secrets for registering the E.164 `number` at `now_ms`: a random
  22-character device password, new ACI and PNI identity keys, random
  registration IDs and each identity's first pre-keys.

  Refuses with `:kem_unsupported` on a node without constant-time KEM
  support (`SalixSignal.Account.KemSupport`).
  """
  @spec new_account(String.t(), integer()) :: {:ok, NewAccount.t()} | {:error, :kem_unsupported}
  def new_account("+" <> _ = number, now_ms) do
    with :ok <- KemSupport.check() do
      {:ok,
       %NewAccount{
         number: number,
         password: Credentials.new_password(),
         aci: Store.new(Keys.ec_keypair(), now_ms),
         pni: Store.new(Keys.ec_keypair(), now_ms),
         registration_id: Registration.random_registration_id(),
         pni_registration_id: Registration.random_registration_id()
       }}
    end
  end

  @doc """
  Registers `account`. `verification` is `{:session, id}` for a verified
  session (`SalixSignal.Account.Verification`) or `{:recovery_password,
  bytes}`. `attributes` are the other account attributes of
  `SalixSignalProto.Registration.account_attributes/1`; the registration IDs
  come from `account`.

  Returns the account object (`SalixSignalProto.Registration.parse_account/1`).
  """
  @spec register(
          Transport.t(),
          NewAccount.t(),
          {:session, String.t()} | {:recovery_password, binary()},
          map()
        ) :: {:ok, Registration.account()} | {:error, error()}
  def register(transport, %NewAccount{} = account, verification, attributes) do
    attributes =
      Map.merge(attributes, %{
        registration_id: account.registration_id,
        pni_registration_id: account.pni_registration_id
      })

    body = Registration.registration_body(verification, attributes, account.aci, account.pni)
    credentials = Credentials.registration(account.number, account.password)

    case Transport.request(transport, "POST", "/v1/registration",
           json: body,
           credentials: credentials
         ) do
      {:ok, %Response{status: 200} = response} ->
        case Registration.parse_account(Transport.json_object(response)) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, :malformed} -> {:error, {:http_error, 200}}
        end

      {:ok, response} ->
        {:error, error(response)}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc "The device credentials after registration: device 1 of the account."
  @spec credentials(Registration.account(), NewAccount.t()) :: Credentials.t()
  def credentials(%{aci: aci}, %NewAccount{password: password}),
    do: Credentials.device(aci, 1, password)

  defp error(%Response{status: 401}), do: :session_not_verified
  defp error(%Response{status: 403}), do: :recovery_password_rejected
  defp error(%Response{status: 409}), do: :device_transfer_available
  defp error(%Response{status: status}) when status in [400, 422], do: :invalid_request
  defp error(%Response{status: 441}), do: :second_factor_required

  defp error(%Response{status: 423} = response) do
    body = Transport.json_object(response) || %{}
    remaining = body["timeRemaining"]

    {:registration_locked,
     %{
       time_remaining_ms: if(is_integer(remaining) and remaining >= 0, do: remaining),
       svr2_credentials: if(is_map(body["svr2Credentials"]), do: body["svr2Credentials"])
     }}
  end

  defp error(response), do: Transport.error(response)
end
