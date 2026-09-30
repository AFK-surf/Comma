defmodule SalixSignalProto.Session.Kdf do
  @moduledoc """
  Key derivations of the EC Double Ratchet as deployed (CRS-04 §4).

  * Root step: `HKDF(salt = root key, ikm = X25519(ours, theirs),
    "WhisperRatchet", 64)` gives the new root key and a new chain key.
  * Chain step: message-key seed `HMAC(CK, 0x01)`, next chain key
    `HMAC(CK, 0x02)`.
  * Message keys: `HKDF(salt = post-quantum key, ikm = seed,
    "WhisperMessageKeys", 80)` gives the cipher key (32), MAC key (32) and
    IV (16). Without a post-quantum key HKDF runs with no salt.
  """

  alias SalixSignalProto.Crypto.Hkdf
  alias SalixSignalProto.Crypto.Hmac
  alias SalixSignalProto.Keys

  @root_label "WhisperRatchet"
  @message_keys_label "WhisperMessageKeys"

  @type message_keys :: %{cipher_key: <<_::256>>, mac_key: <<_::256>>, iv: <<_::128>>}

  @doc """
  The root step (CRS-04 §4.1). Returns `{:ok, {root_key, chain_key}}`, or
  `{:error, :invalid_key}` when the agreement fails.
  """
  @spec root_step(<<_::256>>, <<_::256>>, Keys.ec_public()) ::
          {:ok, {<<_::256>>, <<_::256>>}} | {:error, :invalid_key}
  def root_step(root_key, our_private, their_public) do
    with {:ok, shared} <- Keys.agree(our_private, their_public) do
      <<root::binary-size(32), chain::binary-size(32)>> =
        Hkdf.derive(shared, root_key, @root_label, 64)

      {:ok, {root, chain}}
    end
  end

  @doc "The message-key seed of a chain key (CRS-04 §4.2)."
  @spec seed(<<_::256>>) :: <<_::256>>
  def seed(chain_key), do: Hmac.sha256(chain_key, <<0x01>>)

  @doc "The next chain key (CRS-04 §4.2)."
  @spec next(<<_::256>>) :: <<_::256>>
  def next(chain_key), do: Hmac.sha256(chain_key, <<0x02>>)

  @doc """
  Expands a message-key seed (CRS-04 §4.3). `pq_key` is the post-quantum
  message key, or nil in a session without the post-quantum ratchet.
  """
  @spec message_keys(<<_::256>>, binary() | nil) :: message_keys()
  def message_keys(seed, pq_key) do
    <<cipher_key::binary-size(32), mac_key::binary-size(32), iv::binary-size(16)>> =
      Hkdf.derive(seed, pq_key || "", @message_keys_label, 80)

    %{cipher_key: cipher_key, mac_key: mac_key, iv: iv}
  end
end
