defmodule SalixSignalProto.Session.Message do
  @moduledoc """
  The double-ratchet message, ciphertext type 2 (CRS-04 §7.2):
  `V || P || T`.

  * `V` is one byte: the session version in the high 4 bits, 4 in the low
    4 bits (`0x44` for version 4).
  * `P` is a protocol buffer: ratchet public key (1), message number (2),
    previous chain length (3), encrypted body (4), post-quantum message (5)
    and address binding (6).
  * `T` is the first 8 bytes of `HMAC(MAC key, sender identity || receiver
    identity || V || P)` (CRS-04 §4.5).

  A decoded message keeps its received bytes in `serialized`; the MAC is
  checked over those bytes, never over a re-encoding.
  """

  import Bitwise

  alias SalixSignalProto.Crypto.Hmac
  alias SalixSignalProto.Keys
  alias SalixSignalProto.Session.Wire.DoubleRatchet

  @mac_bytes 8

  defstruct [
    :version,
    :ratchet_key,
    :message_number,
    :previous_chain_length,
    :body,
    :pq_message,
    :address_binding,
    :serialized
  ]

  @type t :: %__MODULE__{
          version: 3 | 4,
          ratchet_key: Keys.ec_public(),
          message_number: non_neg_integer(),
          previous_chain_length: non_neg_integer(),
          body: binary(),
          pq_message: binary() | nil,
          address_binding: binary() | nil,
          serialized: binary()
        }

  @doc """
  Encodes a message and appends its MAC. `pq_message` and `address_binding`
  are emitted only when they are not empty.
  """
  @spec encode(map(), binary(), Keys.ec_public(), Keys.ec_public()) :: binary()
  def encode(fields, mac_key, sender_identity, receiver_identity) do
    proto =
      DoubleRatchet.encode(%DoubleRatchet{
        ratchet_public_key: fields.ratchet_key,
        message_number: fields.message_number,
        previous_chain_length: fields.previous_chain_length,
        encrypted_body: fields.body,
        post_quantum_message: non_empty(Map.get(fields, :pq_message)),
        address_binding: non_empty(Map.get(fields, :address_binding))
      })

    unsigned = <<fields.version <<< 4 ||| 4>> <> proto
    unsigned <> mac(mac_key, sender_identity, receiver_identity, unsigned)
  end

  @doc """
  Decodes a double-ratchet message (CRS-04 §7.2 receiver rules 1 to 3). The
  MAC is not checked here.
  """
  @spec decode(binary()) ::
          {:ok, t()}
          | {:error, :too_short | :legacy_version | :unknown_version | :malformed}
  def decode(bytes) when is_binary(bytes) and byte_size(bytes) < 1 + @mac_bytes,
    do: {:error, :too_short}

  def decode(<<v, rest::binary>> = bytes) do
    proto = binary_part(rest, 0, byte_size(rest) - @mac_bytes)

    with {:ok, version} <- version(v),
         {:ok, decoded} <- decode_proto(DoubleRatchet, proto),
         %DoubleRatchet{
           ratchet_public_key: ratchet_key,
           message_number: number,
           encrypted_body: body
         }
         when is_binary(ratchet_key) and is_integer(number) and is_binary(body) <- decoded,
         {:ok, ratchet_key} <- Keys.parse_ec_public(ratchet_key) do
      {:ok,
       %__MODULE__{
         version: version,
         ratchet_key: ratchet_key,
         message_number: number,
         previous_chain_length: decoded.previous_chain_length || 0,
         body: body,
         pq_message: non_empty(decoded.post_quantum_message),
         address_binding: decoded.address_binding,
         serialized: bytes
       }}
    else
      {:error, reason} when reason in [:legacy_version, :unknown_version] -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  @doc """
  True when the last 8 bytes of the received message equal its MAC under
  `mac_key`, compared in constant time.
  """
  @spec valid_mac?(t(), binary(), Keys.ec_public(), Keys.ec_public()) :: boolean()
  def valid_mac?(%__MODULE__{serialized: bytes}, mac_key, sender_identity, receiver_identity) do
    unsigned_size = byte_size(bytes) - @mac_bytes
    <<unsigned::binary-size(^unsigned_size), tag::binary-size(@mac_bytes)>> = bytes
    Hmac.equal?(tag, mac(mac_key, sender_identity, receiver_identity, unsigned))
  end

  defp mac(mac_key, sender_identity, receiver_identity, unsigned) do
    mac_key
    |> Hmac.sha256([sender_identity, receiver_identity, unsigned])
    |> binary_part(0, @mac_bytes)
  end

  @doc false
  # Version rules shared with the pre-key message (CRS-04 §7.2 item 2).
  def version(v) do
    case v >>> 4 do
      version when version < 3 -> {:error, :legacy_version}
      version when version > 4 -> {:error, :unknown_version}
      version -> {:ok, version}
    end
  end

  @doc false
  def decode_proto(module, bytes) do
    {:ok, module.decode(bytes)}
  rescue
    # The decoder raises on malformed input; every such input is rejected.
    _error -> {:error, :malformed}
  end

  defp non_empty(value) when value in [nil, ""], do: nil
  defp non_empty(value), do: value
end
