defmodule SalixSignalProto.Session.PreKeyMessage do
  @moduledoc """
  The pre-key message, ciphertext type 3 (CRS-04 §7.3): `V || P` with no MAC
  of its own. The inner double-ratchet message carries the MAC.

  Fields of `P`: one-time EC pre-key ID (1, optional), initiator ephemeral
  key (2), initiator identity key (3), inner message (4), registration ID
  (5, absent means 0), signed EC pre-key ID (6), KEM pre-key ID (7) and KEM
  ciphertext (8). Fields 7 and 8 are both present or both absent, and both
  present in version 4.
  """

  import Bitwise

  alias SalixSignalProto.Keys
  alias SalixSignalProto.Session.Message
  alias SalixSignalProto.Session.Wire.PreKey

  defstruct [
    :version,
    :one_time_pre_key_id,
    :base_key,
    :identity_key,
    :message,
    :registration_id,
    :signed_pre_key_id,
    :kem_pre_key_id,
    :kem_ciphertext,
    :serialized
  ]

  @type t :: %__MODULE__{
          version: 3 | 4,
          one_time_pre_key_id: non_neg_integer() | nil,
          base_key: Keys.ec_public(),
          identity_key: Keys.ec_public(),
          message: Message.t(),
          registration_id: non_neg_integer(),
          signed_pre_key_id: non_neg_integer(),
          kem_pre_key_id: non_neg_integer() | nil,
          kem_ciphertext: binary() | nil,
          serialized: binary()
        }

  @doc """
  Encodes a pre-key message around the already encoded inner message.
  """
  @spec encode(map()) :: binary()
  def encode(fields) do
    proto =
      PreKey.encode(%PreKey{
        one_time_pre_key_id: fields.one_time_pre_key_id,
        initiator_ephemeral_key: fields.base_key,
        initiator_identity_key: fields.identity_key,
        inner_message: fields.message,
        registration_id: fields.registration_id,
        signed_pre_key_id: fields.signed_pre_key_id,
        kem_pre_key_id: fields.kem_pre_key_id,
        kem_ciphertext: fields.kem_ciphertext
      })

    <<fields.version <<< 4 ||| 4>> <> proto
  end

  @doc """
  Decodes a pre-key message (CRS-04 §7.3 receiver rules 1, 2 and 4). A
  version-3 message decodes; the session layer rejects it for a new session.
  """
  @spec decode(binary()) ::
          {:ok, t()} | {:error, :legacy_version | :unknown_version | :malformed}
  def decode(<<v, proto::binary>> = bytes) do
    with {:ok, version} <- Message.version(v),
         {:ok, decoded} <- Message.decode_proto(PreKey, proto),
         %PreKey{
           initiator_ephemeral_key: base_key,
           initiator_identity_key: identity_key,
           inner_message: inner,
           signed_pre_key_id: signed_pre_key_id
         }
         when is_binary(base_key) and is_binary(identity_key) and is_binary(inner) and
                is_integer(signed_pre_key_id) <- decoded,
         :ok <- check_kem_fields(version, decoded),
         {:ok, base_key} <- Keys.parse_ec_public(base_key),
         {:ok, identity_key} <- Keys.parse_ec_public(identity_key),
         {:ok, message} <- Message.decode(inner) do
      {:ok,
       %__MODULE__{
         version: version,
         one_time_pre_key_id: decoded.one_time_pre_key_id,
         base_key: base_key,
         identity_key: identity_key,
         message: message,
         registration_id: decoded.registration_id || 0,
         signed_pre_key_id: signed_pre_key_id,
         kem_pre_key_id: decoded.kem_pre_key_id,
         kem_ciphertext: decoded.kem_ciphertext,
         serialized: bytes
       }}
    else
      {:error, reason} when reason in [:legacy_version, :unknown_version] -> {:error, reason}
      _ -> {:error, :malformed}
    end
  end

  def decode(bytes) when is_binary(bytes), do: {:error, :malformed}

  defp check_kem_fields(version, %PreKey{kem_pre_key_id: id, kem_ciphertext: ciphertext}) do
    case {is_nil(id), is_nil(ciphertext)} do
      {false, false} -> :ok
      {true, true} when version < 4 -> :ok
      _ -> :error
    end
  end
end
