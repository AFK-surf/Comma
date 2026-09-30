defmodule SalixSignalProto.Attachment.Pointer do
  @moduledoc """
  The attachment pointer message (CRS-10 section 8, CRS-05 section 5.6).

  Content messages embed it in their attachment lists, quotes, link
  previews and stickers; a content codec can use this module as the field
  type. All fields are optional (proto2). Field names here are descriptive.

  A pointer names its blob by exactly one of `cdn_id` (legacy, CDN 0) and
  `cdn_key`; a pointer with neither is invalid (CRS-05 section 5.6).
  """

  use Protobuf, syntax: :proto2

  field(:cdn_id, 1, optional: true, type: :fixed64)
  field(:content_type, 2, optional: true, type: :string)
  field(:keys, 3, optional: true, type: :bytes)
  field(:size, 4, optional: true, type: :uint32)
  field(:thumbnail, 5, optional: true, type: :bytes)
  field(:digest, 6, optional: true, type: :bytes)
  field(:file_name, 7, optional: true, type: :string)
  field(:flags, 8, optional: true, type: :uint32)
  field(:width, 9, optional: true, type: :uint32)
  field(:height, 10, optional: true, type: :uint32)
  field(:caption, 11, optional: true, type: :string)
  field(:blur_hash, 12, optional: true, type: :string)
  field(:upload_timestamp, 13, optional: true, type: :uint64)
  field(:cdn_number, 14, optional: true, type: :uint32)
  field(:cdn_key, 15, optional: true, type: :string)
  field(:incremental_mac_chunk_size, 17, optional: true, type: :uint32)
  field(:incremental_mac, 19, optional: true, type: :bytes)
  field(:client_uuid, 20, optional: true, type: :bytes)

  import Bitwise

  @voice_message 1
  @borderless 2
  @gif 8

  @doc "Flag bit: the attachment is a voice message."
  def flag_voice_message, do: @voice_message
  @doc "Flag bit: shown without a bubble."
  def flag_borderless, do: @borderless
  @doc "Flag bit: a short looping video without sound or controls."
  def flag_gif, do: @gif

  @doc "True when the voice-message flag is set. Unknown flag bits are ignored."
  @spec voice_message?(t()) :: boolean()
  def voice_message?(%__MODULE__{flags: flags}), do: band(flags || 0, @voice_message) != 0

  @doc "The CDN number; absent means 0."
  @spec cdn(t()) :: non_neg_integer()
  def cdn(%__MODULE__{cdn_number: number}), do: number || 0

  @doc "True when the pointer names its blob by a CDN id or a CDN key."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{cdn_id: id, cdn_key: key}), do: is_integer(id) or is_binary(key)

  @doc """
  Decodes a pointer. Bytes that do not parse, or a pointer without a CDN id
  or key, give `{:error, :invalid}`.
  """
  @spec from_binary(binary()) :: {:ok, t()} | {:error, :invalid}
  def from_binary(bytes) when is_binary(bytes) do
    pointer = decode(bytes)
    if valid?(pointer), do: {:ok, pointer}, else: {:error, :invalid}
  rescue
    _ -> {:error, :invalid}
  end
end
