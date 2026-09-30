defmodule SalixSignalProto.PreKeys do
  @moduledoc """
  The pre-keys that an account publishes for one identity (ACI or PNI) of
  one device, and their JSON forms on the service (CRS-03 §4, §8, §9).

  | Kind | Signed | Record |
  | --- | --- | --- |
  | Signed EC pre-key | identity key signs the 33-byte public key | `SignedPreKey` |
  | One-time EC pre-key | no | `OneTimePreKey` |
  | One-time KEM pre-key | identity key signs the 1569-byte public key | `KemPreKey` (`last_resort: false`) |
  | Last-resort KEM pre-key | same | `KemPreKey` (`last_resort: true`) |

  Records hold private keys and a local creation time. Only `to_json/1` and
  the request bodies here leave the device; they carry public keys and
  signatures only (CRS-03 §7).

  Signatures are deployed XEdDSA (`SalixSignalProto.Crypto.XEdDSA.sign/3`).
  """

  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.Keys

  @max_id 0xFFFFFF

  defmodule SignedPreKey do
    @moduledoc "A signed EC pre-key with its private key and local creation time."
    @enforce_keys [:id, :public, :private, :signature, :created_ms]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: pos_integer(),
            public: Keys.ec_public(),
            private: Keys.ec_private(),
            signature: <<_::512>>,
            created_ms: integer()
          }
  end

  defmodule OneTimePreKey do
    @moduledoc "A one-time EC pre-key with its private key and local creation time."
    @enforce_keys [:id, :public, :private, :created_ms]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: pos_integer(),
            public: Keys.ec_public(),
            private: Keys.ec_private(),
            created_ms: integer()
          }
  end

  defmodule KemPreKey do
    @moduledoc "A one-time or last-resort KEM pre-key with its secret key and local creation time."
    @enforce_keys [:id, :public, :secret, :signature, :last_resort, :created_ms]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: pos_integer(),
            public: Keys.kem_public(),
            secret: Keys.kem_secret(),
            signature: <<_::512>>,
            last_resort: boolean(),
            created_ms: integer()
          }
  end

  @type identity :: %{public: Keys.ec_public(), private: Keys.ec_private()}
  @type identity_kind :: :aci | :pni

  # --- Identifiers (CRS-03 §8) ---

  @doc """
  A random first key ID from 1 to 0xFFFFFF. Deployed clients start each ID
  sequence at a random value (CRS-03 §8).
  """
  @spec random_id() :: pos_integer()
  def random_id do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    rem(n, @max_id) + 1
  end

  @doc "The ID after `id`: IDs run from 1 to 0xFFFFFF and wrap."
  @spec next_id(pos_integer()) :: pos_integer()
  def next_id(id) when is_integer(id) and id >= 1, do: rem(id, @max_id) + 1

  # --- Generation (CRS-03 §4) ---

  @doc "A new signed EC pre-key, signed by the identity key."
  @spec signed_pre_key(identity(), pos_integer(), integer()) :: SignedPreKey.t()
  def signed_pre_key(%{private: identity_private}, id, created_ms) do
    %{public: public, private: private} = Keys.ec_keypair()

    %SignedPreKey{
      id: id,
      public: public,
      private: private,
      signature: XEdDSA.sign(identity_private, public),
      created_ms: created_ms
    }
  end

  @doc "A new one-time EC pre-key. One-time EC pre-keys are not signed."
  @spec one_time_pre_key(pos_integer(), integer()) :: OneTimePreKey.t()
  def one_time_pre_key(id, created_ms) do
    %{public: public, private: private} = Keys.ec_keypair()
    %OneTimePreKey{id: id, public: public, private: private, created_ms: created_ms}
  end

  @doc "A new KEM pre-key (Kyber1024, type `0x08`), signed by the identity key."
  @spec kem_pre_key(identity(), pos_integer(), boolean(), integer()) :: KemPreKey.t()
  def kem_pre_key(%{private: identity_private}, id, last_resort, created_ms)
      when is_boolean(last_resort) do
    %{public: public, secret: secret} = Keys.kem_keypair()

    %KemPreKey{
      id: id,
      public: public,
      secret: secret,
      signature: XEdDSA.sign(identity_private, public),
      last_resort: last_resort,
      created_ms: created_ms
    }
  end

  # --- JSON forms (CRS-03 §9.1) ---

  @doc """
  The JSON object of a pre-key: `keyId`, `publicKey` and, for signed kinds,
  `signature`. Bytes are standard base64 with padding; the service accepts
  both forms.
  """
  @spec to_json(SignedPreKey.t() | OneTimePreKey.t() | KemPreKey.t()) :: map()
  def to_json(%OneTimePreKey{id: id, public: public}),
    do: %{"keyId" => id, "publicKey" => Base.encode64(public)}

  def to_json(%{id: id, public: public, signature: signature}),
    do: %{
      "keyId" => id,
      "publicKey" => Base.encode64(public),
      "signature" => Base.encode64(signature)
    }

  @doc """
  The body of `PUT /v2/keys?identity={aci|pni}` (CRS-03 §9.2). Each part is
  optional; an absent part leaves the stored keys on the service unchanged.
  A list replaces every stored one-time key of its kind. At most 100 keys
  per list.

  Options: `:pre_keys`, `:signed_pre_key`, `:kem_pre_keys` and
  `:last_resort_pre_key`.
  """
  @spec upload_body(keyword()) :: map()
  def upload_body(parts) do
    [
      pre_keys: "preKeys",
      signed_pre_key: "signedPreKey",
      kem_pre_keys: "pqPreKeys",
      last_resort_pre_key: "pqLastResortPreKey"
    ]
    |> Enum.reject(fn {option, _field} -> Keyword.get(parts, option) in [nil, []] end)
    |> Map.new(fn {option, field} -> {field, json_part(field, Keyword.fetch!(parts, option))} end)
  end

  defp json_part(field, keys) when is_list(keys) do
    if length(keys) > 100, do: raise(ArgumentError, "at most 100 #{field} per upload")
    Enum.map(keys, &to_json/1)
  end

  defp json_part(_field, key), do: to_json(key)

  @doc "The `identity` query value of the pre-key endpoints."
  @spec identity_param(identity_kind()) :: String.t()
  def identity_param(:aci), do: "aci"
  def identity_param(:pni), do: "pni"

  @doc """
  The digest of `POST /v2/keys/check` (CRS-03 §9.4):
  `SHA256(identity public || BE(signed id, 8) || signed public ||
  BE(last-resort id, 8) || last-resort public)`.
  """
  @spec check_digest(Keys.ec_public(), SignedPreKey.t(), KemPreKey.t()) :: <<_::256>>
  def check_digest(
        identity_public,
        %SignedPreKey{} = signed,
        %KemPreKey{last_resort: true} = last_resort
      ) do
    :crypto.hash(:sha256, [
      identity_public,
      <<signed.id::64>>,
      signed.public,
      <<last_resort.id::64>>,
      last_resort.public
    ])
  end

  @doc "The body of `POST /v2/keys/check`."
  @spec check_body(identity_kind(), <<_::256>>) :: map()
  def check_body(kind, <<_::binary-size(32)>> = digest) do
    type = if kind == :aci, do: "ACI", else: "PNI"
    %{"identityType" => type, "digest" => Base.encode64(digest, padding: false)}
  end

  @doc """
  Parses the body of `GET /v2/keys` (CRS-03 §9.3): the one-time EC and
  one-time KEM pre-keys the service still holds for this device.
  """
  @spec parse_counts(term()) ::
          {:ok, %{count: non_neg_integer(), kem_count: non_neg_integer()}} | {:error, :malformed}
  def parse_counts(%{"count" => count, "pqCount" => kem_count})
      when is_integer(count) and count >= 0 and is_integer(kem_count) and kem_count >= 0,
      do: {:ok, %{count: count, kem_count: kem_count}}

  def parse_counts(_body), do: {:error, :malformed}
end
