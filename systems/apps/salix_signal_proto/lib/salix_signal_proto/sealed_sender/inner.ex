defmodule SalixSignalProto.SealedSender.Inner do
  @moduledoc """
  The sealed inner message (CRS-06 §5): the plaintext of both sealed sender
  versions.

  | Inner type | Content | Envelope kind equivalent |
  | --- | --- | --- |
  | 1 (`:prekey`) | pre-key 1:1 message (CRS-04) | 3 |
  | 2 (`:whisper`) | double-ratchet 1:1 message (CRS-04) | 1 |
  | 7 (`:sender_key`) | sender-key message (CRS-09) | none |
  | 8 (`:plaintext`) | plaintext wrapper (CRS-05 §7) | 8 |

  Content hints (§5.1): 0 default (field omitted), 1 resendable, 2 implicit.
  Other values are kept unchanged and treated like default.
  """

  alias SalixSignalProto.SealedSender.Certificate
  alias SalixSignalProto.SealedSender.Wire

  @types %{1 => :prekey, 2 => :whisper, 7 => :sender_key, 8 => :plaintext}
  @numbers Map.new(@types, fn {number, type} -> {type, number} end)

  @enforce_keys [:type, :certificate, :content]
  defstruct [:type, :certificate, :content, content_hint: 0, group_id: nil]

  @type type :: :prekey | :whisper | :sender_key | :plaintext

  @type t :: %__MODULE__{
          type: type(),
          certificate: Certificate.Sender.t(),
          content: binary(),
          content_hint: non_neg_integer(),
          group_id: binary() | nil
        }

  @doc "The content hint number of `:default`, `:resendable` or `:implicit`."
  def hint(:default), do: 0
  def hint(:resendable), do: 1
  def hint(:implicit), do: 2

  @doc "The inner type number of a type."
  @spec type_number(type()) :: 1 | 2 | 7 | 8
  def type_number(type), do: Map.fetch!(@numbers, type)

  @doc """
  The inner type of a 1:1 ciphertext type from `SalixSignalProto.Session`
  (2 = double-ratchet, 3 = pre-key).
  """
  @spec from_session_type(2 | 3) :: :whisper | :prekey
  def from_session_type(2), do: :whisper
  def from_session_type(3), do: :prekey

  @doc """
  Encodes an inner message. The hint is omitted when it is 0, and the group
  ID when it is nil (CRS-06 §5).
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = inner) do
    Wire.InnerMessage.encode(%Wire.InnerMessage{
      inner_type: type_number(inner.type),
      sender_certificate: inner.certificate.serialized,
      inner_content: inner.content,
      content_hint: if(inner.content_hint != 0, do: inner.content_hint),
      group_id: inner.group_id
    })
  end

  @doc """
  Decodes an inner message. A missing or unknown inner type, a missing
  certificate or content, or a certificate that does not parse fails.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed}
  def decode(bytes) when is_binary(bytes) do
    with {:ok,
          %Wire.InnerMessage{inner_type: number, sender_certificate: cert, inner_content: content} =
            wire}
         when is_binary(cert) and is_binary(content) <- safe_decode(bytes),
         {:ok, type} <- Map.fetch(@types, number),
         {:ok, certificate} <- Certificate.decode_sender(cert) do
      {:ok,
       %__MODULE__{
         type: type,
         certificate: certificate,
         content: content,
         content_hint: wire.content_hint || 0,
         group_id: wire.group_id
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  defp safe_decode(bytes) do
    {:ok, Wire.InnerMessage.decode(bytes)}
  rescue
    # The protobuf decoder raises on malformed input.
    _error -> :error
  end
end
