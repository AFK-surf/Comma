defmodule SalixStore.Crypto do
  @moduledoc """
  Hashing for key derivation and content addressing.

  Salix uses SHA-256 behind this single seam for inbox keys, content addresses,
  and short shard labels. Inbox keys are internal to Salix (derived from
  `source_message_id`), so the choice of hash does not affect cross-system
  compatibility.
  """

  @runtime_capability_aad "salix.compute.runtime.input.capability.v1"
  @install_material_aad "salix.agent-vmm.install-material.v1"

  @doc "Lowercase hex digest used for deterministic, content-addressed keys."
  @spec hex(iodata()) :: String.t()
  def hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @doc "Short (8 hex char) digest for spill-chunk addressing."
  @spec short(iodata()) :: String.t()
  def short(data), do: hex(data) |> binary_part(0, 8)

  @doc "Envelope-encrypt a short-lived runtime delivery capability for storage."
  @spec seal_runtime_capability(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def seal_runtime_capability(token) when is_binary(token) and token != "" do
    with {:ok, key} <- runtime_capability_key() do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, token, @runtime_capability_aad, true)

      {:ok, "v1." <> Base.url_encode64(iv <> tag <> ciphertext, padding: false)}
    end
  end

  def seal_runtime_capability(nil), do: {:ok, nil}
  def seal_runtime_capability(_), do: {:error, :invalid_runtime_capability}

  @doc "Decrypt a runtime delivery capability only at the carrier delivery boundary."
  @spec unseal_runtime_capability(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def unseal_runtime_capability("v1." <> encoded) do
    with {:ok, key} <- runtime_capability_key(),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @runtime_capability_aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> {:error, :invalid_runtime_capability_ciphertext}
    end
  rescue
    _ -> {:error, :invalid_runtime_capability_ciphertext}
  end

  def unseal_runtime_capability(_), do: {:error, :invalid_runtime_capability_ciphertext}

  @doc "Envelope-encrypt one bounded Agent VMM install exchange response."
  def seal_install_material(material) when is_binary(material) and material != "" do
    with {:ok, key} <- derived_key("agent-vmm-install-material-seal") do
      iv = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, material, @install_material_aad, true)

      {:ok, "v1." <> Base.url_encode64(iv <> tag <> ciphertext, padding: false)}
    end
  end

  def seal_install_material(_), do: {:error, :invalid_install_material}

  @doc "Decrypt install material only while its ticket recovery window is open."
  def unseal_install_material("v1." <> encoded) do
    with {:ok, key} <- derived_key("agent-vmm-install-material-seal"),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @install_material_aad,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _ -> {:error, :invalid_install_material_ciphertext}
    end
  rescue
    _ -> {:error, :invalid_install_material_ciphertext}
  end

  def unseal_install_material(_), do: {:error, :invalid_install_material_ciphertext}

  # Reuse the deployment's existing credential root with a separate purpose.
  # Tenant-bound AEAD prevents copying a configuration token into another
  # tenant's record. Decryption is only used by the admin sync boundary.
  def seal_slack_configuration(value, tenant_id) do
    with {:ok, key} <- derived_key("slack-configuration-seal") do
      iv = :crypto.strong_rand_bytes(12)
      aad = "slack-configuration-v1:" <> tenant_id
      {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, aad, true)
      {:ok, "v1." <> Base.url_encode64(iv <> tag <> ciphertext, padding: false)}
    end
  end

  def unseal_slack_configuration("v1." <> encoded, tenant_id) do
    with {:ok, key} <- derived_key("slack-configuration-seal"),
         {:ok, <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         value when is_binary(value) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             "slack-configuration-v1:" <> tenant_id,
             tag,
             false
           ) do
      {:ok, value}
    else
      _ -> {:error, :configuration_credentials_unavailable}
    end
  rescue
    _ -> {:error, :configuration_credentials_unavailable}
  end

  def unseal_slack_configuration(_, _), do: {:error, :configuration_credentials_unavailable}

  defp runtime_capability_key do
    derived_key("runtime-capability-seal")
  end

  @doc """
  Derive a 32-byte key for one `purpose` from the deployment credential root.
  Each purpose gets an independent key; callers never share a purpose string.
  """
  @spec derived_key(String.t()) :: {:ok, binary()} | {:error, :credential_sealer_unavailable}
  def derived_key(purpose) when is_binary(purpose) do
    case Application.get_env(:salix_store, :compute_workload_credential_secret) do
      secret when is_binary(secret) and byte_size(secret) >= 32 ->
        {:ok, :crypto.hash(:sha256, purpose <> "\0" <> secret)}

      _ ->
        {:error, :credential_sealer_unavailable}
    end
  end

  @doc """
  256-way shard label for an agent id (2 hex chars). Historically spread the
  staged queue-marker PUT rate across sharded prefixes; that key family
  retired with A2 §3.4, and the remaining caller is the hierarchy-identity
  migration reproducing the historical layout it transforms.
  """
  @spec shard(String.t()) :: String.t()
  def shard(agent_id) do
    <<byte, _::binary>> = :crypto.hash(:sha256, agent_id)
    Integer.to_string(byte, 16) |> String.downcase() |> String.pad_leading(2, "0")
  end
end
