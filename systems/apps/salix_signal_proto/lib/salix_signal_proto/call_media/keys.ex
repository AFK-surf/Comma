defmodule SalixSignalProto.CallMedia.Keys do
  @moduledoc """
  SRTP master keys of a 1:1 call (CRS-13 section 4).

  Each side sends a fresh 32-byte X25519 public key in its connection
  parameters (the offer for the caller, the answer for each callee device).
  Both sides compute the same 88 bytes:

      shared = X25519(own ephemeral private key, peer ephemeral public key)
      info   = label || caller identity key || callee identity key
      okm    = HKDF-SHA256(salt = 32 zero bytes, ikm = shared, info, L = 88)

  The identity keys are the 32-byte ACI identity public keys without the type
  byte, the caller's first on both sides. `okm` splits into the caller's
  master key and salt (bytes 0..43) and the callee's (bytes 44..87). A side
  protects the media it sends with its own pair and verifies the peer's media
  with the peer's pair.

  An all-zero shared secret (a low-order peer key) rejects the call.
  """

  alias SalixSignalProto.CallMedia
  alias SalixSignalProto.Crypto.{Hkdf, X25519}

  @label "Signal_Calling_20200807_SignallingDH_SRTPKey_KDF"
  @okm_bytes 88

  @type master :: %{key: <<_::256>>, salt: <<_::96>>}
  @type t :: %{send: master(), receive: master()}

  @doc "The 48-byte HKDF label (CRS-13 section 4.1)."
  def label, do: @label

  @doc "Returns `{public_key, private_key}`: a fresh ephemeral key pair for one offer or answer."
  @spec generate_keypair() :: {<<_::256>>, <<_::256>>}
  def generate_keypair, do: X25519.keypair()

  @doc "The raw 32-byte X25519 public key of `private_key`."
  @spec public_key(<<_::256>>) :: <<_::256>>
  def public_key(private_key), do: X25519.public_key(private_key)

  @doc """
  Derives the SRTP master keys for `role`.

  `own_private` is this side's ephemeral private key, `peer_public` the
  peer's ephemeral public key from its connection parameters, and
  `caller_identity` and `callee_identity` the two 32-byte identity keys.
  """
  @spec derive(CallMedia.role(), binary(), binary(), binary(), binary()) ::
          {:ok, t()} | {:error, :invalid_public_key | :invalid_identity_key}
  def derive(role, own_private, peer_public, caller_identity, callee_identity)
      when role in [:caller, :callee] do
    with :ok <- identity_key(caller_identity),
         :ok <- identity_key(callee_identity),
         {:ok, okm} <- okm(own_private, peer_public, caller_identity, callee_identity) do
      <<offer_key::binary-32, offer_salt::binary-12, answer_key::binary-32,
        answer_salt::binary-12>> = okm

      caller = %{key: offer_key, salt: offer_salt}
      callee = %{key: answer_key, salt: answer_salt}

      case role do
        :caller -> {:ok, %{send: caller, receive: callee}}
        :callee -> {:ok, %{send: callee, receive: caller}}
      end
    end
  end

  @doc """
  The 88 bytes of HKDF output before the split. Exposed for vector and
  differential tests.
  """
  @spec okm(binary(), binary(), binary(), binary()) ::
          {:ok, <<_::704>>} | {:error, :invalid_public_key}
  def okm(own_private, peer_public, caller_identity, callee_identity) do
    with {:ok, shared} <- shared_secret(own_private, peer_public) do
      info = [@label, caller_identity, callee_identity]
      {:ok, Hkdf.derive(shared, <<0::256>>, info, @okm_bytes)}
    end
  end

  defp shared_secret(<<_::binary-32>> = own_private, peer_public) do
    case X25519.dh(own_private, peer_public) do
      {:ok, <<0::256>>} -> {:error, :invalid_public_key}
      {:ok, shared} -> {:ok, shared}
      {:error, _reason} -> {:error, :invalid_public_key}
    end
  end

  defp shared_secret(_own_private, _peer_public), do: {:error, :invalid_public_key}

  defp identity_key(<<_::binary-32>>), do: :ok
  defp identity_key(_key), do: {:error, :invalid_identity_key}
end
