defmodule SalixSignalProto.SenderKey.Wire.Distribution do
  @moduledoc false
  # Body of the sender key distribution message (CRS-09c section 2). proto2;
  # receivers require all five fields.
  use Protobuf, syntax: :proto2

  field(:distribution_id, 1, optional: true, type: :bytes)
  field(:chain_id, 2, optional: true, type: :uint32)
  field(:iteration, 3, optional: true, type: :uint32)
  field(:chain_key, 4, optional: true, type: :bytes)
  field(:signing_key, 5, optional: true, type: :bytes)
end

defmodule SalixSignalProto.SenderKey.Wire.Message do
  @moduledoc false
  # Body of the sender key message (CRS-09c section 3). proto2.
  use Protobuf, syntax: :proto2

  field(:distribution_id, 1, optional: true, type: :bytes)
  field(:chain_id, 2, optional: true, type: :uint32)
  field(:iteration, 3, optional: true, type: :uint32)
  field(:ciphertext, 4, optional: true, type: :bytes)
end

defmodule SalixSignalProto.SenderKey.Message do
  @moduledoc """
  Sender key wire messages (CRS-09c sections 2 and 3).

  | Message | Layout |
  | --- | --- |
  | Distribution | `0x33 ‖ protobuf{1: distribution ID, 2: chain ID, 3: iteration, 4: chain key, 5: signing key}` |
  | Message | `0x33 ‖ protobuf{1: distribution ID, 2: chain ID, 3: iteration, 4: ciphertext} ‖ signature` |

  The version byte's high nibble is the message version and must be 3; a
  receiver reports `:old_version` below 3 and `:unknown_version` above.
  Both messages are at least 65 bytes. The signature is deployed XEdDSA
  (CRS-03 section 5) by the sender key's signing key over all bytes before
  it. Distribution IDs are the 16 raw UUID bytes; the signing key is the
  33-byte serialized EC public key.

  A sender key message has ciphertext type 7 (CRS-06 section 5).
  """

  alias SalixSignalProto.Crypto.XEdDSA
  alias SalixSignalProto.Keys
  alias SalixSignalProto.SenderKey.Wire

  @version 3
  @version_byte 0x33
  @min_length 65
  @max_chain_id 0x7FFFFFFF

  @doc "The ciphertext message type of a sender key message."
  def ciphertext_type, do: 7

  @type distribution :: %{
          distribution_id: <<_::128>>,
          chain_id: non_neg_integer(),
          iteration: non_neg_integer(),
          chain_key: <<_::256>>,
          signing_key: Keys.ec_public()
        }

  @type message :: %{
          distribution_id: <<_::128>>,
          chain_id: non_neg_integer(),
          iteration: non_neg_integer(),
          ciphertext: binary(),
          signed: binary(),
          signature: <<_::512>>
        }

  @doc "Encodes a distribution message."
  @spec encode_distribution(distribution()) :: binary()
  def encode_distribution(%{
        distribution_id: <<_::binary-size(16)>> = distribution_id,
        chain_id: chain_id,
        iteration: iteration,
        chain_key: <<_::binary-size(32)>> = chain_key,
        signing_key: <<0x05, _::binary-size(32)>> = signing_key
      })
      when chain_id in 0..@max_chain_id and iteration in 0..0xFFFFFFFF do
    body =
      Protobuf.encode(%Wire.Distribution{
        distribution_id: distribution_id,
        chain_id: chain_id,
        iteration: iteration,
        chain_key: chain_key,
        signing_key: signing_key
      })

    <<@version_byte, body::binary>>
  end

  @doc "Decodes a distribution message."
  @spec decode_distribution(binary()) :: {:ok, distribution()} | {:error, atom()}
  def decode_distribution(bytes) when is_binary(bytes) do
    with {:ok, body} <- versioned_body(bytes),
         {:ok, %Wire.Distribution{} = d} <- decode(Wire.Distribution, body),
         <<_::binary-size(16)>> <- d.distribution_id,
         true <- is_integer(d.chain_id) and is_integer(d.iteration),
         <<_::binary-size(32)>> <- d.chain_key,
         <<0x05, _::binary-size(32)>> <- d.signing_key do
      {:ok, Map.take(d, [:distribution_id, :chain_id, :iteration, :chain_key, :signing_key])}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_message}
    end
  end

  @doc """
  Encodes and signs a sender key message with the 32-byte signing private
  key. `random` is the 64-byte XEdDSA randomness.
  """
  @spec encode_message(map(), Keys.ec_private(), <<_::512>>) :: binary()
  def encode_message(
        %{
          distribution_id: <<_::binary-size(16)>> = distribution_id,
          chain_id: chain_id,
          iteration: iteration,
          ciphertext: ciphertext
        },
        <<_::binary-size(32)>> = signing_private,
        random \\ :crypto.strong_rand_bytes(64)
      )
      when is_binary(ciphertext) do
    body =
      Protobuf.encode(%Wire.Message{
        distribution_id: distribution_id,
        chain_id: chain_id,
        iteration: iteration,
        ciphertext: ciphertext
      })

    signed = <<@version_byte, body::binary>>
    signed <> XEdDSA.sign(signing_private, signed, random)
  end

  @doc "Decodes a sender key message without checking its signature."
  @spec decode_message(binary()) :: {:ok, message()} | {:error, atom()}
  def decode_message(bytes) when is_binary(bytes) and byte_size(bytes) >= @min_length do
    signed_size = byte_size(bytes) - 64
    <<signed::binary-size(^signed_size), signature::binary-size(64)>> = bytes

    with {:ok, body} <- version(signed),
         {:ok, %Wire.Message{} = m} <- decode(Wire.Message, body),
         <<_::binary-size(16)>> <- m.distribution_id,
         true <- is_integer(m.chain_id) and is_integer(m.iteration),
         true <- is_binary(m.ciphertext) do
      {:ok,
       %{
         distribution_id: m.distribution_id,
         chain_id: m.chain_id,
         iteration: m.iteration,
         ciphertext: m.ciphertext,
         signed: signed,
         signature: signature
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_message}
    end
  end

  def decode_message(bytes) when is_binary(bytes) do
    case version(bytes) do
      {:ok, _} -> {:error, :invalid_message}
      error -> error
    end
  end

  @doc "Verifies a decoded message's signature with the 33-byte signing key."
  @spec verify(message(), binary()) :: boolean()
  def verify(%{signed: signed, signature: signature}, signing_key),
    do: Keys.verify_signature(signing_key, signed, signature)

  defp versioned_body(bytes) when byte_size(bytes) >= @min_length, do: version(bytes)

  defp versioned_body(bytes) do
    case version(bytes) do
      {:ok, _} -> {:error, :invalid_message}
      error -> error
    end
  end

  defp version(<<byte, body::binary>>) do
    case Bitwise.bsr(byte, 4) do
      @version -> {:ok, body}
      v when v < @version -> {:error, :old_version}
      _ -> {:error, :unknown_version}
    end
  end

  defp version(<<>>), do: {:error, :invalid_message}

  defp decode(module, body) do
    {:ok, Protobuf.decode(body, module)}
  rescue
    _ -> {:error, :invalid_message}
  end
end
