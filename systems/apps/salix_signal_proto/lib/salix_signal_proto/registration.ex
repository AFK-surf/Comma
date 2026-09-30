defmodule SalixSignalProto.Registration do
  @moduledoc """
  JSON bodies of primary-device registration and account attributes
  (CRS-02 §3 and §5), and the account object that the service returns.

  Comma registers primary devices with a phone number, with
  `fetchesMessages: true` and no push token (CRS-02, Comma decisions 1 and 3).
  The request therefore carries the full PNI group and no push field.

  Byte fields are standard base64 with padding. The service also accepts
  them without padding (CRS-02 §0).
  """

  alias SalixSignalProto.PreKeys.Store

  @required_capabilities %{"spqr" => true}

  @typedoc """
  Inputs of the account attributes object (CRS-02 §3.2):

    * `:registration_id`, `:pni_registration_id`: 1 to 16383;
    * `:unidentified_access_key`: 16 bytes, the sealed-sender access key of
      the account's profile key (`SalixSignalProto.Profile.access_key/1`,
      CRS-06). Required unless
      `:unrestricted_unidentified_access` is true;
    * `:unrestricted_unidentified_access`: default false;
    * `:discoverable_by_phone_number`: default true;
    * `:registration_lock`: the 64-character token, or nil for no lock;
    * `:recovery_password`: 32 bytes to store, or nil to keep the stored
      value;
    * `:capabilities`: extra capability names set to true. `spqr` is always
      sent: the service requires it for new devices (CRS-02 §6), and an
      attribute update without it removes it (CRS-15 §3.3).
  """
  @type attributes :: %{
          required(:registration_id) => pos_integer(),
          required(:pni_registration_id) => pos_integer(),
          optional(:unidentified_access_key) => <<_::128>>,
          optional(:unrestricted_unidentified_access) => boolean(),
          optional(:discoverable_by_phone_number) => boolean(),
          optional(:registration_lock) => String.t() | nil,
          optional(:recovery_password) => <<_::256>> | nil,
          optional(:capabilities) => [String.t()]
        }

  @doc """
  A random registration ID from 1 to 16380, the range of deployed clients
  (CRS-03 §8). Use one for the ACI and another for the PNI.
  """
  @spec random_registration_id() :: pos_integer()
  def random_registration_id do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    rem(n, 16_380) + 1
  end

  @doc """
  The account attributes object, the body of `PUT /v1/accounts/attributes/`.
  The service replaces every stored value with it, so it always carries the
  full set, including the registration lock that should stay set
  (CRS-02 §5).
  """
  @spec account_attributes(attributes()) :: map()
  def account_attributes(attributes) do
    unrestricted = Map.get(attributes, :unrestricted_unidentified_access, false)
    access_key = Map.get(attributes, :unidentified_access_key)

    unless unrestricted or match?(<<_::binary-size(16)>>, access_key),
      do: raise(ArgumentError, "unidentified_access_key must be 16 bytes")

    lock = Map.get(attributes, :registration_lock)

    unless lock == nil or (is_binary(lock) and byte_size(lock) == 64),
      do: raise(ArgumentError, "registration_lock must be 64 characters")

    capabilities =
      attributes
      |> Map.get(:capabilities, [])
      |> Map.new(&{&1, true})
      |> Map.merge(@required_capabilities)

    %{
      "fetchesMessages" => true,
      "registrationId" => registration_id!(attributes.registration_id),
      "pniRegistrationId" => registration_id!(attributes.pni_registration_id),
      "unrestrictedUnidentifiedAccess" => unrestricted,
      "discoverableByPhoneNumber" => Map.get(attributes, :discoverable_by_phone_number, true),
      "capabilities" => capabilities
    }
    |> put_present("unidentifiedAccessKey", access_key && Base.encode64(access_key))
    |> put_present("registrationLock", lock)
    |> put_present("recoveryPassword", recovery_password(Map.get(attributes, :recovery_password)))
  end

  defp registration_id!(id) when is_integer(id) and id in 1..16_383, do: id
  defp registration_id!(id), do: raise(ArgumentError, "invalid registration ID #{inspect(id)}")

  defp recovery_password(nil), do: nil
  defp recovery_password(<<_::binary-size(32)>> = password), do: Base.encode64(password)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  The body of `POST /v1/registration` (CRS-02 §3.1).

  `verification` is `{:session, session_id}` for a verified session or
  `{:recovery_password, bytes}` to re-register the same number without a
  session (CRS-02 §3.6). `aci` and `pni` are the pre-key stores of the two
  identities; their current signed EC pre-key and last-resort KEM pre-key
  are sent. `skipDeviceTransfer` is true: Comma has no old device to transfer
  from.
  """
  @spec registration_body(
          {:session, String.t()} | {:recovery_password, <<_::256>>},
          attributes(),
          Store.t(),
          Store.t()
        ) :: map()
  def registration_body(verification, attributes, %Store{} = aci, %Store{} = pni) do
    %{
      "accountAttributes" => account_attributes(attributes),
      "skipDeviceTransfer" => true,
      "aciIdentityKey" => Base.encode64(aci.identity.public),
      "pniIdentityKey" => Base.encode64(pni.identity.public),
      "aciSignedPreKey" => SalixSignalProto.PreKeys.to_json(Store.current_signed(aci)),
      "pniSignedPreKey" => SalixSignalProto.PreKeys.to_json(Store.current_signed(pni)),
      "aciPqLastResortPreKey" => SalixSignalProto.PreKeys.to_json(Store.current_last_resort(aci)),
      "pniPqLastResortPreKey" => SalixSignalProto.PreKeys.to_json(Store.current_last_resort(pni))
    }
    |> Map.merge(verification_field(verification))
  end

  defp verification_field({:session, id}) when is_binary(id), do: %{"sessionId" => id}

  defp verification_field({:recovery_password, <<_::binary-size(32)>> = password}),
    do: %{"recoveryPassword" => Base.encode64(password)}

  @typedoc "The account object of a registration or `GET /v1/accounts/whoami` response (CRS-02 §3.3)."
  @type account :: %{
          aci: String.t(),
          pni: String.t() | nil,
          number: String.t() | nil,
          username_hash: binary() | nil,
          username_link_handle: String.t() | nil,
          reregistration: boolean()
        }

  @doc """
  Parses the account object. `uuid` must be a UUID; the other fields are
  optional. The username hash is base64url without padding.
  """
  @spec parse_account(term()) :: {:ok, account()} | {:error, :malformed}
  def parse_account(%{"uuid" => aci} = body) when is_binary(aci) do
    with true <- uuid?(aci),
         pni = Map.get(body, "pni"),
         true <- pni == nil or uuid?(pni),
         {:ok, username_hash} <- username_hash(Map.get(body, "usernameHash")) do
      {:ok,
       %{
         aci: String.downcase(aci),
         pni: pni && String.downcase(pni),
         number: string_or_nil(Map.get(body, "number")),
         username_hash: username_hash,
         username_link_handle: string_or_nil(Map.get(body, "usernameLinkHandle")),
         reregistration: Map.get(body, "reregistration") == true
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  def parse_account(_body), do: {:error, :malformed}

  defp username_hash(nil), do: {:ok, nil}

  defp username_hash(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<_::binary-size(32)>> = hash} -> {:ok, hash}
      _ -> :error
    end
  end

  defp username_hash(_other), do: :error

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp uuid?(value),
    do: match?({:ok, {:aci, _}}, SalixSignalProto.Address.parse_service_id(value))
end
