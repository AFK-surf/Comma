defmodule SalixSignalProto.Session.Pqxdh do
  @moduledoc """
  PQXDH as deployed (CRS-04 §3; public specification: PQXDH).

  The secret input is `0xFF * 32 || DH1 || DH2 || DH3 [|| DH4] || SS` with

  * `DH1 = X25519(IK_A, SPK_B)`, `DH2 = X25519(EK_A, IK_B)`,
    `DH3 = X25519(EK_A, SPK_B)`, `DH4 = X25519(EK_A, OPK_B)` when the bundle
    has a one-time pre-key;
  * `SS` the Kyber1024 round-3 shared secret for the KEM pre-key.

  `HKDF(no salt, S, "WhisperText_X25519_SHA-256_CRYSTALS-KYBER-1024", 96)`
  gives the first root key (bytes 0 to 31), the first chain key (32 to 63)
  and the start secret of the post-quantum ratchet (64 to 95).
  """

  alias SalixSignalProto.Crypto.Hkdf
  alias SalixSignalProto.Keys

  @label "WhisperText_X25519_SHA-256_CRYSTALS-KYBER-1024"
  @prefix :binary.copy(<<0xFF>>, 32)

  @type result :: %{root_key: <<_::256>>, chain_key: <<_::256>>, pq_secret: <<_::256>>}

  @doc """
  The initiator side. `keys` holds `identity_private`, `ephemeral_private`
  and the bundle's `identity_key`, `signed_pre_key`, `one_time_pre_key`
  (nil when absent) and `kem_pre_key`. `kem_random` is the 32-byte
  encapsulation input. Returns the derived keys and the serialized KEM
  ciphertext.
  """
  @spec initiate(map(), <<_::256>>) ::
          {:ok, result(), Keys.kem_ciphertext()} | {:error, :invalid_key}
  def initiate(keys, kem_random) do
    with {:ok, dh1} <- Keys.agree(keys.identity_private, keys.signed_pre_key),
         {:ok, dh2} <- Keys.agree(keys.ephemeral_private, keys.identity_key),
         {:ok, dh3} <- Keys.agree(keys.ephemeral_private, keys.signed_pre_key),
         {:ok, dh4} <- optional_agree(keys.ephemeral_private, keys.one_time_pre_key),
         {:ok, {shared, ciphertext}} <- Keys.kem_encapsulate(keys.kem_pre_key, kem_random) do
      {:ok, derive([dh1, dh2, dh3, dh4], shared), ciphertext}
    end
  end

  @doc """
  The responder side. `keys` holds `identity_private`,
  `signed_pre_key_private`, `one_time_pre_key_private` (nil when the message
  names none), `kem_secret`, and the message's `identity_key`, `base_key`
  and `kem_ciphertext`.
  """
  @spec respond(map()) :: {:ok, result()} | {:error, :invalid_key}
  def respond(keys) do
    with {:ok, dh1} <- Keys.agree(keys.signed_pre_key_private, keys.identity_key),
         {:ok, dh2} <- Keys.agree(keys.identity_private, keys.base_key),
         {:ok, dh3} <- Keys.agree(keys.signed_pre_key_private, keys.base_key),
         {:ok, dh4} <- optional_agree(keys.one_time_pre_key_private, keys.base_key),
         {:ok, shared} <- Keys.kem_decapsulate(keys.kem_secret, keys.kem_ciphertext) do
      {:ok, derive([dh1, dh2, dh3, dh4], shared)}
    end
  end

  @doc "The secret input `S` for the given DH values and KEM shared secret."
  @spec secret_input([binary() | nil], binary()) :: binary()
  def secret_input(dh_values, kem_shared),
    do: IO.iodata_to_binary([@prefix, Enum.reject(dh_values, &is_nil/1), kem_shared])

  defp derive(dh_values, kem_shared) do
    <<root_key::binary-size(32), chain_key::binary-size(32), pq_secret::binary-size(32)>> =
      dh_values |> secret_input(kem_shared) |> Hkdf.derive("", @label, 96)

    %{root_key: root_key, chain_key: chain_key, pq_secret: pq_secret}
  end

  defp optional_agree(_private, nil), do: {:ok, nil}
  defp optional_agree(nil, _public), do: {:ok, nil}
  defp optional_agree(private, public), do: Keys.agree(private, public)
end
