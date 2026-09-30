defmodule SalixSignal.Storage.Cipher do
  @moduledoc """
  Encryption at rest of the Signal tables (PLAN "Durable state").

  The dedicated Signal storage key is derived with HKDF-SHA256 (RFC 5869)
  from the existing subscription storage key (`config :salix_agent,
  :subscription_storage_key`) under a Signal-specific label (owner decision:
  no new configuration). It gives two keys, again through HKDF: an
  AES-256-GCM key for row data and an HMAC-SHA256 key for blind indexes.

  * `seal/3` encrypts an Erlang term. The additional data binds the
    ciphertext to its table, account and row key, so a row copied to
    another place does not decrypt. Layout: `0x01 ‖ iv (12) ‖ tag (16) ‖
    ciphertext`.
  * `open/3` decrypts and decodes; the term is decoded only after the tag
    verifies, and only with atoms that already exist.
  * `index/3` is the blind index of a lookup key, for columns that would
    otherwise hold remote service IDs, group identifiers or message
    identities in plain text.

  Without a configured key every function returns
  `{:error, :storage_key_missing}`: Signal state is never written or read
  unencrypted.
  """

  @version 1
  @aad_prefix "salix.signal.storage.v1"

  @type keys :: %{data: <<_::256>>, index: <<_::256>>}

  @doc "The derived keys, or `{:error, :storage_key_missing}`."
  @spec keys() :: {:ok, keys()} | {:error, :storage_key_missing}
  def keys do
    case Application.get_env(:salix_agent, :subscription_storage_key) do
      <<_::binary-size(32)>> = subscription_key ->
        root =
          SalixSignalProto.Crypto.Hkdf.derive(
            subscription_key,
            "",
            "salix.signal.storage.key.v1",
            32
          )

        {:ok,
         %{
           data: SalixSignalProto.Crypto.Hkdf.derive(root, "", "salix.signal.storage.data", 32),
           index: SalixSignalProto.Crypto.Hkdf.derive(root, "", "salix.signal.storage.index", 32)
         }}

      _ ->
        {:error, :storage_key_missing}
    end
  end

  @doc "Encrypts `term` for the row `(table, account_id, row_key)`."
  @spec seal(keys(), {atom(), String.t(), binary()}, term()) :: binary()
  def seal(%{data: key}, {table, account_id, row_key}, term) do
    iv = :crypto.strong_rand_bytes(12)
    plaintext = :erlang.term_to_binary(term)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        iv,
        plaintext,
        aad(table, account_id, row_key),
        true
      )

    <<@version, iv::binary, tag::binary, ciphertext::binary>>
  end

  @doc "Decrypts a sealed row. `{:error, :undecryptable}` for a wrong key, row or format."
  @spec open(keys(), {atom(), String.t(), binary()}, binary()) ::
          {:ok, term()} | {:error, :undecryptable}
  def open(
        %{data: key},
        {table, account_id, row_key},
        <<@version, iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>
      ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           key,
           iv,
           ciphertext,
           aad(table, account_id, row_key),
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, :erlang.binary_to_term(plaintext, [:safe])}
      :error -> {:error, :undecryptable}
    end
  rescue
    ArgumentError -> {:error, :undecryptable}
  end

  def open(_keys, _row, _bytes), do: {:error, :undecryptable}

  @doc "The blind index of `term` in `table` for `account_id`: 32 bytes."
  @spec index(keys(), atom(), String.t(), term()) :: <<_::256>>
  def index(%{index: key}, table, account_id, term) do
    :crypto.mac(
      :hmac,
      :sha256,
      key,
      [Atom.to_string(table), 0, account_id, 0, :erlang.term_to_binary(term, [:deterministic])]
    )
  end

  defp aad(table, account_id, row_key),
    do: [@aad_prefix, 0, Atom.to_string(table), 0, account_id, 0, row_key]
end
