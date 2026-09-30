defmodule SalixSignalProto.SealedSender.Certificate do
  @moduledoc """
  Server and sender certificates of sealed sender (CRS-06 §3).

  A trust root signs a server certificate, which binds a server signing key
  to a key ID. The server key signs the sender certificate that the service
  issues to an account device. A sender certificate names its signer either
  by embedding the server certificate or by the key ID of a known server
  certificate (§3.4).

  Signatures are deployed XEdDSA (CRS-03 §5) over the certificate body bytes
  exactly as received; a body is never re-encoded before verification.
  """

  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.Keys
  alias SalixSignalProto.SealedSender.Wire
  alias SalixSignalProto.ServiceId

  @revoked_key_id 0xDEADC357

  defmodule Server do
    @moduledoc "A decoded server certificate (CRS-06 §3.1)."
    @enforce_keys [:key_id, :key, :body, :signature, :serialized]
    defstruct [:key_id, :key, :body, :signature, :serialized]

    @type t :: %__MODULE__{
            key_id: non_neg_integer(),
            key: SalixSignalProto.Keys.ec_public(),
            body: binary(),
            signature: binary(),
            serialized: binary()
          }
  end

  defmodule Sender do
    @moduledoc """
    A decoded sender certificate (CRS-06 §3.2). `signer` is
    `{:embedded, server_certificate}` or `{:reference, key_id}`.
    """
    @enforce_keys [
      :device_id,
      :expiration,
      :identity_key,
      :signer,
      :aci,
      :body,
      :signature,
      :serialized
    ]
    defstruct [
      :e164,
      :device_id,
      :expiration,
      :identity_key,
      :signer,
      :aci,
      :body,
      :signature,
      :serialized
    ]

    @type t :: %__MODULE__{
            e164: String.t() | nil,
            device_id: 1..127,
            expiration: non_neg_integer(),
            identity_key: SalixSignalProto.Keys.ec_public(),
            signer:
              {:embedded, SalixSignalProto.SealedSender.Certificate.Server.t()}
              | {:reference, non_neg_integer()},
            aci: <<_::128>>,
            body: binary(),
            signature: binary(),
            serialized: binary()
          }
  end

  # --- trust roots and known server certificates (CRS-06 §3.4, §3.5) -----

  @trust_roots %{
    production: [
      "BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF",
      "BUkY0I+9+oPgDCn4+Ac6Iu813yvqkDr/ga8DzLxFxuk6"
    ],
    staging: [
      "BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx",
      "BYhU6tPjqP46KGZEzRs1OL4U39V5dlPJ/X09ha4rErkm"
    ]
  }

  @known_server_certificates %{
    staging: %{
      2 =>
        "0a25080212210539450d63ebd0752c0fd4038b9d07a916f5e174b756d409b5ca79f4c97400631e124064c5a38b1e927497d3d4786b101a623ab34a7da3954fae126b04dba9d7a3604ed88cdc8550950f0d4a9134ceb7e19b94139151d2c3d6e1c81e9d1128aafca806"
    },
    production: %{
      3 =>
        "0a250803122105bc9d1d290be964810dfa7e94856480a3f7060d004c9762c24c575a1522353a5a1240c11ec3c401eb0107ab38f8600e8720a63169e0e2eb8a3fae24f63099f85ea319c3c1c46d3454706ae2a679d1fee690a488adda98a2290b66c906bb60295ed781"
    }
  }

  @doc "The typed trust root public keys of `environment` (`:production` or `:staging`)."
  @spec trust_roots(:production | :staging) :: [Keys.ec_public()]
  def trust_roots(environment) do
    for encoded <- Map.fetch!(@trust_roots, environment) do
      {:ok, key} = encoded |> Base.decode64!() |> Keys.parse_ec_public()
      key
    end
  end

  @doc "The built-in server certificates of `environment`, by key ID."
  @spec known_server_certificates(:production | :staging) :: %{non_neg_integer() => Server.t()}
  def known_server_certificates(environment) do
    Map.new(Map.fetch!(@known_server_certificates, environment), fn {id, hex} ->
      {:ok, certificate} = decode_server(Base.decode16!(hex, case: :lower))
      {id, certificate}
    end)
  end

  @doc "True for the revoked key ID `0xDEADC357`, which never validates."
  @spec revoked?(non_neg_integer()) :: boolean()
  def revoked?(key_id), do: key_id == @revoked_key_id

  # --- decoding -----------------------------------------------------------

  @doc "Decodes a serialized server certificate. Key ID and key are required."
  @spec decode_server(binary()) :: {:ok, Server.t()} | {:error, :malformed}
  def decode_server(bytes) when is_binary(bytes) do
    with {:ok, %Wire.Signed{body: body, signature: signature}}
         when is_binary(body) and is_binary(signature) <-
           safe_decode(Wire.Signed, bytes),
         {:ok, %Wire.ServerCertificateBody{key_id: key_id, server_public: key}}
         when is_integer(key_id) and is_binary(key) <-
           safe_decode(Wire.ServerCertificateBody, body),
         {:ok, key} <- Keys.parse_ec_public(key) do
      {:ok,
       %Server{key_id: key_id, key: key, body: body, signature: signature, serialized: bytes}}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc """
  Decodes a serialized sender certificate. It fails to parse when a required
  field is missing, when the device ID is outside 1 to 127, when not exactly
  one signer form or one ACI form is present, or when the ACI does not parse
  (CRS-06 §3.2).
  """
  @spec decode_sender(binary()) :: {:ok, Sender.t()} | {:error, :malformed}
  def decode_sender(bytes) when is_binary(bytes) do
    with {:ok, %Wire.Signed{body: body, signature: signature}}
         when is_binary(body) and is_binary(signature) <-
           safe_decode(Wire.Signed, bytes),
         {:ok, %Wire.SenderCertificateBody{} = wire} <-
           safe_decode(Wire.SenderCertificateBody, body),
         %{sender_device: device, expiration: expiration, identity_key: identity}
         when device in 1..127 and is_integer(expiration) and is_binary(identity) <- wire,
         {:ok, identity_key} <- Keys.parse_ec_public(identity),
         {:ok, signer} <- signer(wire),
         {:ok, aci} <- aci(wire),
         {:ok, e164} <- e164(wire.sender_e164) do
      {:ok,
       %Sender{
         e164: e164,
         device_id: device,
         expiration: expiration,
         identity_key: identity_key,
         signer: signer,
         aci: aci,
         body: body,
         signature: signature,
         serialized: bytes
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  defp signer(%{signer: bytes, signer_key_id: nil}) when is_binary(bytes) do
    case decode_server(bytes) do
      {:ok, server} -> {:ok, {:embedded, server}}
      error -> error
    end
  end

  defp signer(%{signer: nil, signer_key_id: id}) when is_integer(id), do: {:ok, {:reference, id}}
  defp signer(_wire), do: :error

  defp aci(%{sender_aci: bytes, sender_aci_string: nil}) when is_binary(bytes),
    do: ServiceId.aci_from_binary(bytes)

  defp aci(%{sender_aci: nil, sender_aci_string: string}) when is_binary(string),
    do: ServiceId.aci_from_string(string)

  defp aci(_wire), do: :error

  defp e164(nil), do: {:ok, nil}
  defp e164(bytes), do: if(String.valid?(bytes), do: {:ok, bytes}, else: :error)

  defp safe_decode(module, bytes) do
    {:ok, module.decode(bytes)}
  rescue
    # The protobuf decoder raises on malformed input.
    _error -> :error
  end

  # --- validation (CRS-06 §3.3) --------------------------------------------

  @doc """
  Validates a sender certificate against `trust_roots` at `now_ms`
  (CRS-06 §3.3): the signer resolves (embedded, or in `known` by key ID), its
  key ID is not revoked, a trust root verifies it, its key verifies the
  sender certificate, and `now_ms <= expiration`.
  """
  @spec validate(Sender.t(), [Keys.ec_public()], non_neg_integer(), %{
          non_neg_integer() => Server.t()
        }) ::
          :ok
          | {:error, :unknown_signer | :revoked | :untrusted_signer | :bad_signature | :expired}
  def validate(%Sender{} = certificate, trust_roots, now_ms, known \\ %{}) do
    with {:ok, server} <- resolve_signer(certificate.signer, known),
         :ok <- not_revoked(server),
         :ok <- trusted(server, trust_roots),
         :ok <- signed_by(certificate, server),
         :ok <- not_expired(certificate, now_ms) do
      :ok
    end
  end

  defp resolve_signer({:embedded, server}, _known), do: {:ok, server}

  defp resolve_signer({:reference, id}, known) do
    case Map.fetch(known, id) do
      {:ok, server} -> {:ok, server}
      :error -> {:error, :unknown_signer}
    end
  end

  defp not_revoked(%Server{key_id: id}), do: if(revoked?(id), do: {:error, :revoked}, else: :ok)

  defp trusted(%Server{body: body, signature: signature}, roots) do
    if Enum.any?(roots, &Keys.verify_signature(&1, body, signature)),
      do: :ok,
      else: {:error, :untrusted_signer}
  end

  defp signed_by(%Sender{body: body, signature: signature}, %Server{key: key}) do
    if Keys.verify_signature(key, body, signature), do: :ok, else: {:error, :bad_signature}
  end

  defp not_expired(%Sender{expiration: expiration}, now_ms) do
    if now_ms <= expiration, do: :ok, else: {:error, :expired}
  end

  # --- issuing (test servers) ------------------------------------------------

  @doc """
  Issues a server certificate signed by `root_private` (32 bytes). Comma uses
  it only in test servers; the Signal service issues real certificates.
  """
  @spec issue_server(non_neg_integer(), Keys.ec_public(), <<_::256>>, <<_::512>>) :: binary()
  def issue_server(key_id, server_public, root_private, random \\ :crypto.strong_rand_bytes(64)) do
    body =
      Wire.ServerCertificateBody.encode(%Wire.ServerCertificateBody{
        key_id: key_id,
        server_public: server_public
      })

    Wire.Signed.encode(%Wire.Signed{
      body: body,
      signature: XEdDSA.sign(root_private, body, random)
    })
  end

  @doc """
  Issues a sender certificate signed by `server_private`, as the service does
  (CRS-06 §3.6): the ACI in 16-byte form, and the signer embedded
  (`{:embedded, serialized_server_certificate}`) or by reference
  (`{:reference, key_id}`). For test servers only.
  """
  @spec issue_sender(map(), <<_::256>>, <<_::512>>) :: binary()
  def issue_sender(fields, server_private, random \\ :crypto.strong_rand_bytes(64)) do
    {signer, signer_key_id} =
      case fields.signer do
        {:embedded, bytes} -> {bytes, nil}
        {:reference, id} -> {nil, id}
      end

    body =
      Wire.SenderCertificateBody.encode(%Wire.SenderCertificateBody{
        sender_e164: Map.get(fields, :e164),
        sender_device: fields.device_id,
        expiration: fields.expiration,
        identity_key: fields.identity_key,
        signer: signer,
        sender_aci: fields.aci,
        signer_key_id: signer_key_id
      })

    Wire.Signed.encode(%Wire.Signed{
      body: body,
      signature: XEdDSA.sign(server_private, body, random)
    })
  end
end
