defmodule SalixSignalProto.Message.DecryptionError do
  @moduledoc """
  The decryption error message and its plaintext wrapper (CRS-05 §7, CRS-07
  §6).

  A receiver that cannot decrypt a message sends the sender a decryption
  error message: the ratchet key of the failed 1:1 message (absent for a
  sender-key message), the failed envelope's client timestamp and the sender
  device ID. It normally travels unencrypted in the plaintext wrapper
  `0xC0 || content container {8: message} || 0x80`.
  """

  alias SalixSignalProto.Keys
  alias SalixSignalProto.Message.Content
  alias SalixSignalProto.Message.Padding
  alias SalixSignalProto.Message.Wire
  alias SalixSignalProto.Session.Message
  alias SalixSignalProto.Session.PreKeyMessage

  @wrapper_marker 0xC0

  defstruct [:ratchet_key, :timestamp, :device_id]

  @type t :: %__MODULE__{
          ratchet_key: Keys.ec_public() | nil,
          timestamp: non_neg_integer(),
          device_id: non_neg_integer() | nil
        }

  @typedoc """
  The type of the failed ciphertext: `:whisper` (envelope kind 1, sealed
  inner type 2), `:prekey` (kind 3, inner type 1), `:sender_key` (inner type
  7) or `:plaintext` (kind 8, inner type 8).
  """
  @type failed_type :: :whisper | :prekey | :sender_key | :plaintext

  @doc """
  Builds the serialized decryption error message for a failed ciphertext.
  Returns `{:error, :not_encrypted}` for a plaintext wrapper, which was not
  encrypted, and `{:error, :malformed}` when a 1:1 ciphertext does not parse,
  so that its ratchet key is unknown.
  """
  @spec build(binary(), failed_type(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :not_encrypted | :malformed}
  def build(original, type, timestamp, device_id)
      when is_binary(original) and is_integer(timestamp) and is_integer(device_id) do
    with {:ok, ratchet_key} <- ratchet_key(original, type) do
      {:ok,
       encode(%__MODULE__{ratchet_key: ratchet_key, timestamp: timestamp, device_id: device_id})}
    end
  end

  defp ratchet_key(_original, :plaintext), do: {:error, :not_encrypted}
  defp ratchet_key(_original, :sender_key), do: {:ok, nil}

  defp ratchet_key(original, :whisper) do
    case Message.decode(original) do
      {:ok, message} -> {:ok, message.ratchet_key}
      {:error, _} -> {:error, :malformed}
    end
  end

  defp ratchet_key(original, :prekey) do
    case PreKeyMessage.decode(original) do
      {:ok, message} -> {:ok, message.message.ratchet_key}
      {:error, _} -> {:error, :malformed}
    end
  end

  @doc "Encodes a decryption error message (fields 1, 2, 3 in that order)."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = message) do
    Wire.DecryptionErrorMessage.encode(%Wire.DecryptionErrorMessage{
      ratchet_key: message.ratchet_key,
      timestamp: message.timestamp,
      device_id: message.device_id
    })
  end

  @doc """
  Decodes a decryption error message. The timestamp (field 2) is required; a
  ratchet key, when present, must parse as an EC public key.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, %Wire.DecryptionErrorMessage{timestamp: timestamp} = wire}
         when is_integer(timestamp) <-
           Content.safe_decode(Wire.DecryptionErrorMessage, bytes),
         {:ok, ratchet_key} <- optional_key(wire.ratchet_key) do
      {:ok,
       %__MODULE__{ratchet_key: ratchet_key, timestamp: timestamp, device_id: wire.device_id}}
    else
      _ -> {:error, :malformed}
    end
  end

  def decode(_bytes), do: {:error, :malformed}

  defp optional_key(nil), do: {:ok, nil}
  defp optional_key(bytes), do: Keys.parse_ec_public(bytes)

  @doc "Wraps a serialized decryption error message in the plaintext wrapper."
  @spec wrap(binary()) :: binary()
  def wrap(message) when is_binary(message) do
    content = Wire.Content.encode(%Wire.Content{decryption_error: message})
    <<@wrapper_marker>> <> content <> <<0x80>>
  end

  @doc """
  Opens a plaintext wrapper: removes `0xC0` and the padding and parses the
  content container. A wrapper whose container has anything but field 8 is
  invalid (CRS-05 §7). Returns the serialized decryption error message.
  """
  @spec unwrap(binary()) :: {:ok, binary()} | {:error, :malformed}
  def unwrap(<<@wrapper_marker, padded::binary>>) do
    with {:ok, content} <- Padding.unpad(padded),
         {:ok, :decryption_error, %Wire.Content{decryption_error: message} = wire} <-
           Content.decode(content),
         true <- wire.sender_key_distribution == nil and wire.pni_signature == nil do
      {:ok, message}
    else
      _ -> {:error, :malformed}
    end
  end

  def unwrap(_bytes), do: {:error, :malformed}
end
