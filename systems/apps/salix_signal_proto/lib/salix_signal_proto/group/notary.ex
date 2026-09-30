defmodule SalixSignalProto.Group.Notary do
  @moduledoc """
  Notary signatures (CRS-09a section 12). The storage service signs each
  group change's action bytes with the notary key; clients verify with
  `PK_sig` at offset 129 of the server public params.

  The signature is the 64-byte proof of `PK_sig = x·B` with the signed bytes
  as the proof message.
  """

  alias SalixSignalProto.Group.Proof
  alias SalixSignalProto.Group.ServerParams
  alias SalixSignalProto.Group.Sho

  @sign_label "Signal_ZKGroup_20200424_Random_ServerSecretParams_Sign"
  @statement [{:pk, [{:x, :base}]}]

  @doc false
  def statement, do: @statement

  @doc "Verifies a notary signature on `message`."
  @spec verify(ServerParams.Public.t(), binary(), binary()) :: boolean()
  def verify(%ServerParams.Public{notary: pk}, message, signature)
      when is_binary(message) and is_binary(signature) do
    byte_size(signature) == 64 and Proof.verify(@statement, %{pk: pk}, message, signature)
  end

  @doc false
  # Test servers only.
  def sign(%ServerParams.Secret{notary: x}, message, randomness \\ :crypto.strong_rand_bytes(32)) do
    {proof_randomness, _state} = @sign_label |> Sho.derive(randomness) |> Sho.squeeze(32)

    Proof.prove(
      @statement,
      %{x: x},
      %{pk: SalixSignalProto.Crypto.Ristretto255.mul_base(x)},
      message,
      proof_randomness
    )
  end
end
