defmodule SalixStore.AgentVMMInstallMaterial do
  @moduledoc """
  Builds one bounded Agent VMM registration enrollment plan.

  The Host binary is installed through the Server-bound artifact path before
  this operation starts. Remote enrollment uses the configured gateway and Pool policy.
  """

  @max_trust_bundle_bytes 64_000
  alias SalixStore.Compute

  @spec issue(map(), map()) :: {:ok, map()} | {:error, atom()}
  def issue(operation, enrollment) when is_map(operation) and is_map(enrollment) do
    with {:ok, catalog} <- catalog(),
         {:ok, remote_policy} <- Compute.agent_vmm_remote_policy(operation.environment_id),
         {:ok, remote} <- remote_enrollment(catalog, enrollment, remote_policy),
         {:ok, scope_digest} <- scope_digest(operation),
         registration_id when is_binary(registration_id) <- enrollment.registration_id do
      {:ok,
       %{
         version: 1,
         operation_id: operation.id,
         registration_id: registration_id,
         scope_digest: scope_digest,
         remote_enrollment: remote
       }}
    else
      _ -> {:error, :install_material_unavailable}
    end
  end

  def issue(_operation, _enrollment), do: {:error, :install_material_unavailable}

  defp catalog do
    case Application.get_env(:salix_store, :agent_vmm_install_material) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, :missing_catalog}
    end
  end

  defp remote_enrollment(catalog, enrollment, %{policy: pool_policy, revision: policy_revision}) do
    with %{} = configured <- get(catalog, "remote_enrollment"),
         endpoint when is_binary(endpoint) <- get(configured, "gateway_endpoint"),
         true <- valid_gateway_endpoint?(endpoint),
         {:ok, trust_bundle} <-
           decode_bounded(get(configured, "trust_bundle"), 1, @max_trust_bundle_bytes),
         true <- valid_pem_certificates?(trust_bundle),
         true <- valid_pool_policy?(pool_policy),
         token when is_binary(token) <- enrollment.enrollment_token,
         {:ok, decoded_token} <- Base.decode64(token),
         true <- byte_size(decoded_token) == 32 do
      {:ok,
       %{
         gateway_endpoint: endpoint,
         enrollment_token: token,
         trust_bundle: Base.encode64(trust_bundle),
         policy_revision: policy_revision,
         pool_policy: pool_policy
       }}
    else
      _ -> {:error, :invalid_remote_enrollment}
    end
  end

  defp valid_pool_policy?(policy) when is_map(policy) do
    per_environment = get(policy, "per_environment_limits")

    with true <- valid_resource_policy?(per_environment),
         egress when egress in ["deny_all", "public_internet"] <-
           get(policy, "max_egress_mode"),
         stop when is_integer(stop) and stop in 1..300 <- get(policy, "stop_grace_seconds") do
      true
    else
      _ -> false
    end
  end

  defp valid_pool_policy?(_), do: false

  defp valid_resource_policy?(policy) when is_map(policy) do
    Enum.all?(~w(pids disk_bytes), fn key ->
      value = get(policy, key)
      is_integer(value) and value > 0
    end)
  end

  defp valid_resource_policy?(_), do: false

  defp scope_digest(operation) do
    values = [operation.tenant_id, operation.group_id, operation.scope_key]

    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok,
       values
       |> Jason.encode!()
       |> then(&:crypto.hash(:sha256, &1))
       |> Base.url_encode64(padding: false)}
    else
      {:error, :invalid_scope}
    end
  end

  defp valid_gateway_endpoint?(value) do
    case URI.parse("https://" <> value) do
      %URI{host: host, port: port, path: path, query: nil, fragment: nil}
      when is_binary(host) and host != "" and is_integer(port) and port > 0 and
             path in [nil, ""] ->
        Regex.match?(~r/:\d+\z/, value) and
          :inet.parse_address(String.to_charlist(host)) == {:error, :einval}

      _ ->
        false
    end
  end

  defp valid_pem_certificates?(pem) do
    case :public_key.pem_decode(pem) do
      entries when is_list(entries) and entries != [] ->
        Enum.all?(entries, fn
          {:Certificate, der, :not_encrypted} ->
            match?({:OTPCertificate, _, _, _}, :public_key.pkix_decode_cert(der, :otp))

          _ ->
            false
        end)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp decode_bounded(value, minimum, maximum) when is_binary(value) do
    with {:ok, decoded} <- Base.decode64(value),
         true <- byte_size(decoded) in minimum..maximum do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_base64}
    end
  end

  defp decode_bounded(_value, _minimum, _maximum), do: {:error, :invalid_base64}

  defp get(map, key), do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
end
