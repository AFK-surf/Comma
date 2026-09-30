defmodule SalixStore.AgentVMMManagedTrustSigning do
  @moduledoc """
  Builds the managed Agent VMM trust signer from the release config.

  The private key protects tenant-scoped membership credentials. The expected
  public key is derived from that independent config value and is persisted as
  the trust anchor; Postgres never owns the signing key. Invalid or incomplete
  signer configuration refuses boot instead of making enrollment fail later.

  The protocol's key ID is the public-key digest. Anchor revision is advanced
  only by a reviewed release when the configured private key is rotated;
  config does not expose a partial rotation control.
  """

  import Bitwise

  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  @authority_prefix "salix-managed"
  # Revision 2 records the 2026-08-28 managed signing-key rotation. Keeping
  # this release-owned prevents an environment variable from relabeling key
  # bytes without changing the durable trust identity.
  @key_revision 2
  @allowed_fields MapSet.new(~w(private_key))

  @spec from_json(nil | map()) :: nil | map()
  def from_json(nil), do: nil

  def from_json(config) when is_map(config) do
    reject_unknown_fields!(config)

    private_key = decode_private_key!(Map.get(config, "private_key"))
    public_key = compressed_public_key!(private_key)
    key_id = "p256:" <> Base.url_encode64(:crypto.hash(:sha256, public_key), padding: false)

    %{
      authority_prefix: @authority_prefix,
      key_id: key_id,
      key_revision: @key_revision,
      public_key: public_key,
      signer: fn payload -> sign_low_s(payload, private_key) end
    }
  end

  def from_json(_) do
    raise ArgumentError, "agent_vmm.managed_trust_signing must be an object"
  end

  defp reject_unknown_fields!(config) do
    unknown =
      config
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(@allowed_fields)
      |> MapSet.to_list()

    if unknown != [] do
      raise ArgumentError,
            "agent_vmm.managed_trust_signing contains unknown fields #{inspect(Enum.sort(unknown))}"
    end
  end

  defp decode_private_key!(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, private_key} when byte_size(private_key) == 32 ->
        private_key

      _ ->
        raise ArgumentError,
              "agent_vmm.managed_trust_signing.private_key must be base64 for exactly 32 bytes"
    end
  end

  defp decode_private_key!(_) do
    raise ArgumentError,
          "agent_vmm.managed_trust_signing.private_key must be base64 for exactly 32 bytes"
  end

  defp compressed_public_key!(private_key) do
    case :crypto.generate_key(:ecdh, :secp256r1, private_key) do
      {<<4, x::binary-size(32), y::binary-size(32)>>, ^private_key} ->
        <<2 + band(:binary.last(y), 1), x::binary>>

      _ ->
        raise ArgumentError,
              "agent_vmm.managed_trust_signing.private_key is not a valid P-256 scalar"
    end
  rescue
    _ ->
      raise ArgumentError,
            "agent_vmm.managed_trust_signing.private_key is not a valid P-256 scalar"
  end

  defp sign_low_s(payload, private_key) when is_binary(payload) do
    der = :crypto.sign(:ecdsa, :sha256, payload, [private_key, :secp256r1])
    <<0x30, _size, 0x02, r_size, rest::binary>> = der
    <<r::binary-size(^r_size), 0x02, s_size, s::binary-size(s_size)>> = rest

    r = r |> :binary.decode_unsigned() |> encode32()
    s_value = :binary.decode_unsigned(s)
    s_value = min(s_value, @p256_order - s_value)
    r <> encode32(s_value)
  end

  defp encode32(value) do
    encoded = :binary.encode_unsigned(value)
    :binary.copy(<<0>>, 32 - byte_size(encoded)) <> encoded
  end
end
