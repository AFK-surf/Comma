defmodule SalixStore.Compute.WorkloadCredential do
  @moduledoc """
  Outbound credential scoped to one Compute Workload.

  The token contains only Salix-owned workload/runtime identity and scopes. It
  never contains Provider, host, operator, enrollment, or transport identity.
  Bootstrap credentials expire. A Runtime Agent exchanges its bootstrap once
  for an epoch capability whose validity is fenced by the current durable
  RuntimeInstance generation and connection epoch.
  """

  @max_ttl_seconds 900
  @scopes ~w(bootstrap runtime workspace service_route hosting)
  alias SalixStore.{Compute, Repo}

  def issue(workload_id, runtime_instance_id, scopes, ttl_seconds \\ 300)

  def issue(workload_id, runtime_instance_id, scopes, ttl_seconds)
      when is_binary(workload_id) and is_list(scopes) and
             ttl_seconds in 1..@max_ttl_seconds do
    with :ok <- validate_id(workload_id),
         :ok <- validate_optional_id(runtime_instance_id),
         true <-
           (scopes != [] and Enum.all?(scopes, &(&1 in @scopes))) || {:error, :invalid_scope},
         {:ok, secret} <- secret() do
      now = System.system_time(:second)

      claims = %{
        "aud" => "salix-compute-runtime",
        "workload_id" => workload_id,
        "runtime_instance_id" => runtime_instance_id,
        "scopes" => Enum.uniq(scopes),
        "iat" => now,
        "exp" => now + ttl_seconds,
        "nonce" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
      }

      payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)

      signature =
        :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)

      expires_at = DateTime.from_unix!(claims["exp"])

      {:ok,
       %{
         "token" => payload <> "." <> signature,
         "workload_id" => workload_id,
         "runtime_instance_id" => runtime_instance_id,
         "expires_at" => expires_at
       }}
    else
      {:error, _} = error -> error
    end
  end

  def issue(_, _, _, _), do: {:error, :invalid_credential_request}

  @doc "Issue a runtime-bound credential for the current workload generation."
  def issue_for_runtime(workload_id, runtime_instance_id, scopes, ttl_seconds \\ 300)

  def issue_for_runtime(workload_id, runtime_instance_id, scopes, ttl_seconds)
      when is_binary(workload_id) and is_binary(runtime_instance_id) and is_list(scopes) do
    with %Compute.Workload{generation: generation} <-
           Repo.get(Compute.Workload, workload_id),
         %Compute.RuntimeInstance{
           workload_id: ^workload_id,
           generation: ^generation,
           id: ^runtime_instance_id,
           connection_epoch: connection_epoch
         } <- Repo.get(Compute.RuntimeInstance, runtime_instance_id),
         {:ok, credential} <- issue(workload_id, runtime_instance_id, scopes, ttl_seconds) do
      claims = decode_claims!(credential["token"])

      claims =
        claims
        |> Map.put("generation", generation)
        |> Map.put("connection_epoch", connection_epoch)

      {claims, credential} =
        if Enum.uniq(scopes) == ["runtime"] do
          {claims
           |> Map.drop(["iat", "exp", "nonce"])
           |> Map.put("credential_kind", "runtime_epoch"), Map.delete(credential, "expires_at")}
        else
          {claims, credential}
        end

      {:ok, Map.put(credential, "token", sign_claims(claims))}
    else
      nil -> {:error, :runtime_not_found}
      _ -> {:error, :runtime_scope_mismatch}
    end
  end

  def issue_for_runtime(_, _, _, _), do: {:error, :invalid_credential_request}

  @doc "Verify that a credential still names the current runtime generation."
  def verify_for_runtime(token, workload_id, runtime_instance_id, generation, required_scope)
      when is_binary(runtime_instance_id) and is_integer(generation) and generation > 0 do
    with {:ok, claims} <- verify_claims(token, workload_id, required_scope, true),
         true <- claims["runtime_instance_id"] == runtime_instance_id,
         true <- claims["generation"] == generation,
         %Compute.Workload{generation: ^generation, desired_state: "ready"} <-
           Repo.get(Compute.Workload, workload_id),
         %Compute.RuntimeInstance{
           id: ^runtime_instance_id,
           workload_id: ^workload_id,
           generation: ^generation,
           connection_epoch: connection_epoch
         } = runtime <- Repo.get(Compute.RuntimeInstance, runtime_instance_id) do
      cond do
        claims["connection_epoch"] != connection_epoch ->
          {:error, :invalid_workload_credential}

        runtime.status != "connected" or not Compute.runtime_control_current?(runtime) ->
          {:error, Compute.runtime_control_error(runtime)}

        true ->
          {:ok, claims}
      end
    else
      _ -> {:error, :invalid_workload_credential}
    end
  end

  def verify_for_runtime(_, _, _, _, _), do: {:error, :invalid_workload_credential}

  def verify(token, workload_id, required_scope)
      when is_binary(token) and is_binary(workload_id) and required_scope in @scopes do
    verify_claims(token, workload_id, required_scope, false)
  end

  def verify(_, _, _), do: {:error, :invalid_workload_credential}

  @doc "Verify a signed runtime-carrier token before resolving its scoped identity."
  def verify_unscoped(token) when is_binary(token) do
    with {:ok, claims} <- verified_claims(token),
         scopes when is_list(scopes) and scopes != [] <- claims["scopes"],
         true <- Enum.all?(scopes, &(&1 in @scopes)),
         true <- credential_live_unscoped?(claims) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_workload_credential}
    end
  end

  def verify_unscoped(_), do: {:error, :invalid_workload_credential}

  defp verify_claims(token, workload_id, required_scope, allow_runtime_epoch?) do
    with {:ok, claims} <- verified_claims(token),
         true <- claims["workload_id"] == workload_id,
         true <- required_scope in List.wrap(claims["scopes"]),
         true <- credential_live?(claims, required_scope, allow_runtime_epoch?) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_workload_credential}
    end
  end

  defp verified_claims(token) do
    with [payload, encoded_signature] <- String.split(token, ".", parts: 2),
         {:ok, secret} <- secret(),
         {:ok, signature} <- Base.url_decode64(encoded_signature, padding: false),
         expected <- :crypto.mac(:hmac, :sha256, secret, payload),
         true <-
           byte_size(signature) == byte_size(expected) and
             :crypto.hash_equals(signature, expected),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json),
         true <- claims["aud"] == "salix-compute-runtime" do
      {:ok, claims}
    else
      _ -> {:error, :invalid_workload_credential}
    end
  end

  defp credential_live?(%{"credential_kind" => "runtime_epoch"}, "runtime", true), do: true

  defp credential_live?(%{"exp" => exp}, _scope, _allow_runtime_epoch?) when is_integer(exp),
    do: exp > System.system_time(:second)

  defp credential_live?(_claims, _scope, _allow_runtime_epoch?), do: false

  defp credential_live_unscoped?(%{"credential_kind" => "runtime_epoch"}), do: true

  defp credential_live_unscoped?(%{"exp" => exp}) when is_integer(exp),
    do: exp > System.system_time(:second)

  defp credential_live_unscoped?(_claims), do: false

  defp secret do
    case Application.get_env(:salix_store, :compute_workload_credential_secret) do
      value when is_binary(value) and byte_size(value) >= 32 -> {:ok, value}
      _ -> {:error, :credential_signer_unavailable}
    end
  end

  defp decode_claims!(token) do
    [payload, _signature] = String.split(token, ".", parts: 2)
    {:ok, json} = Base.url_decode64(payload, padding: false)
    {:ok, claims} = Jason.decode(json)
    claims
  end

  defp sign_claims(claims) do
    {:ok, secret} = secret()
    payload = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.url_encode64(padding: false)
    payload <> "." <> signature
  end

  defp validate_id(value) when byte_size(value) in 1..180, do: :ok
  defp validate_id(_), do: {:error, :invalid_workload_id}
  defp validate_optional_id(nil), do: :ok
  defp validate_optional_id(value) when is_binary(value), do: validate_id(value)
  defp validate_optional_id(_), do: {:error, :invalid_runtime_instance_id}
end
