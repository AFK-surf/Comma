defmodule SalixStore.AgentVMMGatewayControl do
  @moduledoc """
  The control decisions Salix makes for an Agent VMM gateway: authenticate a
  Host credential, settle its hello and observations, hand out and commit
  commands, observe sessions, and serve the Personal Mesh registry.

  `call/3` takes the gateway instance that asks, one operation and its JSON
  body, and answers `{status, body}`: an HTTP-style status and a JSON-encodable
  map, or `nil` for no content. The node's own worker
  (`SalixStore.AgentVMM.Worker`) and the gateway control HTTP routes
  (`SalixWeb.Router`, `/v1/compute/*`) both answer from here, so one gateway
  sees one contract over either path.

  This module owns no state. Durable facts stay with `SalixStore.AgentVMM`
  and `SalixStore.PersonalMeshRegistry`.
  """

  alias SalixStore.{AgentVMM, PersonalMeshProto, PersonalMeshRegistry, Repo}

  @operations %{
    "authenticate" => :authenticate,
    "observe_hello" => :observe_hello,
    "settle_observation" => :settle_observation,
    "claim_command" => :claim_command,
    "commit_result" => :commit_result,
    "disconnected" => :disconnected,
    "observe_session" => :observe_session,
    "registry_create" => :registry_create,
    "registry_join" => :registry_join,
    "registry_revoke" => :registry_revoke,
    "registry_snapshot" => :registry_snapshot,
    "registry_endpoint" => :registry_endpoint,
    "registry_endpoints" => :registry_endpoints
  }

  @type operation ::
          :authenticate
          | :observe_hello
          | :settle_observation
          | :claim_command
          | :commit_result
          | :disconnected
          | :observe_session
          | :registry_create
          | :registry_join
          | :registry_revoke
          | :registry_snapshot
          | :registry_endpoint
          | :registry_endpoints

  @doc "The operation a worker names, or `:error` for a name this Salix does not serve."
  @spec operation(term()) :: {:ok, operation()} | :error
  def operation(name), do: Map.fetch(@operations, name)

  @spec call(String.t(), operation(), map()) :: {pos_integer(), map() | nil}
  def call(gateway_instance_id, operation, body)
      when is_binary(gateway_instance_id) and is_atom(operation) and is_map(body) do
    dispatch(operation, gateway_instance_id, body)
  end

  defp dispatch(:authenticate, _gateway, body) do
    with registration_id when is_binary(registration_id) <- body["registration_id"],
         {:ok, credential} <- Base.decode64(body["credential_b64"] || ""),
         :ok <- AgentVMM.authenticate_registration(registration_id, credential) do
      {200, nil}
    else
      {:error, :unavailable} -> {503, %{error: "registration_authentication_unavailable"}}
      _ -> {401, %{error: "registration_credential_rejected"}}
    end
  end

  defp dispatch(:observe_hello, gateway, body) do
    with {:ok, hello} <- decode_b64_json(body["hello_b64"]),
         registration_id when is_binary(registration_id) <- hello["registrationId"],
         {:ok, epoch} <- uint64_decimal_value(hello["connectionEpoch"]),
         {:ok, :ok} <-
           AgentVMM.observe_registration(
             registration_id,
             gateway,
             Map.put(hello, "connectionEpoch", epoch)
           ) do
      {200, nil}
    else
      {:error, :stale_connection} -> {409, %{error: "stale_connection"}}
      other -> connection_observation_error(other)
    end
  end

  defp dispatch(:settle_observation, gateway, body) do
    with registration_id when is_binary(registration_id) <- body["registration_id"],
         {:ok, renewal} <- decode_b64_json(body["renewal_b64"]),
         {:ok, epoch} <- uint64_decimal_value(renewal["connectionEpoch"]),
         observation when is_map(observation) <- renewal["observation"],
         {:ok, :ok} <-
           AgentVMM.settle_registration_observation(registration_id, gateway, epoch, observation) do
      {200, nil}
    else
      {:error, reason} when reason in [:stale_connection, :stale_observation] ->
        {409, %{error: "stale_observation"}}

      other ->
        connection_observation_error(other)
    end
  end

  defp dispatch(:claim_command, gateway, body) do
    with {:ok, epoch} <- uint64_decimal_value(body["connection_epoch"]) do
      case AgentVMM.claim_registration_command(body["registration_id"], gateway, epoch) do
        {:ok, nil} ->
          {204, nil}

        {:ok, %{payload: %{"command_json" => command}}} when is_map(command) ->
          {200, %{command_json: command}}

        {:ok, _} ->
          {500, %{error: "invalid_command_projection"}}

        {:error, :stale_connection} ->
          {409, %{error: "stale_connection"}}

        {:error, :unauthorized} ->
          {403, %{error: "registration_inactive"}}

        _ ->
          {503, %{error: "control_unavailable"}}
      end
    else
      _ -> {422, %{error: "invalid_connection_epoch"}}
    end
  end

  defp dispatch(:commit_result, gateway, body) do
    transcript = body["transcript"] || %{}
    result = transcript["result"] || %{}
    ack = transcript["ack"] || %{}
    evidence = transcript["evidence"] || %{}
    command_id = result["commandId"] || ack["commandId"] || evidence["commandId"]

    epoch_value =
      result["connectionEpoch"] || ack["connectionEpoch"] || evidence["connectionEpoch"]

    status =
      case result["outcome"] do
        "COMMAND_OUTCOME_SUCCEEDED" -> "succeeded"
        "COMMAND_OUTCOME_UNKNOWN" -> "unknown_outcome"
        nil -> "unknown_outcome"
        _ -> "failed"
      end

    with {:ok, epoch} <- uint64_decimal_value(epoch_value) do
      case AgentVMM.commit_registration_result(
             body["registration_id"],
             gateway,
             epoch,
             command_id,
             status,
             transcript
           ) do
        :ok -> {200, nil}
        {:error, :stale_command} -> {409, %{error: "stale_command"}}
        _ -> {503, %{error: "control_unavailable"}}
      end
    else
      _ -> {422, %{error: "invalid_connection_epoch"}}
    end
  end

  defp dispatch(:disconnected, gateway, body) do
    with {:ok, epoch} <- uint64_decimal_value(body["connection_epoch"]) do
      case AgentVMM.mark_connection_lost(body["registration_id"], gateway, epoch) do
        {:ok, _} -> {200, nil}
        _ -> {503, %{error: "control_unavailable"}}
      end
    else
      _ -> {422, %{error: "invalid_connection_epoch"}}
    end
  end

  defp dispatch(:observe_session, gateway, body) do
    with {:ok, header} <- decode_b64_json(body["header_b64"]),
         registration_id when is_binary(registration_id) <- header["registrationId"],
         {:ok, epoch} <- uint64_decimal_value(header["connectionEpoch"]),
         {:ok, :ok} <-
           AgentVMM.observe_session(
             registration_id,
             gateway,
             Map.put(header, "connectionEpoch", epoch)
           ) do
      session_ready(header["allocationId"])
      {200, nil}
    else
      _ -> {409, %{error: "stale_session"}}
    end
  end

  defp dispatch(:registry_create, _gateway, body) do
    with {:ok, request} <- registry_request(body),
         descriptor when is_map(descriptor) <- request["meshDescriptor"],
         operation when is_map(operation) <- request["genesis"],
         membership when is_map(membership) <- operation["membership"],
         {:ok, root_key} <- decode_bytes(membership["rootPublicKey"]),
         {:ok, descriptor_signature} <- decode_bytes(descriptor["genesisSignature"]),
         {:ok, descriptor_created_at} <- parse_proto_time(descriptor["createdAt"]),
         true <- descriptor["meshId"] == operation["meshId"],
         true <- descriptor["genesisDeviceId"] == operation["issuerDeviceId"],
         true <- descriptor["genesisRootPublicKey"] == membership["rootPublicKey"],
         true <-
           PersonalMeshRegistry.verify_p256_signature(
             PersonalMeshProto.personal_mesh_descriptor_signing_input(%{
               mesh_id: descriptor["meshId"],
               genesis_device_id: descriptor["genesisDeviceId"],
               genesis_root_public_key: root_key,
               registry_audience: descriptor["registryAudience"],
               policy_epoch: proto_uint(descriptor["policyEpoch"]),
               created_at: descriptor_created_at
             }),
             descriptor_signature,
             root_key
           ),
         {:ok, attrs} <- registry_operation_attrs(operation, membership, "genesis"),
         {:ok, snapshot} <-
           PersonalMeshRegistry.genesis(
             Map.merge(attrs, %{
               descriptor: Jason.encode!(descriptor),
               registry_audience: descriptor["registryAudience"]
             })
           ) do
      registry_snapshot_response(snapshot, :create)
    else
      reason -> registry_error(reason)
    end
  end

  defp dispatch(:registry_join, _gateway, body) do
    with {:ok, request} <- registry_request(body),
         operation when is_map(operation) <- request["operation"],
         membership when is_map(membership) <- operation["membership"],
         {:ok, attrs} <- registry_operation_attrs(operation, membership, "join"),
         {:ok, snapshot} <- PersonalMeshRegistry.join(attrs) do
      registry_snapshot_response(snapshot, :join)
    else
      reason -> registry_error(reason)
    end
  end

  defp dispatch(:registry_revoke, _gateway, body) do
    with {:ok, request} <- registry_request(body),
         operation when is_map(operation) <- request["operation"],
         membership when is_map(membership) <- operation["membership"],
         {:ok, attrs} <- registry_operation_attrs(operation, membership, "revoke"),
         {:ok, snapshot} <- PersonalMeshRegistry.revoke(attrs) do
      registry_snapshot_response(snapshot, :revoke)
    else
      reason -> registry_error(reason)
    end
  end

  defp dispatch(:registry_snapshot, _gateway, body) do
    with {:ok, request} <- registry_request(body),
         mesh_id when is_binary(mesh_id) <- request["meshId"],
         {:ok, snapshot} <- PersonalMeshRegistry.snapshot(mesh_id) do
      registry_snapshot_response(snapshot, :snapshot)
    else
      reason -> registry_error(reason)
    end
  end

  defp dispatch(:registry_endpoint, _gateway, body) do
    with {:ok, request} <- registry_request(body),
         observation when is_map(observation) <- request["observation"],
         {:ok, root_key} <- registry_member_root(request["meshId"], observation["deviceId"]),
         {:ok, signature} <- decode_bytes(observation["deviceSignature"]),
         {:ok, endpoint_node_id} <- decode_bytes(observation["endpointNodeId"]),
         {:ok, observed_addresses_digest} <-
           optional_decode_bytes(observation["observedAddressesDigest"]),
         {:ok, expires_at} <- parse_proto_time(observation["expiresAt"]),
         attrs0 <- %{
           mesh_id: request["meshId"],
           expected_revision: integer_value(request["expectedRevision"]),
           device_id: observation["deviceId"],
           root_key_revision: integer_value(observation["rootKeyRevision"]),
           generation: integer_value(observation["endpointGeneration"]),
           observation: Jason.encode!(observation),
           endpoint_node_id: endpoint_node_id,
           supported_alpns: observation["supportedAlpns"] || [],
           feature_set: observation["featureSet"] || [],
           observed_addresses_digest: observed_addresses_digest,
           signature: signature,
           root_public_key: root_key,
           expires_at: expires_at
         },
         attrs <-
           Map.put(
             attrs0,
             :canonical_payload,
             PersonalMeshProto.endpoint_observation_signing_input(attrs0)
           ),
         :ok <- PersonalMeshRegistry.publish_endpoint(attrs),
         {:ok, snapshot} <- PersonalMeshRegistry.snapshot(request["meshId"]) do
      registry_snapshot_response(snapshot, :endpoint)
    else
      reason -> registry_error(reason)
    end
  end

  defp dispatch(:registry_endpoints, _gateway, body) do
    with {:ok, request} <- registry_request(body),
         mesh_id when is_binary(mesh_id) <- request["meshId"],
         expected_revision when is_integer(expected_revision) and expected_revision > 0 <-
           integer_value(request["expectedRevision"]),
         {:ok, snapshot} <- PersonalMeshRegistry.snapshot(mesh_id),
         true <- snapshot.mesh.revision == expected_revision,
         {:ok, observations} <- decode_endpoint_observations(snapshot.endpoints) do
      response = %{"observations" => observations, "meshRevision" => snapshot.mesh.revision}
      {200, %{response_b64: Base.encode64(Jason.encode!(response))}}
    else
      reason -> registry_error(reason)
    end
  end

  # Wakes the exact Workload once its Host session is committed. The reconciler
  # belongs to an app above this one, which names it in the configuration; its
  # sweep covers a lost wake.
  defp session_ready(allocation_id) when is_binary(allocation_id) do
    notifier = SystemsRuntime.get_env(:salix_store, :agent_vmm_session_notifier)

    if is_atom(notifier) and not is_nil(notifier) and SystemsRuntime.Proc.ensure_loaded?(notifier) and
         function_exported?(notifier, :host_session_ready, 1),
       do: notifier.host_session_ready(allocation_id)

    :ok
  end

  defp session_ready(_allocation_id), do: :ok

  # Hello and observation errors keep their category. Only an unparseable
  # payload is `invalid_observation`; inactive authority and an unavailable
  # store are distinct so the Host side can map them.
  defp connection_observation_error({:error, :authorization_expired}),
    do: {403, %{error: "authorization_expired"}}

  defp connection_observation_error({:error, :registration_inactive}),
    do: {403, %{error: "registration_inactive"}}

  defp connection_observation_error({:error, :unavailable}),
    do: {503, %{error: "control_unavailable"}}

  defp connection_observation_error(_other), do: {422, %{error: "invalid_observation"}}

  defp decode_b64_json(value) when is_binary(value) do
    with {:ok, raw} <- Base.decode64(value),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_encoding}
    end
  end

  defp decode_b64_json(_), do: {:error, :invalid_encoding}

  # A gateway may still send its own canonical inputs. They are not used, and
  # an undecodable one is still a malformed request.
  defp registry_request(params) do
    with {:ok, request} <- decode_b64_json(params["request_json_b64"]),
         {:ok, _canonical} <- optional_decode_bytes(params["canonical_b64"]),
         {:ok, _descriptor} <- optional_decode_bytes(params["descriptor_canonical_b64"]) do
      {:ok, request}
    end
  end

  defp registry_operation_attrs(operation, membership, expected_kind) do
    expected_enum = "REGISTRY_OPERATION_KIND_" <> String.upcase(expected_kind)

    with true <- operation["kind"] == expected_enum,
         {:ok, signature} <- decode_bytes(operation["signature"]),
         {:ok, root_key} <- optional_decode_bytes(membership["rootPublicKey"]),
         {:ok, nonce} <- optional_decode_bytes(operation["nonce"]),
         {:ok, pairing_proof} <- optional_decode_bytes(operation["pairingProof"]),
         {:ok, operation_digest} <- optional_decode_bytes(membership["operationDigest"]),
         {:ok, membership_signatures} <- decode_bytes_list(membership["signatures"] || []),
         {:ok, expires_at} <- parse_proto_time(operation["expiresAt"]) do
      attrs = %{
        operation_id: operation["operationId"],
        mesh_id: operation["meshId"],
        kind: expected_kind,
        issuer_device_id: operation["issuerDeviceId"],
        expected_revision: proto_uint(operation["expectedRevision"]),
        policy_epoch: proto_uint(operation["policyEpoch"]),
        issuer_root_key_revision: proto_uint(operation["issuerRootKeyRevision"]),
        device_id: membership["deviceId"],
        root_public_key: root_key,
        root_key_revision: integer_value(membership["rootKeyRevision"]),
        permissions: Enum.map(membership["permissions"] || [], &registry_permission/1),
        invite_id: operation["inviteId"],
        nonce: nonce,
        pairing_proof: pairing_proof,
        invite_digest: :crypto.hash(:sha256, nonce),
        expires_at: expires_at,
        signature: signature,
        canonical_membership: %{
          mesh_id: membership["meshId"] || operation["meshId"],
          device_id: membership["deviceId"],
          root_public_key: root_key,
          root_key_revision: integer_value(membership["rootKeyRevision"]),
          permissions: Enum.map(membership["permissions"] || [], &registry_permission_number/1),
          state: registry_membership_state(membership["state"]),
          joined_at_revision: proto_uint(membership["joinedAtRevision"]),
          revoked_at_revision: optional_proto_uint(membership["revokedAtRevision"]),
          operation_digest: operation_digest,
          signatures: membership_signatures
        }
      }

      {:ok,
       Map.put(
         attrs,
         :canonical_payload,
         PersonalMeshProto.registry_operation_signing_input(attrs)
       )}
    else
      _ -> {:error, :invalid_operation}
    end
  end

  defp registry_snapshot_response(snapshot, kind) do
    encoded =
      case kind do
        :endpoint -> PersonalMeshProto.encode_endpoint_response(snapshot)
        kind -> PersonalMeshProto.encode_registry_response(snapshot, kind)
      end

    {200, %{response_b64: Base.encode64(encoded)}}
  rescue
    _ -> {503, %{error: "registry_signer_unavailable"}}
  end

  defp registry_error({:error, reason})
       when reason in [:revision_conflict, :stale_generation, :remove_wins, :operation_conflict],
       do: {409, %{error: to_string(reason)}}

  defp registry_error({:error, :unavailable}), do: {503, %{error: "registry_unavailable"}}
  defp registry_error(_), do: {422, %{error: "invalid_registry_request"}}

  defp registry_member_root(mesh_id, device_id) do
    case Repo.get_by(PersonalMeshRegistry.Member, mesh_id: mesh_id, device_id: device_id) do
      nil -> {:error, :not_found}
      member -> {:ok, member.root_public_key}
    end
  end

  defp decode_endpoint_observations(endpoints)
       when is_list(endpoints) and length(endpoints) <= 32 do
    Enum.reduce_while(endpoints, {:ok, []}, fn endpoint, {:ok, values} ->
      case Jason.decode(endpoint.observation) do
        {:ok, observation} when is_map(observation) -> {:cont, {:ok, [observation | values]}}
        _ -> {:halt, {:error, :invalid_endpoint_projection}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      other -> other
    end
  end

  defp decode_endpoint_observations(_), do: {:error, :invalid_endpoint_projection}

  defp registry_permission("MESH_PERMISSION_USE_SERVICES"), do: "use_services"
  defp registry_permission("MESH_PERMISSION_MANAGE_MEMBERS"), do: "manage_members"
  defp registry_permission(_), do: ""

  defp registry_permission_number("MESH_PERMISSION_USE_SERVICES"), do: 1
  defp registry_permission_number("MESH_PERMISSION_MANAGE_MEMBERS"), do: 2
  defp registry_permission_number(_), do: 0

  defp registry_membership_state("MESH_MEMBERSHIP_STATE_PENDING_JOIN"), do: 1
  defp registry_membership_state("MESH_MEMBERSHIP_STATE_ACTIVE"), do: 2
  defp registry_membership_state("MESH_MEMBERSHIP_STATE_REVOKED"), do: 3
  defp registry_membership_state(_), do: 0

  defp decode_bytes_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, decoded} ->
      case decode_bytes(value) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | decoded]}}
        _ -> {:halt, {:error, :invalid_encoding}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_bytes_list(_), do: {:error, :invalid_encoding}

  defp decode_bytes(value) when is_binary(value), do: Base.decode64(value)
  defp decode_bytes(_), do: {:error, :invalid_encoding}
  defp optional_decode_bytes(nil), do: {:ok, <<>>}
  defp optional_decode_bytes(value), do: decode_bytes(value)

  defp parse_proto_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_proto_time(_), do: {:error, :invalid_time}

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> -1
    end
  end

  defp integer_value(_), do: -1

  defp uint64_decimal_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed in 1..18_446_744_073_709_551_615 ->
        if Integer.to_string(parsed) == value,
          do: {:ok, value},
          else: {:error, :invalid_uint64}

      _ ->
        {:error, :invalid_uint64}
    end
  end

  defp uint64_decimal_value(_), do: {:error, :invalid_uint64}

  defp proto_uint(nil), do: 0
  defp proto_uint(value), do: integer_value(value)

  defp optional_proto_uint(nil), do: nil
  defp optional_proto_uint(value), do: integer_value(value)
end
