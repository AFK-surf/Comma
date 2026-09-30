defmodule SalixWeb.Router do
  @moduledoc """
  HTTP API adapter for Salix runtime, callbacks, connectors, and debug/admin
  surfaces. Most Comma product routes live in the dedicated `CommaWeb` endpoint;
  runtime product routes that share Salix auth/control state live here.

    * `GET  /health` — liveness

  Delivery writers go durable-store first and then signal the runtime:
  `SalixAgent.deliver/3` stages via touch→inbox→marker before waking.
  """
  use Plug.Router

  plug(:match)
  plug(SystemsObservability.HTTPPlug, endpoint: :salix_api)
  plug(SalixWeb.CORS)
  plug(SystemsObservability.PodDrainGate)
  plug(:put_runtime_auth_no_store)
  plug(SalixWeb.Auth)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    json_decoder: Jason,
    pass: ["application/json"],
    body_reader: {__MODULE__, :cache_raw_body, []}
  )

  plug(:dispatch)

  alias SalixIM.ProviderHTTP
  alias SalixIM.{ConversationInput, ConversationServer}
  alias SalixIM.Conversations
  alias SalixIM.RouterConversationInput
  alias SalixIM.ProviderConnects
  alias SalixIM.ConversationSeedInput
  alias SalixCluster.TaskSchedules

  alias Salix.Control.{
    ComposioSettings,
    GroupApiKeys,
    Groups,
    InitialAgentSeeds,
    IntegrationMaterialization,
    OAuthApps,
    OAuthBindings,
    RemoteMCPOAuth,
    Plugins,
    Tenants
  }

  alias SalixAgent.{
    Activity,
    Billing,
    CapabilityRequests,
    Control,
    Schedules,
    Templates,
    Workspace
  }

  alias SalixEnv.ConnectorTokens
  alias SalixEnv.ComputeRuntimeAuth
  alias SalixEnv.Control, as: EnvControl
  alias SalixWeb.E2EReports

  @install_operation_paths [
    "/v1/compute/agent-vmm/install-operations/exchange",
    "/v1/compute/agent-vmm/install-operations/ack"
  ]
  @max_install_operation_body_bytes 16_384

  defp serve_composio_webhook_configuration(conn, scope) do
    case ComposioSettings.configure_webhook(scope, conn.body_params) do
      {:ok, result} ->
        send_json(conn, 200, result)

      {:error, :existing_project_webhook} ->
        send_json(conn, 409, %{
          error: "existing_project_webhook",
          action:
            "Use replace_existing=true only to replace the project's current webhook destination."
        })

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "configure_settings_for_this_scope_first"})

      {:error, :not_configured} ->
        send_json(conn, 422, %{error: "not_configured"})

      {:error, _} ->
        send_json(conn, 503, %{error: "composio_webhook_configuration_failed"})
    end
  end

  def cache_raw_body(conn, opts) do
    result =
      cond do
        conn.request_path in @install_operation_paths ->
          Plug.Conn.read_body(conn, Keyword.put(opts, :length, @max_install_operation_body_bytes))

        SalixWeb.Auth.remote_shell_callback_path?(conn.request_path) ->
          read_bounded_body(conn, opts, 2_048)

        SalixWeb.Auth.composio_webhook_path?(conn.request_path) ->
          read_bounded_body(conn, opts, 16 * 1024)

        SalixWeb.Auth.loop_webhook_path?(conn.request_path) ->
          read_bounded_body(conn, opts, 16 * 1024)

        SalixWeb.TwilioWebhook.webhook_path?(conn.request_path) ->
          read_bounded_body(conn, opts, SalixWeb.TwilioWebhook.max_body_bytes())

        SalixWeb.Auth.router_inbox_path?(conn.request_path) ->
          read_bounded_body(conn, opts, Salix.App.RouterInbox.max_body_bytes())

        true ->
          read_raw_body(conn, opts, [])
      end

    case result do
      {:ok, body, conn} -> {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
      other -> other
    end
  end

  # The Router post_message ceiling is enforced here, before anything is
  # buffered past it or parsed: the socket is read up to the limit and no
  # further, and an over-limit request reaches the handler as an empty body
  # flagged `:raw_body_too_large` (docs/product-features.md).
  defp read_bounded_body(conn, opts, limit) do
    opts = opts |> Keyword.put(:length, limit) |> Keyword.put(:read_length, limit)

    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} when byte_size(body) <= limit -> {:ok, body, conn}
      {:ok, _body, conn} -> {:ok, "", Plug.Conn.assign(conn, :raw_body_too_large, true)}
      {:more, _partial, conn} -> {:ok, "", Plug.Conn.assign(conn, :raw_body_too_large, true)}
      {:error, _} = err -> err
    end
  end

  defp read_raw_body(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc])), conn}
      {:more, chunk, conn} -> read_raw_body(conn, opts, [chunk | acc])
      {:error, _} = err -> err
    end
  end

  get "/live" do
    send_json(conn, 200, %{status: "ok"})
  end

  get "/ready" do
    send_lifecycle_readiness(conn, :salix)
  end

  get "/health" do
    send_lifecycle_readiness(conn, :salix)
  end

  # Tenant-authenticated Workload projection. This is deliberately outside
  # /v1/compute/, whose routes are reserved for gateway control credentials.
  get "/v1/compute-node/work-activity/:registration_id" do
    case SalixStore.Compute.work_activity(tenant_id(conn), registration_id) do
      {:ok, projection} ->
        send_json(conn, 200, projection)

      {:error, :invalid_provider_binding} ->
        send_json(conn, 400, %{error: "invalid_registration_id"})

      {:error, :unavailable} ->
        send_json(conn, 503, %{error: "work_activity_unavailable"})
    end
  end

  post "/v1/compute/agent-vmm/install-operations/exchange" do
    exchange_install_operation(conn, conn.body_params)
  end

  post "/v1/compute/agent-vmm/install-operations/ack" do
    with %{"operation_id" => operation_id, "host_identity_digest" => host_digest} <-
           conn.body_params,
         true <- exact_keys?(conn.body_params, ["operation_id", "host_identity_digest"]),
         true <- is_binary(operation_id),
         {:ok, host_digest} <- decode_install_operation_digest(host_digest),
         {:ok, operation} <-
           SalixStore.AgentVMMInstallations.acknowledge(
             operation_id,
             conn.assigns.install_operation_secret,
             host_digest
           ) do
      send_json(conn, 200, %{operation: operation})
    else
      {:error, reason} -> send_install_operation_error(conn, reason)
      _ -> send_install_operation_error(conn, :invalid_request)
    end
  end

  post "/v1/compute/enroll" do
    with {:ok, request} <- decode_b64_json(conn.body_params["request_b64"]),
         registration_id when is_binary(registration_id) <- request["registrationId"],
         %{
           "deviceId" => device_id,
           "rootPublicKey" => root_public_key,
           "rootKeyRevision" => root_key_revision
         } = device_identity <- request["deviceIdentity"],
         true <-
           is_binary(device_id) and is_binary(root_public_key) and is_binary(root_key_revision),
         {:ok, token} <- Base.decode64(request["enrollmentToken"] || ""),
         credential <- :crypto.strong_rand_bytes(32),
         {:ok,
          {_registration,
           %{trust_anchor: trust_anchor, membership_credential: membership_credential}}} <-
           SalixStore.AgentVMM.enroll_with_bundle(
             registration_id,
             token,
             credential,
             fn registration ->
               if registration.device_id == device_id,
                 do:
                   SalixStore.AgentVMMTrust.issue_enrollment_bundle(registration, device_identity),
                 else: {:error, :device_identity_mismatch}
             end
           ) do
      response = %{
        "protocolVersion" => request["protocolVersion"],
        "registrationId" => registration_id,
        "controllerDisplayName" => "Salix",
        "credential" => Base.encode64(credential),
        "enabledFeatures" => request["supportedFeatures"] || [],
        "trustAnchor" => trust_anchor,
        "membershipCredential" => membership_credential
      }

      send_json(conn, 200, %{response_b64: Base.encode64(Jason.encode!(response))})
    else
      {:error, reason} ->
        send_json(conn, 403, %{
          error: "enrollment_rejected",
          reason: managed_enrollment_rejection_reason(reason)
        })

      _ ->
        send_json(conn, 403, %{error: "enrollment_rejected", reason: "invalid_request"})
    end
  end

  post "/v1/compute/authenticate" do
    with registration_id when is_binary(registration_id) <- conn.body_params["registration_id"],
         {:ok, credential} <- Base.decode64(conn.body_params["credential_b64"] || ""),
         :ok <- SalixStore.AgentVMM.authenticate_registration(registration_id, credential) do
      send_resp(conn, 200, "")
    else
      {:error, :unavailable} ->
        send_json(conn, 503, %{error: "registration_authentication_unavailable"})

      _ ->
        send_json(conn, 401, %{error: "registration_credential_rejected"})
    end
  end

  post "/v1/compute/connections/observe" do
    with {:ok, hello} <- decode_b64_json(conn.body_params["hello_b64"]),
         registration_id when is_binary(registration_id) <- hello["registrationId"],
         {:ok, epoch} <- uint64_decimal_value(hello["connectionEpoch"]),
         {:ok, :ok} <-
           SalixStore.AgentVMM.observe_registration(
             registration_id,
             conn.assigns.gateway_instance_id,
             Map.put(hello, "connectionEpoch", epoch)
           ) do
      send_resp(conn, 200, "")
    else
      {:error, :stale_connection} -> send_json(conn, 409, %{error: "stale_connection"})
      _ -> send_json(conn, 422, %{error: "invalid_observation"})
    end
  end

  post "/v1/compute/connections/observation" do
    with registration_id when is_binary(registration_id) <- conn.body_params["registration_id"],
         {:ok, renewal} <- decode_b64_json(conn.body_params["renewal_b64"]),
         {:ok, epoch} <- uint64_decimal_value(renewal["connectionEpoch"]),
         observation when is_map(observation) <- renewal["observation"],
         {:ok, :ok} <-
           SalixStore.AgentVMM.settle_registration_observation(
             registration_id,
             conn.assigns.gateway_instance_id,
             epoch,
             observation
           ) do
      send_resp(conn, 200, "")
    else
      {:error, reason} when reason in [:stale_connection, :stale_observation] ->
        send_json(conn, 409, %{error: "stale_observation"})

      _ ->
        send_json(conn, 422, %{error: "invalid_observation"})
    end
  end

  post "/v1/compute/commands/claim" do
    registration_id = conn.body_params["registration_id"]

    with {:ok, epoch} <- uint64_decimal_value(conn.body_params["connection_epoch"]) do
      case SalixStore.AgentVMM.claim_registration_command(
             registration_id,
             conn.assigns.gateway_instance_id,
             epoch
           ) do
        {:ok, nil} ->
          send_resp(conn, 204, "")

        {:ok, %{payload: %{"command_json" => command}}} when is_map(command) ->
          send_json(conn, 200, %{command_json: command})

        {:ok, _} ->
          send_json(conn, 500, %{error: "invalid_command_projection"})

        _ ->
          send_json(conn, 503, %{error: "control_unavailable"})
      end
    else
      _ -> send_json(conn, 422, %{error: "invalid_connection_epoch"})
    end
  end

  post "/v1/compute/commands/commit" do
    transcript = conn.body_params["transcript"] || %{}
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
      case SalixStore.AgentVMM.commit_registration_result(
             conn.body_params["registration_id"],
             conn.assigns.gateway_instance_id,
             epoch,
             command_id,
             status,
             transcript
           ) do
        :ok -> send_resp(conn, 200, "")
        {:error, :stale_command} -> send_json(conn, 409, %{error: "stale_command"})
        _ -> send_json(conn, 503, %{error: "control_unavailable"})
      end
    else
      _ -> send_json(conn, 422, %{error: "invalid_connection_epoch"})
    end
  end

  post "/v1/compute/connections/disconnected" do
    with {:ok, epoch} <- uint64_decimal_value(conn.body_params["connection_epoch"]) do
      case SalixStore.AgentVMM.mark_connection_lost(
             conn.body_params["registration_id"],
             conn.assigns.gateway_instance_id,
             epoch
           ) do
        {:ok, _} -> send_resp(conn, 200, "")
        _ -> send_json(conn, 503, %{error: "control_unavailable"})
      end
    else
      _ -> send_json(conn, 422, %{error: "invalid_connection_epoch"})
    end
  end

  post "/v1/compute/sessions/ready" do
    with {:ok, header} <- decode_b64_json(conn.body_params["header_b64"]),
         registration_id when is_binary(registration_id) <- header["registrationId"],
         {:ok, epoch} <- uint64_decimal_value(header["connectionEpoch"]),
         {:ok, :ok} <-
           SalixStore.AgentVMM.observe_session(
             registration_id,
             conn.assigns.gateway_instance_id,
             Map.put(header, "connectionEpoch", epoch)
           ) do
      SalixEnv.ComputeReconciler.host_session_ready(header["allocationId"])
      send_resp(conn, 200, "")
    else
      _ -> send_json(conn, 409, %{error: "stale_session"})
    end
  end

  get "/v1/compute/runtime/socket" do
    with {:ok, token} <- runtime_bearer_token(conn) do
      WebSockAdapter.upgrade(
        conn,
        SalixWeb.ComputeRuntimeSocket,
        %{token: token},
        compress: false,
        # Runtime Agents are long-lived and may be idle while waiting for
        # work. The carrier already owns bounded durable claims; an adapter
        # idle timeout would close healthy sessions every minute with 1002.
        timeout: :infinity,
        max_frame_size: 8 * 1024 * 1024
      )
    else
      _ -> send_json(conn, 401, %{error: "runtime_socket_unauthorized"})
    end
  end

  post "/v1/compute/registry/create" do
    with {:ok, request, _canonical, _descriptor_canonical} <- registry_request(conn.body_params),
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
           SalixStore.PersonalMeshRegistry.verify_p256_signature(
             SalixStore.PersonalMeshProto.personal_mesh_descriptor_signing_input(%{
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
           SalixStore.PersonalMeshRegistry.genesis(
             Map.merge(attrs, %{
               descriptor: Jason.encode!(descriptor),
               registry_audience: descriptor["registryAudience"]
             })
           ) do
      registry_snapshot_response(conn, snapshot, :commit)
    else
      reason -> registry_error(conn, reason)
    end
  end

  post "/v1/compute/registry/join" do
    with {:ok, request, _canonical, _} <- registry_request(conn.body_params),
         operation when is_map(operation) <- request["operation"],
         membership when is_map(membership) <- operation["membership"],
         {:ok, attrs} <- registry_operation_attrs(operation, membership, "join"),
         {:ok, snapshot} <- SalixStore.PersonalMeshRegistry.join(attrs) do
      registry_snapshot_response(conn, snapshot, :commit)
    else
      reason -> registry_error(conn, reason)
    end
  end

  post "/v1/compute/registry/revoke" do
    with {:ok, request, _canonical, _} <- registry_request(conn.body_params),
         operation when is_map(operation) <- request["operation"],
         membership when is_map(membership) <- operation["membership"],
         {:ok, attrs} <- registry_operation_attrs(operation, membership, "revoke"),
         {:ok, snapshot} <- SalixStore.PersonalMeshRegistry.revoke(attrs) do
      registry_snapshot_response(conn, snapshot, :commit)
    else
      reason -> registry_error(conn, reason)
    end
  end

  post "/v1/compute/registry/snapshot" do
    with {:ok, request, _canonical, _} <- registry_request(conn.body_params),
         mesh_id when is_binary(mesh_id) <- request["meshId"],
         {:ok, snapshot} <- SalixStore.PersonalMeshRegistry.snapshot(mesh_id) do
      registry_snapshot_response(conn, snapshot, :snapshot)
    else
      reason -> registry_error(conn, reason)
    end
  end

  post "/v1/compute/registry/endpoint" do
    with {:ok, request, _canonical, _} <- registry_request(conn.body_params),
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
             SalixStore.PersonalMeshProto.endpoint_observation_signing_input(attrs0)
           ),
         :ok <- SalixStore.PersonalMeshRegistry.publish_endpoint(attrs),
         {:ok, snapshot} <- SalixStore.PersonalMeshRegistry.snapshot(request["meshId"]) do
      registry_snapshot_response(conn, snapshot, :endpoint)
    else
      reason -> registry_error(conn, reason)
    end
  end

  post "/v1/compute/registry/endpoints" do
    with {:ok, request, _canonical, _} <- registry_request(conn.body_params),
         mesh_id when is_binary(mesh_id) <- request["meshId"],
         expected_revision when is_integer(expected_revision) and expected_revision > 0 <-
           integer_value(request["expectedRevision"]),
         {:ok, snapshot} <- SalixStore.PersonalMeshRegistry.snapshot(mesh_id),
         true <- snapshot.mesh.revision == expected_revision,
         {:ok, observations} <- decode_endpoint_observations(snapshot.endpoints) do
      response = %{"observations" => observations, "meshRevision" => snapshot.mesh.revision}
      send_json(conn, 200, %{response_b64: Base.encode64(Jason.encode!(response))})
    else
      reason -> registry_error(conn, reason)
    end
  end

  get "/v1/calendar/feeds/:cfd1_id/:secret" do
    # Plug captures the whole trailing segment including ".ics" into :secret.
    if String.ends_with?(secret, ".ics") do
      raw_secret = String.trim_trailing(secret, ".ics")
      if_none_match = conn |> get_req_header("if-none-match") |> List.first("")

      case Salix.Bindings.CalendarFeed.serve(cfd1_id, raw_secret, if_none_match) do
        {:ok, %{body: body, etag: etag}} ->
          conn
          |> put_resp_content_type("text/calendar")
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, max-age=300")
          |> send_resp(200, body)

        {:not_modified, etag} ->
          conn
          |> put_resp_header("etag", etag)
          |> put_resp_header("cache-control", "private, max-age=300")
          |> send_resp(304, "")

        {:error, reason}
        when reason in [:not_found, :unauthorized, :revoked, :invalid_local_item] ->
          send_json(conn, 404, %{error: "not found"})

        {:error, :calendar_feed_too_large} ->
          send_json(conn, 500, %{error: "feed too large"})

        {:error, _reason} ->
          send_json(conn, 503, %{error: "unavailable"})
      end
    else
      send_json(conn, 404, %{error: "not found"})
    end
  end

  post "/v1/calendar/google/notifications/:group_id/:calendar_id/:source_id" do
    case Salix.Bindings.GoogleCalendarWatch.receive(
           group_id,
           calendar_id,
           source_id,
           conn.req_headers
         ) do
      :ok ->
        send_resp(conn, 204, "")

      {:error, reason} when reason in [:not_found, :invalid_notification] ->
        send_json(conn, 404, %{error: "not found"})

      {:error, _reason} ->
        send_json(conn, 503, %{error: "unavailable"})
    end
  end

  defp send_lifecycle_readiness(conn, surface) do
    lifecycle = Module.concat([Comma, PodLifecycle])

    case apply(lifecycle, :ready, [surface]) do
      :ok -> send_json(conn, 200, %{status: "ok"})
      {:error, reason} -> send_json(conn, 503, %{status: "unavailable", reason: reason})
    end
  end

  get "/v1/admin/cluster/stats" do
    send_json(conn, 200, SalixCluster.Nodes.stats())
  end

  get "/v1/admin/cluster/nodes" do
    send_json(conn, 200, SalixCluster.Nodes.list())
  end

  get "/v1/admin/tenants" do
    send_json(conn, 200, Tenants.list())
  end

  post "/v1/admin/tenants" do
    case Tenants.create(conn.body_params) do
      {:ok, tenant} -> send_json(conn, 201, tenant)
      {:error, :exists} -> send_json(conn, 409, %{error: "tenant already exists"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/tenants/:id" do
    case Tenants.get(id) do
      {:ok, tenant} -> send_json(conn, 200, tenant)
      {:error, :not_found} -> send_json(conn, 404, %{error: "tenant not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  patch "/v1/admin/tenants/:id" do
    case Tenants.update(id, conn.body_params) do
      {:ok, tenant} -> send_json(conn, 200, tenant)
      {:error, :not_found} -> send_json(conn, 404, %{error: "tenant not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/tenants/:id/api-keys" do
    case Tenants.get(id) do
      {:ok, _tenant} ->
        case Tenants.list_api_keys(id) do
          {:error, :unavailable} -> send_json(conn, 503, %{error: "unavailable"})
          keys -> send_json(conn, 200, keys)
        end

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "tenant not found"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/admin/tenants/:id/api-keys" do
    case Tenants.create_api_key(id, conn.body_params) do
      {:ok, key} -> send_json(conn, 201, key)
      {:error, :not_found} -> send_json(conn, 404, %{error: "tenant not found"})
      {:error, {:unavailable, _}} -> send_json(conn, 503, %{error: "unavailable"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/admin/tenants/:id/api-keys/:key_hash" do
    case Tenants.delete_api_key(id, key_hash) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "tenant not found"})
      {:error, {:unavailable, _}} -> send_json(conn, 503, %{error: "unavailable"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/tenants/:id/agent-groups" do
    case Tenants.get(id) do
      {:ok, _tenant} -> send_json(conn, 200, Groups.list(id))
      {:error, :not_found} -> send_json(conn, 404, %{error: "tenant not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Tenant-layer Router/Worker default pointers plus the effective default per
  # role after layering with the platform (SalixAgent.AgentDefaults).
  get "/v1/agent-defaults" do
    {:ok, config} = Tenants.get_config(tenant_id(conn), "agent_defaults", %{})
    send_json(conn, 200, agent_defaults_json(config, tenant_id(conn)))
  end

  patch "/v1/agent-defaults" do
    case Tenants.update_config(tenant_id(conn), "agent_defaults", conn.body_params) do
      {:ok, config} -> send_json(conn, 200, agent_defaults_json(config, tenant_id(conn)))
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Platform-layer default pointers; global templates only.
  get "/v1/admin/agent-defaults" do
    case SalixAgent.AgentDefaults.platform() do
      {:ok, config} -> send_json(conn, 200, agent_defaults_json(config, nil))
      {:error, reason} -> send_json(conn, 503, %{error: inspect(reason)})
    end
  end

  patch "/v1/admin/agent-defaults" do
    case SalixAgent.AgentDefaults.update_platform(conn.body_params) do
      {:ok, config} -> send_json(conn, 200, agent_defaults_json(config, nil))
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :conflict} -> send_json(conn, 409, %{error: "concurrent update"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/integrations/im" do
    {:ok, config} = Tenants.get_config(tenant_id(conn), "im_integrations", %{})
    send_json(conn, 200, config)
  end

  patch "/v1/integrations/im" do
    case Tenants.update_config(tenant_id(conn), "im_integrations", conn.body_params) do
      {:ok, config} -> send_json(conn, 200, config)
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/integrations/im/status" do
    case Tenants.im_status(tenant_id(conn)) do
      {:ok, status} -> send_json(conn, 200, status)
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Provider redirect target (willow handleOAuthCallback). PUBLIC: the
  # browser arrives here from the provider with no bearer token — the route
  # is carved out in SalixWeb.Auth; the one-time
  # `state` parameter (consumed atomically) is the credential.
  get "/v1/oauth/mcp/callback" do
    conn = Plug.Conn.fetch_query_params(conn)
    send_oauth_callback_response(conn, RemoteMCPOAuth.handle_callback(conn.query_params))
  end

  get "/v1/oauth/:provider/callback" do
    conn = Plug.Conn.fetch_query_params(conn)

    send_oauth_callback_response(
      conn,
      SalixWeb.OAuthFlow.handle_callback(provider, conn.query_params)
    )
  end

  get "/v1/runtime/oauth/provider-apps" do
    send_json_list(conn, OAuthApps.list(tenant_id(conn)))
  end

  put "/v1/runtime/oauth/provider-apps/:provider" do
    case OAuthApps.put(tenant_id(conn), provider, conn.body_params) do
      {:ok, app} -> send_json(conn, 200, app)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/runtime/oauth/provider-apps/:provider" do
    case OAuthApps.delete(tenant_id(conn), provider) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/oauth/remote-mcp/provider-apps" do
    send_json_list(conn, RemoteMCPOAuth.list_provider_apps(tenant_id(conn)))
  end

  put "/v1/runtime/oauth/remote-mcp/provider-apps/:provider_key" do
    case RemoteMCPOAuth.put_provider_app(tenant_id(conn), provider_key, conn.body_params) do
      {:ok, app} -> send_json(conn, 200, app)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/runtime/oauth/remote-mcp/provider-apps/:provider_key" do
    case RemoteMCPOAuth.delete_provider_app(tenant_id(conn), provider_key) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Tenant Composio settings: the opt-in Composio integrations path that runs
  # alongside managed OAuth. The api_key is write-only; GET returns the
  # redacted view plus the effective resolution source.
  get "/v1/runtime/composio/settings" do
    send_json(conn, 200, ComposioSettings.view(tenant_id(conn)))
  end

  put "/v1/runtime/composio/settings" do
    case ComposioSettings.put(tenant_id(conn), conn.body_params) do
      {:ok, settings} -> send_json(conn, 200, settings)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/runtime/composio/settings" do
    case ComposioSettings.delete(tenant_id(conn)) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Deployment-wide default OAuth apps: the fallback credentials `get/2`
  # resolves when a tenant has none of its own. Tenant-independent,
  # operator-facing: admin-token gated under /v1/admin/ (a tenant key must
  # not reach deployment-wide defaults).
  get "/v1/admin/oauth/default-apps" do
    send_json_list(conn, OAuthApps.list_defaults())
  end

  put "/v1/admin/oauth/default-apps/:provider" do
    case OAuthApps.put_default(provider, conn.body_params) do
      {:ok, app} -> send_json(conn, 200, app)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/admin/oauth/default-apps/:provider" do
    case OAuthApps.delete_default(provider) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Deployment-wide default Composio settings: the fallback record
  # `ComposioSettings.get/1` resolves when a tenant has none of its own.
  # Admin-token gated like the OAuth default apps.
  get "/v1/admin/composio/default-settings" do
    send_json(conn, 200, ComposioSettings.view_default())
  end

  put "/v1/admin/composio/default-settings" do
    case ComposioSettings.put_default(conn.body_params) do
      {:ok, settings} -> send_json(conn, 200, settings)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/admin/composio/default-settings" do
    case ComposioSettings.delete_default() do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # Platform voice settings (docs/messaging-voice.md). Admin-token gated;
  # secrets are write-only; GET returns the redacted view.
  get "/v1/admin/voice/settings" do
    SalixWeb.VoiceRoutes.get_settings(conn)
  end

  put "/v1/admin/voice/settings" do
    SalixWeb.VoiceRoutes.put_settings(conn)
  end

  # The platform Signal number (docs/messaging-voice.md). Admin-token gated.
  get "/v1/admin/signal/settings" do
    send_signal_result(conn, Salix.Control.Signal.platform_settings())
  end

  put "/v1/admin/signal/settings" do
    send_signal_result(conn, Salix.Control.Signal.put_platform_settings(conn.body_params))
  end

  # A tenant's own Signal number, overriding the platform number.
  get "/v1/admin/tenants/:tenant_id/signal-number" do
    send_signal_result(conn, Salix.Control.Signal.tenant_number(tenant_id))
  end

  put "/v1/admin/tenants/:tenant_id/signal-number" do
    send_signal_result(
      conn,
      Salix.Control.Signal.put_tenant_number(tenant_id, conn.body_params)
    )
  end

  # Deployment-wide platform cloud-VM configuration. Tenants use it only when
  # their vm config explicitly follows platform config. Admin-token gated;
  # secrets are write-only; GET returns the redacted view.
  get "/v1/admin/vm/default-config" do
    send_json(conn, 200, SalixWeb.CloudVM.redacted_default_vm_config())
  end

  put "/v1/admin/vm/default-config" do
    case SalixWeb.CloudVM.put_default_vm_config(conn.body_params) do
      {:ok, redacted} -> send_json(conn, 200, redacted)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/admin/vm/default-config" do
    case SalixWeb.CloudVM.delete_default_vm_config() do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/vm/worker-release" do
    comma_revision =
      case System.get_env("SALIX_APP_REVISION") do
        revision when is_binary(revision) and byte_size(revision) == 40 ->
          if String.match?(revision, ~r/\A[0-9a-f]{40}\z/), do: revision

        _ ->
          nil
      end

    send_json(
      conn,
      200,
      Map.put(SalixWeb.CloudVM.worker_release(), "comma_source_revision", comma_revision)
    )
  end

  get "/v1/admin/vm/image-release/status" do
    case SalixWeb.ComputeProviders.Cloudflare.image_release_status() do
      {:ok, record} -> send_json(conn, 200, %{maintenance: record})
      {:error, reason} -> send_json(conn, 503, %{error: inspect(reason)})
    end
  end

  post "/v1/admin/vm/image-release/prepare" do
    maintenance_id = conn.body_params["maintenance_id"]

    if is_binary(maintenance_id) and byte_size(maintenance_id) in 1..128 do
      case SalixWeb.ComputeProviders.Cloudflare.prepare_image_release(maintenance_id) do
        {:ok, record} ->
          send_json(conn, 200, record)

        {:error, :vm_maintenance_owned_by_other_release} ->
          send_json(conn, 409, %{error: "vm_maintenance_owned_by_other_release"})

        {:error, :vm_maintenance_phase_mismatch} ->
          send_json(conn, 409, %{error: "vm_maintenance_phase_mismatch"})

        {:error, reason} ->
          send_json(conn, 503, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "invalid_maintenance_id"})
    end
  end

  get "/v1/admin/vm/image-release/workloads" do
    conn = fetch_query_params(conn)
    maintenance_id = conn.query_params["maintenance_id"]

    if is_binary(maintenance_id) and byte_size(maintenance_id) in 1..128 do
      cloud_vm_ops_page(conn, fn opts ->
        case SalixWeb.ComputeProviders.Cloudflare.image_release_workloads(
               maintenance_id,
               opts
             ) do
          {:ok, page} -> page
          error -> error
        end
      end)
    else
      send_json(conn, 400, %{error: "invalid_maintenance_id"})
    end
  end

  post "/v1/admin/vm/image-release/archive" do
    maintenance_id = conn.body_params["maintenance_id"]
    group_id = conn.body_params["group_id"]
    resource_name = conn.body_params["resource_name"]
    profile_key = conn.body_params["profile_key"]

    if is_binary(maintenance_id) and byte_size(maintenance_id) in 1..128 and
         is_binary(group_id) and byte_size(group_id) in 1..128 and
         is_binary(resource_name) and byte_size(resource_name) in 1..128 and
         profile_key in ["cf-standard-1", "cf-standard-2"] do
      case SalixWeb.ComputeProviders.Cloudflare.image_release_archive(
             maintenance_id,
             group_id,
             resource_name,
             profile_key
           ) do
        {:ok, state} -> send_json(conn, 202, %{state: state})
        {:error, reason} -> send_json(conn, 409, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "invalid_image_release_archive_request"})
    end
  end

  get "/v1/admin/vm/archive/operation" do
    conn = fetch_query_params(conn)
    group_id = conn.query_params["group_id"]
    operation = conn.query_params["operation"]

    if is_binary(group_id) and byte_size(group_id) in 1..128 and
         is_binary(operation) and byte_size(operation) in 1..128 do
      case SalixWeb.ComputeProviders.Cloudflare.archive_operation_status(group_id, operation) do
        {:ok, status} -> send_json(conn, 200, status)
        {:error, reason} -> send_json(conn, 404, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "invalid_archive_operation_request"})
    end
  end

  post "/v1/admin/vm/archive/cancel" do
    group_id = conn.body_params["group_id"]
    operation = conn.body_params["operation"]

    if is_binary(group_id) and byte_size(group_id) in 1..128 and
         is_binary(operation) and byte_size(operation) in 1..128 do
      case SalixWeb.ComputeProviders.Cloudflare.cancel_archive_operation(group_id, operation) do
        {:ok, status} -> send_json(conn, 200, %{status: status})
        {:error, reason} -> send_json(conn, 409, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "invalid_archive_operation_request"})
    end
  end

  post "/v1/admin/vm/image-release/finish" do
    maintenance_id = conn.body_params["maintenance_id"]

    if is_binary(maintenance_id) and byte_size(maintenance_id) in 1..128 do
      case SalixWeb.ComputeProviders.Cloudflare.finish_image_release(maintenance_id) do
        :ok ->
          send_json(conn, 200, %{status: "released", maintenance_id: maintenance_id})

        {:error, :vm_maintenance_owned_by_other_release} ->
          send_json(conn, 409, %{error: "vm_maintenance_owned_by_other_release"})

        {:error, :vm_maintenance_phase_mismatch} ->
          send_json(conn, 409, %{error: "vm_maintenance_phase_mismatch"})

        {:error, reason} ->
          send_json(conn, 503, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "invalid_maintenance_id"})
    end
  end

  post "/v1/admin/vm/image-release/deploying" do
    maintenance_id = conn.body_params["maintenance_id"]

    if is_binary(maintenance_id) and byte_size(maintenance_id) in 1..128 do
      case SalixWeb.ComputeProviders.Cloudflare.mark_image_release_deploying(maintenance_id) do
        {:ok, record} ->
          send_json(conn, 200, record)

        {:error, :vm_maintenance_owned_by_other_release} ->
          send_json(conn, 409, %{error: "vm_maintenance_owned_by_other_release"})

        {:error, reason} ->
          send_json(conn, 503, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "invalid_maintenance_id"})
    end
  end

  post "/v1/admin/vm/image-release/cancel" do
    maintenance_id = conn.body_params["maintenance_id"]

    if is_binary(maintenance_id) and byte_size(maintenance_id) in 1..128 do
      case SalixWeb.ComputeProviders.Cloudflare.cancel_image_release(maintenance_id) do
        :ok ->
          send_json(conn, 200, %{status: "released", maintenance_id: maintenance_id})

        {:error, :vm_maintenance_owned_by_other_release} ->
          send_json(conn, 409, %{error: "vm_maintenance_owned_by_other_release"})

        {:error, :vm_maintenance_phase_mismatch} ->
          send_json(conn, 409, %{error: "vm_maintenance_phase_mismatch"})

        {:error, reason} ->
          send_json(conn, 503, %{error: inspect(reason)})
      end
    else
      send_json(conn, 400, %{error: "invalid_maintenance_id"})
    end
  end

  put "/v1/admin/vm/worker-release" do
    case SalixWeb.CloudVM.put_worker_release(conn.body_params) do
      {:ok, release} -> send_json(conn, 200, release)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/vm/worker-release/outdated" do
    cloud_vm_ops_page(conn, &SalixWeb.ComputeProviders.Cloudflare.list_outdated_cloudflare_vms/1)
  end

  get "/v1/admin/vm/ops/stuck" do
    cloud_vm_ops_page(conn, &SalixWeb.ComputeProviders.Cloudflare.list_stuck_cloudflare_vms/1)
  end

  get "/v1/admin/vm/ops/keepalive-leaks" do
    cloud_vm_ops_page(
      conn,
      &SalixWeb.ComputeProviders.Cloudflare.list_cloudflare_keepalive_leaks/1
    )
  end

  post "/v1/admin/vm/worker-release/vms/:group_id/switch" do
    opts =
      [
        desired_worker_version_id: conn.body_params["desired_worker_version_id"],
        worker_release_id: conn.body_params["worker_release_id"],
        worker_release_kind: conn.body_params["worker_release_kind"],
        grace_ms: conn.body_params["grace_ms"]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case SalixWeb.ComputeProviders.Cloudflare.force_worker_switch(group_id, opts) do
      {:ok, rec} ->
        send_json(conn, 200, rec)

      {:error, {:active_operations, summary}} ->
        send_json(conn, 409, %{error: "active_operations", summary: summary})

      {:error, {:bad_request, message}} ->
        send_json(conn, 400, %{error: message})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agent-groups/:group_id/oauth-connections" do
    with_scoped_group(conn, group_id, fn ->
      send_json(conn, 200, OAuthBindings.list(group_id))
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/oauth/:provider/authorize" do
    with_scoped_group(conn, group_id, fn ->
      case SalixWeb.OAuthFlow.start_authorization(
             tenant_id(conn),
             group_id,
             provider,
             conn.body_params
           ) do
        {:ok, auth} -> send_json(conn, 200, auth)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, {:precondition_failed, message}} -> send_json(conn, 412, %{error: message})
        {:error, {:internal, message}} -> send_json(conn, 500, %{error: message})
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/oauth-connections/:binding_id" do
    with_scoped_group(conn, group_id, fn ->
      case OAuthBindings.update(group_id, binding_id, conn.body_params) do
        {:ok, binding} -> send_json(conn, 200, binding)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "oauth binding not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/oauth-connections/:binding_id" do
    with_scoped_group(conn, group_id, fn ->
      case SalixWeb.OAuthFlow.delete_binding(tenant_id(conn), group_id, binding_id) do
        :ok -> send_json(conn, 200, %{status: "deleted"})
        {:error, :not_found} -> send_json(conn, 404, %{error: "oauth binding not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/plugins" do
    with_scoped_group(conn, group_id, fn ->
      with {:ok, definitions} <- Plugins.list_definitions(tenant_id(conn), group_id),
           {:ok, enablements} <- Plugins.list_group_enablements(tenant_id(conn), group_id),
           {:ok, projection} <-
             Plugins.runtime_projection(%{
               "tenant_id" => tenant_id(conn),
               "group_id" => group_id
             }) do
        send_json(conn, 200, %{
          "definitions" => definitions,
          "enablements" => enablements,
          "projection" => projection
        })
      else
        error -> send_plugin_result(conn, error)
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/plugins" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(
        conn,
        Plugins.create_definition(tenant_id(conn), group_id, conn.body_params),
        201
      )
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/plugins/enablements" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(conn, Plugins.list_group_enablements(tenant_id(conn), group_id))
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/plugins/projection" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(
        conn,
        Plugins.runtime_projection(%{"tenant_id" => tenant_id(conn), "group_id" => group_id})
      )
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/plugins/:plugin_id" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(conn, Plugins.get_definition(tenant_id(conn), group_id, plugin_id))
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/plugins/:plugin_id" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(
        conn,
        Plugins.update_definition(tenant_id(conn), group_id, plugin_id, conn.body_params)
      )
    end)
  end

  put "/v1/runtime/agent-groups/:group_id/plugins/:plugin_id/refs" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(
        conn,
        Plugins.put_refs(tenant_id(conn), group_id, plugin_id, conn.body_params)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/plugins/:plugin_id/enable" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(conn, Plugins.enable_group(tenant_id(conn), group_id, plugin_id))
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/plugins/:plugin_id/disable" do
    with_scoped_group(conn, group_id, fn ->
      send_plugin_result(conn, Plugins.disable_group(tenant_id(conn), group_id, plugin_id))
    end)
  end

  get "/v1/runtime/mcp/definitions" do
    send_json(conn, 200, SalixMCP.Store.list_definitions(tenant_id(conn)))
  end

  post "/v1/runtime/mcp/definitions" do
    case SalixMCP.Store.create_definition(Map.put(conn.body_params, "tenant_id", tenant_id(conn))) do
      {:ok, definition} -> send_json(conn, 201, definition)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :exists} -> send_json(conn, 409, %{error: "MCP definition already exists"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/mcp/definitions/:mcp_id" do
    case SalixMCP.Store.get_definition(mcp_id, tenant_id(conn)) do
      {:ok, definition} -> send_json(conn, 200, SalixMCP.Store.public_definition(definition))
      {:error, :not_found} -> send_json(conn, 404, %{error: "MCP definition not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  patch "/v1/runtime/mcp/definitions/:mcp_id" do
    case SalixMCP.Store.update_definition(mcp_id, conn.body_params, tenant_id(conn)) do
      {:ok, definition} -> send_json(conn, 200, definition)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "MCP definition not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agent-groups/:group_id/mcp/bindings" do
    with_scoped_group(conn, group_id, fn ->
      send_json(
        conn,
        200,
        SalixMCP.Store.list_group_bindings(tenant_id(conn), group_id, include_disabled: true)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings" do
    with_scoped_group(conn, group_id, fn ->
      case SalixMCP.Gateway.create_binding(tenant_id(conn), group_id, conn.body_params) do
        {:ok, binding} ->
          send_json(conn, 201, binding)

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:device_runtime_required, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:device_runtime_not_found, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:device_runtime_unavailable, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "MCP definition not found"})

        {:error, :exists} ->
          send_json(conn, 409, %{error: "MCP binding already exists"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id" do
    with_scoped_group(conn, group_id, fn ->
      case SalixMCP.Gateway.update_binding(
             tenant_id(conn),
             group_id,
             binding_id,
             conn.body_params
           ) do
        {:ok, binding} ->
          send_json(conn, 200, binding)

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:device_runtime_required, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:device_runtime_not_found, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:device_runtime_unavailable, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "MCP binding not found"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id/enable" do
    with_scoped_group(conn, group_id, fn ->
      send_mcp_result(
        conn,
        SalixMCP.Gateway.set_binding_enabled(tenant_id(conn), group_id, binding_id, true)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id/disable" do
    with_scoped_group(conn, group_id, fn ->
      send_mcp_result(
        conn,
        SalixMCP.Gateway.set_binding_enabled(tenant_id(conn), group_id, binding_id, false)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id/discover" do
    with_scoped_group(conn, group_id, fn ->
      send_mcp_result(
        conn,
        SalixMCP.Gateway.refresh_binding(tenant_id(conn), group_id, binding_id)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id/oauth/authorize" do
    with_scoped_group(conn, group_id, fn ->
      case RemoteMCPOAuth.start_authorization(
             tenant_id(conn),
             group_id,
             binding_id,
             conn.body_params
           ) do
        {:ok, auth} -> send_json(conn, 200, auth)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, {:precondition_failed, message}} -> send_json(conn, 412, %{error: message})
        {:error, {:missing_oauth_client, message}} -> send_json(conn, 412, %{error: message})
        {:error, {:internal, message}} -> send_json(conn, 500, %{error: message})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id/restart" do
    with_scoped_group(conn, group_id, fn ->
      send_mcp_result(
        conn,
        SalixMCP.Gateway.restart_binding(tenant_id(conn), group_id, binding_id)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id/reconnect" do
    with_scoped_group(conn, group_id, fn ->
      send_mcp_result(
        conn,
        SalixMCP.Gateway.restart_binding(tenant_id(conn), group_id, binding_id)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/mcp/bindings/:binding_id/stop" do
    with_scoped_group(conn, group_id, fn ->
      send_mcp_result(
        conn,
        SalixMCP.Gateway.stop_binding(tenant_id(conn), group_id, binding_id)
      )
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/im/connects" do
    with_scoped_group(conn, group_id, fn ->
      case ProviderConnects.list_group_im_connects(group_id, conn.query_params["provider"]) do
        {:ok, connects} -> send_json(conn, 200, connects)
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/eval/integration-materializations" do
    with_scoped_group(conn, group_id, fn ->
      case IntegrationMaterialization.materialize(
             tenant_id(conn),
             group_id,
             conn.body_params
           ) do
        {:ok, materialization} ->
          send_json(conn, 200, materialization)

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:conflict, message}} ->
          send_json(conn, 409, %{error: message})

        {:error, {:provider, message}} ->
          send_json(conn, 502, %{error: message})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "agent group not found"})

        {:error, :scan_capacity_exhausted} ->
          send_json(conn, 503, %{error: "identity resolution over scan capacity, retry"})

        {:error, :identity_census_unavailable} ->
          send_json(conn, 503, %{error: "identity uniqueness could not be proven, retry"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/eval/trajectory-results" do
    conn = Plug.Conn.fetch_query_params(conn)

    case SalixWeb.TrajectoryEvalAPI.list(tenant_id(conn), conn.query_params) do
      {:ok, page} ->
        send_json(conn, 200, page)

      {:error, reason} when reason in [:invalid_cursor, :invalid] ->
        send_json(conn, 400, %{error: "invalid cursor"})

      {:error, reason}
      when reason in [
             :cursor_filter_conflict,
             :initial_cursor_required,
             :invalid_bootstrap,
             :invalid_time,
             :invalid_limit,
             :invalid_severity
           ] ->
        send_json(conn, 400, %{error: to_string(reason)})

      {:error, :unavailable} ->
        send_json(conn, 503, %{error: "unavailable"})

      {:error, _reason} ->
        send_json(conn, 500, %{error: "internal error"})
    end
  end

  post "/v1/runtime/agent-groups/:group_id/im/connects/:connect_id/disable" do
    with_scoped_group(conn, group_id, fn ->
      case ProviderConnects.disable_im_connect(tenant_id(conn), group_id, connect_id) do
        :ok -> send_json(conn, 200, %{disabled: true})
        {:error, :not_found} -> send_json(conn, 404, %{error: "connect not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/im/connects/:connect_id/enable" do
    with_scoped_group(conn, group_id, fn ->
      case ProviderConnects.enable_im_connect(tenant_id(conn), group_id, connect_id) do
        :ok -> send_json(conn, 200, %{enabled: true})
        {:error, :not_found} -> send_json(conn, 404, %{error: "connect not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/im/connects/:connect_id" do
    with_scoped_group(conn, group_id, fn ->
      case ProviderConnects.delete_im_connect(tenant_id(conn), group_id, connect_id) do
        :ok -> send_json(conn, 200, %{deleted: true})
        {:error, :not_found} -> send_json(conn, 404, %{error: "connect not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/im/providers/slack/manifest" do
    with_scoped_group(conn, group_id, fn ->
      sync_im_public_base_url()
      send_json(conn, 200, ProviderHTTP.slack_manifest(conn.query_params["app_name"]))
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/im/providers/slack/connects" do
    with_scoped_group(conn, group_id, fn ->
      sync_im_public_base_url()

      case ProviderConnects.create_slack_im_connect(tenant_id(conn), group_id, conn.body_params) do
        {:ok, connect} -> send_json(conn, 201, connect)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/im/providers/slack/connects/:connect_id" do
    with_scoped_group(conn, group_id, fn ->
      sync_im_public_base_url()

      case ProviderConnects.update_slack_im_connect(
             tenant_id(conn),
             group_id,
             connect_id,
             conn.body_params
           ) do
        {:ok, connect} -> send_json(conn, 200, connect)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "connect not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/im/providers/telegram/connects" do
    with_scoped_group(conn, group_id, fn ->
      sync_im_public_base_url()

      case ProviderConnects.create_telegram_im_connect(
             tenant_id(conn),
             group_id,
             conn.body_params
           ) do
        {:ok, connect} -> send_json(conn, 201, connect)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/im/providers/telegram/connects/:connect_id" do
    with_scoped_group(conn, group_id, fn ->
      case ProviderConnects.update_telegram_im_connect(
             tenant_id(conn),
             group_id,
             connect_id,
             conn.body_params
           ) do
        {:ok, connect} -> send_json(conn, 200, connect)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "connect not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/im/providers/feishu/connects" do
    with_scoped_group(conn, group_id, fn ->
      sync_im_public_base_url()

      case ProviderConnects.create_feishu_im_connect(tenant_id(conn), group_id, conn.body_params) do
        {:ok, connect} -> send_json(conn, 201, connect)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/im/providers/feishu/connects/:connect_id" do
    with_scoped_group(conn, group_id, fn ->
      case ProviderConnects.update_feishu_im_connect(
             tenant_id(conn),
             group_id,
             connect_id,
             conn.body_params
           ) do
        {:ok, connect} -> send_json(conn, 200, connect)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "connect not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:id/router/messages" do
    with_scoped_group(conn, id, fn ->
      case SalixIM.RouterConversationProjection.list_group_router_messages(id) do
        {:ok, messages} -> send_json(conn, 200, messages)
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:id/router/conversation" do
    with_scoped_group(conn, id, fn ->
      case RouterConversationInput.ensure(id) do
        {:ok, conversation} ->
          send_json(conn, 200, conversation)

        {:error, :router_not_configured} ->
          send_json(conn, 404, %{error: "router agent not configured"})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "agent group not found"})

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:id/router/messages" do
    with_scoped_group(conn, id, fn ->
      case RouterConversationInput.append_user_message(id, conn.body_params) do
        {:ok, result} ->
          send_json(conn, 201, result)

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, :router_not_configured} ->
          send_json(conn, 404, %{error: "router agent not configured"})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "agent group not found"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  # ---- Router post_message API (docs/product-features.md) ----
  #
  # The one path a group API key opens. `SalixWeb.Auth` has already resolved
  # the key; the path group must be the key's own group, and the answer for
  # any other group is the same 404 a missing group gets.
  post "/v1/agent-groups/:id/router/post-message" do
    serve_router_inbox_post_message(conn, id)
  end

  # ---- Background Loop event ingress (docs/salix/tasks-background-execution.md) --
  #
  # The same group API key feeds one of the group's Loops. 202 means the
  # event was admitted to the owner node's spinfoam mailbox, not processed;
  # processed acknowledgements are the guest's `loop.ack`.
  post "/v1/composio-webhooks/:secret" do
    SalixWeb.ComposioWebhook.receive_event(conn)
  end

  post "/v1/runtime/composio/webhook" do
    serve_composio_webhook_configuration(conn, tenant_id(conn))
  end

  post "/v1/admin/composio/default-webhook" do
    serve_composio_webhook_configuration(conn, SalixStore.ComposioSettings.default_scope())
  end

  post "/v1/loop-webhooks/:secret" do
    SalixWeb.LoopWebhook.receive_event(conn, secret)
  end

  post "/v1/agent-groups/:group_id/loops/:loop_id/events" do
    serve_loop_event(conn, group_id, loop_id)
  end

  # ---- Voice (docs/messaging-voice.md) ----

  # Twilio webhooks: public in Auth, admitted by X-Twilio-Signature.
  post "/v1/voice/twilio/incoming" do
    SalixWeb.TwilioWebhook.incoming(conn)
  end

  post "/v1/voice/twilio/pin" do
    SalixWeb.TwilioWebhook.pin(conn)
  end

  post "/v1/voice/twilio/status" do
    SalixWeb.TwilioWebhook.status(conn)
  end

  # Twilio media stream: public in Auth, admitted by the stream token.
  get "/v1/voice/twilio/stream/:token" do
    SalixWeb.VoiceRoutes.twilio_stream(conn, token)
  end

  # comma.voice.v1: voice agent keys only.
  get "/v1/agent-groups/:group_id/voice" do
    SalixWeb.VoiceRoutes.readiness(conn, group_id)
  end

  get "/v1/agent-groups/:group_id/voice/sessions" do
    SalixWeb.VoiceRoutes.session(conn, group_id)
  end

  get "/v1/runtime/agent-groups/:group_id/im-connects/voice" do
    with_scoped_group(conn, group_id, fn ->
      SalixWeb.VoiceRoutes.send_numbers_result(
        conn,
        Salix.Control.VoiceNumbers.status(group_id, tenant_id(conn))
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/im-connects/voice/numbers/verify-start" do
    with_scoped_group(conn, group_id, fn ->
      SalixWeb.VoiceRoutes.send_numbers_result(
        conn,
        Salix.Control.VoiceNumbers.verify_start(group_id, tenant_id(conn), conn.body_params)
      )
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/im-connects/voice/numbers/verify-check" do
    with_scoped_group(conn, group_id, fn ->
      SalixWeb.VoiceRoutes.send_numbers_result(
        conn,
        Salix.Control.VoiceNumbers.verify_check(group_id, tenant_id(conn), conn.body_params)
      )
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/im-connects/voice/numbers/:e164" do
    with_scoped_group(conn, group_id, fn ->
      SalixWeb.VoiceRoutes.send_numbers_result(
        conn,
        Salix.Control.VoiceNumbers.remove_number(group_id, tenant_id(conn), e164)
      )
    end)
  end

  put "/v1/runtime/agent-groups/:group_id/im-connects/voice/pin" do
    with_scoped_group(conn, group_id, fn ->
      SalixWeb.VoiceRoutes.send_numbers_result(
        conn,
        Salix.Control.VoiceNumbers.set_pin(group_id, tenant_id(conn), conn.body_params)
      )
    end)
  end

  # ---- Signal (docs/messaging-voice.md) ----

  get "/v1/runtime/signal/number" do
    send_signal_result(conn, Salix.Control.Signal.tenant_number(tenant_id(conn)))
  end

  put "/v1/runtime/signal/number" do
    send_signal_result(
      conn,
      Salix.Control.Signal.put_tenant_number(tenant_id(conn), conn.body_params)
    )
  end

  get "/v1/runtime/agent-groups/:group_id/im-connects/signal" do
    with_scoped_group(conn, group_id, fn ->
      send_signal_result(conn, Salix.Control.Signal.status(group_id, tenant_id(conn)))
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/im-connects/signal/claims" do
    with_scoped_group(conn, group_id, fn ->
      created_by = "tenant_api:" <> to_string(conn.assigns[:auth_role] || "tenant")

      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_signal_result(
        Salix.Control.Signal.start_claim(group_id, tenant_id(conn), created_by)
      )
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/im-connects/signal/claims/:claim_id" do
    with_scoped_group(conn, group_id, fn ->
      send_signal_result(
        conn,
        Salix.Control.Signal.cancel_claim(group_id, tenant_id(conn), claim_id)
      )
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/im-connects/signal/bindings/:binding_id" do
    with_scoped_group(conn, group_id, fn ->
      send_signal_result(
        conn,
        Salix.Control.Signal.remove_binding(group_id, tenant_id(conn), binding_id)
      )
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/voice/api-keys" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.list(group_id, tenant_id(conn), "voice") do
        {:ok, keys} -> send_json(conn, 200, keys)
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/voice/api-keys" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.create(
             group_id,
             tenant_id(conn),
             conn.body_params,
             "tenant_api",
             "voice"
           ) do
        {:ok, key} -> send_json(conn, 201, key)
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/voice/api-keys/:key_id" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.update(group_id, tenant_id(conn), key_id, conn.body_params, "voice") do
        {:ok, key} -> send_json(conn, 200, key)
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/voice/api-keys/:key_id" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.delete(group_id, tenant_id(conn), key_id, "voice") do
        :ok -> send_json(conn, 200, %{status: "deleted"})
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  get "/v1/runtime/agent-groups/:group_id/router/api-keys" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.list(group_id, tenant_id(conn)) do
        {:ok, keys} -> send_json(conn, 200, keys)
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/router/api-keys" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.create(group_id, tenant_id(conn), conn.body_params, "tenant_api") do
        {:ok, key} -> send_json(conn, 201, key)
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:group_id/router/api-keys/:key_id" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.update(group_id, tenant_id(conn), key_id, conn.body_params) do
        {:ok, key} -> send_json(conn, 200, key)
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/router/api-keys/:key_id" do
    with_scoped_group(conn, group_id, fn ->
      case GroupApiKeys.delete(group_id, tenant_id(conn), key_id) do
        :ok -> send_json(conn, 200, %{status: "deleted"})
        {:error, reason} -> send_group_api_key_error(conn, reason)
      end
    end)
  end

  # Tenant keys own private-template management. Catalog reads remain credential-free.
  get "/v1/templates/catalog" do
    case Templates.list_available(tenant_id(conn)) do
      {:ok, templates} -> send_json(conn, 200, templates)
      {:error, reason} -> send_json(conn, 503, %{error: inspect(reason)})
    end
  end

  get "/v1/templates" do
    case Templates.list_private(tenant_id(conn)) do
      {:ok, templates} -> send_json(conn, 200, templates)
      {:error, reason} -> send_json(conn, 503, %{error: inspect(reason)})
    end
  end

  post "/v1/templates" do
    case Templates.create_private(conn.body_params, tenant_id(conn)) do
      {:ok, template} -> send_json(conn, 201, template)
      {:error, :exists} -> send_json(conn, 409, %{error: "template already exists"})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/templates/:id" do
    # A management read must never expose global provider credentials to a tenant.
    result =
      if SalixStore.Ids.valid_private_template_id?(id),
        do: Templates.get(id, tenant_id(conn)),
        else: {:error, :not_found}

    case result do
      {:ok, template} -> send_json(conn, 200, template)
      {:error, :not_found} -> send_json(conn, 404, %{error: "template not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  patch "/v1/templates/:id" do
    case Templates.update_private(id, conn.body_params, tenant_id(conn)) do
      {:ok, template} -> send_json(conn, 200, template)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "template not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/templates/:id" do
    case Templates.delete_private(id, tenant_id(conn)) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "template not found"})
      {:error, {:conflict, message}} -> send_json(conn, 409, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/templates/catalog" do
    send_json(conn, 200, Templates.list())
  end

  get "/v1/initial-agents" do
    send_json(conn, 200, %{"initial_agents" => InitialAgentSeeds.list(tenant_id(conn))})
  end

  put "/v1/initial-agents/:slot" do
    case InitialAgentSeeds.put(slot, conn.body_params, tenant_id(conn)) do
      {:ok, initial_agent} -> send_json(conn, 200, %{"initial_agent" => initial_agent})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/initial-agents/main" do
    case InitialAgentSeeds.set_main(conn.body_params, tenant_id(conn)) do
      {:ok, initial_agent} -> send_json(conn, 200, %{"initial_agent" => initial_agent})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/templates" do
    send_json(conn, 200, Templates.list_admin())
  end

  post "/v1/admin/templates" do
    case Templates.create(conn.body_params) do
      {:ok, template} -> send_json(conn, 201, template)
      {:error, :exists} -> send_json(conn, 409, %{error: "template already exists"})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/admin/templates/:id" do
    case Templates.get(id) do
      {:ok, template} -> send_json(conn, 200, template)
      {:error, :not_found} -> send_json(conn, 404, %{error: "template not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  patch "/v1/admin/templates/:id" do
    case Templates.update(id, conn.body_params) do
      {:ok, template} -> send_json(conn, 200, template)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "template not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/admin/templates/:id" do
    case Templates.delete(id) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "template not found"})
      {:error, {:conflict, message}} -> send_json(conn, 409, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agent-groups" do
    send_json(conn, 200, Groups.list(tenant_id(conn)))
  end

  post "/v1/runtime/agent-groups" do
    case Groups.create(conn.body_params, tenant_id(conn)) do
      {:ok, group} -> send_json(conn, 201, group)
      {:error, :exists} -> send_json(conn, 409, %{error: "agent group already exists"})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agent-groups/:id" do
    case Groups.get(id, tenant_id(conn)) do
      {:ok, group} -> send_json(conn, 200, group)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  patch "/v1/runtime/agent-groups/:id" do
    case Groups.update(id, conn.body_params, tenant_id(conn)) do
      {:ok, group} -> send_json(conn, 200, group)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/runtime/agent-groups/:id" do
    case Groups.delete(id, tenant_id(conn)) do
      :ok -> send_json(conn, 200, %{status: "deleted"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
      {:error, {:conflict, message}} -> send_json(conn, 409, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agent-groups/:id/connector-tokens" do
    case ConnectorTokens.create_group_connector_token(id, tenant_id(conn), conn.body_params) do
      {:ok, token} -> send_json(conn, 201, token)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agent-groups/:id/initial-agent-slots/:slot/materialize" do
    case InitialAgentSeeds.materialize_slot(id, slot, tenant_id(conn)) do
      {:ok, agent} -> send_json(conn, 200, %{"agent" => agent})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "initial agent slot not found"})
      {:error, :exists} -> send_json(conn, 409, %{error: "agent already exists"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/agent-groups/:id/capability-requests" do
    serve_capability_request_list(conn, id)
  end

  get "/v1/agent-groups/:id/capability-requests/events" do
    serve_capability_request_events(conn, id)
  end

  post "/v1/agent-groups/:id/capability-requests/:request_id/location/share" do
    serve_share_location_capability_request(conn, id, request_id)
  end

  post "/v1/agent-groups/:id/capability-requests/:request_id/oauth-authorization/confirm" do
    serve_confirm_oauth_authorization_capability_request(conn, id, request_id)
  end

  post "/v1/agent-groups/:id/capability-requests/:request_id/host-access/decision" do
    serve_decide_host_access_capability_request(conn, id, request_id)
  end

  post "/v1/agent-groups/:id/capability-requests/:request_id/computer-use-start/decision" do
    serve_decide_computer_use_start_capability_request(conn, id, request_id)
  end

  get "/v1/runtime/agent-groups/:id/capability-requests" do
    serve_capability_request_list(conn, id)
  end

  get "/v1/runtime/agent-groups/:id/capability-requests/events" do
    serve_capability_request_events(conn, id)
  end

  post "/v1/runtime/agent-groups/:id/capability-requests/:request_id/location/share" do
    serve_share_location_capability_request(conn, id, request_id)
  end

  post "/v1/runtime/agent-groups/:id/capability-requests/:request_id/oauth-authorization/confirm" do
    serve_confirm_oauth_authorization_capability_request(conn, id, request_id)
  end

  post "/v1/runtime/agent-groups/:id/capability-requests/:request_id/host-access/decision" do
    serve_decide_host_access_capability_request(conn, id, request_id)
  end

  post "/v1/runtime/agent-groups/:id/capability-requests/:request_id/computer-use-start/decision" do
    serve_decide_computer_use_start_capability_request(conn, id, request_id)
  end

  get "/v1/agent-groups/:id/meeting-agent" do
    serve_meeting_agent_status(conn, id)
  end

  post "/v1/agent-groups/:id/meeting-agent/start" do
    with_scoped_group(conn, id, fn ->
      case SalixMeet.Runtime.start_for_group(tenant_id(conn), id) do
        {:ok, meeting_agent} -> send_json(conn, 200, %{"meeting_agent" => meeting_agent})
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, {:invalid_meeting_agent, reason}} -> send_meeting_agent_conflict(conn, reason)
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/agent-groups/:id/meeting-agent/heartbeat" do
    with_scoped_group(conn, id, fn ->
      case SalixMeet.Runtime.heartbeat(tenant_id(conn), id) do
        {:ok, meeting_agent} -> send_json(conn, 200, %{"meeting_agent" => meeting_agent})
        {:error, :not_found} -> send_json(conn, 404, %{error: "meeting agent not found"})
        {:error, {:invalid_meeting_agent, reason}} -> send_meeting_agent_conflict(conn, reason)
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/agent-groups/:id/meeting-agent/stop" do
    with_scoped_group(conn, id, fn ->
      case SalixMeet.Runtime.stop_for_group(tenant_id(conn), id) do
        {:ok, meeting_agent} -> send_json(conn, 200, %{"meeting_agent" => meeting_agent})
        {:error, :not_found} -> send_json(conn, 404, %{error: "meeting agent not found"})
        {:error, {:invalid_meeting_agent, reason}} -> send_meeting_agent_conflict(conn, reason)
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/agent-groups/:id/meeting-agent/events" do
    with_scoped_group(conn, id, fn ->
      case conn.body_params do
        %{"event" => event} when is_map(event) ->
          case SalixMeet.Runtime.deliver_event(tenant_id(conn), id, event) do
            {:ok, result} ->
              send_json(conn, 202, result)

            {:error, :not_found} ->
              send_json(conn, 404, %{error: "agent group not found"})

            {:error, {:invalid_meeting_agent, reason}} ->
              send_meeting_agent_conflict(conn, reason)

            {:error, reason} ->
              send_json(conn, 500, %{error: inspect(reason)})
          end

        _ ->
          send_json(conn, 400, %{error: "event is required"})
      end
    end)
  end

  post "/v1/agent-groups/:id/meeting-agent/runtime-events" do
    serve_meeting_runtime_event(conn, id)
  end

  get "/v1/remote-shell/client.py" do
    SalixWeb.RemoteShell.launcher(conn)
  end

  post "/v1/remote-shell/:group_id/registrations/:request_id" do
    SalixWeb.RemoteShell.register(conn, group_id, request_id)
  end

  get "/v1/device-connection/*path" do
    SalixWeb.DeviceConnection.serve(conn, path)
  end

  get "/v1/runtime/agent-groups/:id/conversations" do
    with_scoped_group(conn, id, fn ->
      case Conversations.list_group_conversations(id,
             limit: conn.query_params["limit"],
             cursor: conn.query_params["cursor"]
           ) do
        {:ok, page} -> send_json(conn, 200, page)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :invalid_cursor} -> send_json(conn, 400, %{error: "invalid cursor"})
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:id/conversations" do
    with_scoped_group(conn, id, fn ->
      case ConversationInput.create_group_conversation(id, conn.body_params) do
        {:ok, conversation} ->
          send_json(conn, 201, conversation)

        {:error, :exists} ->
          send_json(conn, 409, %{error: "conversation already exists"})

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:conflict, message}} ->
          send_json(conn, 409, %{error: message})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "agent group not found"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  # Live conversation event stream (must precede the :conversation_id routes).
  get "/v1/runtime/agent-groups/:id/conversations/events" do
    with_scoped_group(conn, id, fn -> SalixWeb.ConversationSSE.serve_group(conn, id) end)
  end

  get "/v1/runtime/agent-groups/:id/conversations/search" do
    with_scoped_group(conn, id, fn ->
      case Conversations.search_group_conversations(id, conn.query_params["q"],
             limit: conn.query_params["limit"]
           ) do
        {:ok, results} -> send_json(conn, 200, results)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:id/conversation-pins" do
    with_scoped_group(conn, id, fn ->
      case Conversations.list_conversation_pins(id, tenant_id(conn)) do
        {:ok, pins} -> send_json(conn, 200, pins)
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:id/conversations/:conversation_id" do
    with_scoped_group(conn, id, fn ->
      case Conversations.get_group_conversation(id, conversation_id) do
        {:ok, conversation} -> send_json(conn, 200, conversation)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:id/conversations/:conversation_id/transcript/seed" do
    with_scoped_group(conn, id, fn ->
      result =
        with {:ok, seed} <-
               ConversationSeedInput.prepare(
                 id,
                 conversation_id,
                 conn.body_params
               ) do
          ConversationServer.seed_group_conversation_transcript(id, conversation_id, seed)
        end

      case result do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  put "/v1/runtime/agent-groups/:id/conversations/:conversation_id/pin" do
    with_scoped_group(conn, id, fn ->
      case ConversationServer.pin_conversation(id, conversation_id, tenant_id(conn)) do
        {:ok, pin} -> send_json(conn, 200, pin)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  delete "/v1/runtime/agent-groups/:id/conversations/:conversation_id/pin" do
    with_scoped_group(conn, id, fn ->
      case ConversationServer.unpin_conversation(id, conversation_id, tenant_id(conn)) do
        :ok -> send_resp(conn, 204, "")
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  patch "/v1/runtime/agent-groups/:id/conversations/:conversation_id" do
    with_scoped_group(conn, id, fn ->
      result =
        TaskSchedules.update_conversation(id, conversation_id, conn.body_params)

      case result do
        {:ok, conversation} -> send_json(conn, 200, conversation)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  delete "/v1/runtime/agent-groups/:id/conversations/:conversation_id" do
    with_scoped_group(conn, id, fn ->
      case TaskSchedules.delete_conversation(id, conversation_id) do
        :ok -> send_resp(conn, 204, "")
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:id/conversations/:conversation_id/messages" do
    with_scoped_group(conn, id, fn ->
      case Conversations.list_group_conversation_messages(id, conversation_id,
             limit: conn.query_params["limit"],
             after_id: conn.query_params["after_id"],
             tail: conn.query_params["tail"]
           ) do
        {:ok, messages} -> send_json(conn, 200, messages)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:id/conversations/:conversation_id/participants" do
    with_scoped_group(conn, id, fn ->
      case Conversations.list_group_conversation_participants(id, conversation_id,
             limit: conn.query_params["limit"],
             cursor: conn.query_params["cursor"]
           ) do
        {:ok, page} -> send_json(conn, 200, page)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-groups/:id/conversations/:conversation_id/participants/:participant_id" do
    with_scoped_group(conn, id, fn ->
      case Conversations.get_group_conversation_participant(id, conversation_id, participant_id) do
        {:ok, participant} ->
          send_json(conn, 200, participant)

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "conversation participant not found"})

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:id/conversations/:conversation_id/messages" do
    with_scoped_group(conn, id, fn ->
      attrs =
        case conn.body_params do
          %{"kind" => "app_event"} = params ->
            Map.put(params, "delivery_filter", %{"participant_ids" => []})

          params ->
            params
        end

      case ConversationServer.append_group_conversation_message(
             id,
             conversation_id,
             attrs
           ) do
        {:ok, result} -> send_json(conn, 201, result)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, {:conflict, message}} -> send_json(conn, 409, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:id/conversations/:conversation_id/provider-participants/:participant_id/messages" do
    with_scoped_group(conn, id, fn ->
      case ConversationServer.send_provider_participant_message(
             id,
             conversation_id,
             participant_id,
             conn.body_params
           ) do
        {:ok, result} ->
          send_json(conn, 202, result)

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, {:conflict, message}} ->
          send_json(conn, 409, %{error: message})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "conversation participant not found"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agent-groups/:id/conversations/:conversation_id/activity-surface-dismissal" do
    with_scoped_group(conn, id, fn ->
      case ConversationServer.dismiss_group_conversation_activity_surface(id, conversation_id) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "conversation not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agent-activities" do
    send_json(conn, 200, Activity.list(tenant_id(conn)))
  end

  get "/v1/runtime/agent-activities/stream" do
    SalixWeb.ActivitySSE.serve(conn, tenant_id(conn))
  end

  get "/v1/runtime/agents" do
    opts = [status: conn.query_params["status"], group_id: conn.query_params["group_id"]]
    send_json(conn, 200, Control.list(tenant_id(conn), opts))
  end

  post "/v1/runtime/agents" do
    case Control.create(conn.body_params, tenant_id(conn)) do
      {:ok, agent} -> send_json(conn, 201, agent)
      {:error, :exists} -> send_json(conn, 409, %{error: "agent already exists"})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id" do
    result =
      if truthy?(conn.query_params["include_archived"]) do
        Control.get_including_archived(id, tenant_id(conn))
      else
        Control.get(id, tenant_id(conn))
      end

    case result do
      {:ok, agent} -> send_json(conn, 200, agent)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/billing-state" do
    case Billing.get_state(id, tenant_id(conn)) do
      {:ok, state} -> send_json(conn, 200, state)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  put "/v1/runtime/agents/:id/billing-state" do
    case Billing.put_state(id, conn.body_params, tenant_id(conn)) do
      {:ok, state} -> send_json(conn, 200, state)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/billing-history" do
    case Billing.list_history(
           id,
           [after_id: conn.query_params["after_id"], limit: conn.query_params["limit"]],
           tenant_id(conn)
         ) do
      {:ok, page} -> send_json(conn, 200, page)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/resource-usage-history" do
    case Billing.list_resource_usage_history(
           id,
           [after_id: conn.query_params["after_id"], limit: conn.query_params["limit"]],
           tenant_id(conn)
         ) do
      {:ok, page} -> send_json(conn, 200, page)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  patch "/v1/runtime/agents/:id" do
    case Control.configure(id, conn.body_params, tenant_id(conn)) do
      {:ok, agent} -> send_json(conn, 200, agent)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/archive" do
    case Control.delete(id, tenant_id(conn)) do
      {:ok, _agent} -> send_resp(conn, 204, "")
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/unarchive" do
    case Control.unarchive(id, tenant_id(conn)) do
      {:ok, _agent} -> send_resp(conn, 204, "")
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, :conflict} -> send_json(conn, 409, %{error: "agent was archived again"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/cancel" do
    case Control.cancel(id, tenant_id(conn)) do
      {:ok, agent} -> send_json(conn, 200, agent)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/wake" do
    case Control.wake(id, conn.body_params, tenant_id(conn)) do
      {:ok, agent} -> send_json(conn, 200, agent)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/heartbeat" do
    case Schedules.get_heartbeat(id, tenant_id(conn)) do
      {:ok, heartbeat} -> send_json(conn, 200, heartbeat)
      {:error, :not_found} -> send_json(conn, 404, %{error: "heartbeat not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  put "/v1/runtime/agents/:id/heartbeat" do
    case Schedules.upsert_heartbeat(id, conn.body_params, tenant_id(conn)) do
      {:ok, heartbeat} -> send_json(conn, 200, heartbeat)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/heartbeat/pause" do
    case Schedules.pause_heartbeat(id, tenant_id(conn)) do
      {:ok, heartbeat} -> send_json(conn, 200, heartbeat)
      {:error, :not_found} -> send_json(conn, 404, %{error: "heartbeat not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/heartbeat/resume" do
    case Schedules.resume_heartbeat(id, tenant_id(conn)) do
      {:ok, heartbeat} -> send_json(conn, 200, heartbeat)
      {:error, :not_found} -> send_json(conn, 404, %{error: "heartbeat not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/schedules" do
    case Schedules.list(id, tenant_id(conn)) do
      {:ok, schedules} -> send_json(conn, 200, schedules)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/schedules/:schedule_id/runs" do
    case Schedules.list_runs(id, schedule_id, tenant_id(conn)) do
      {:ok, runs} -> send_json(conn, 200, runs)
      {:error, :not_found} -> send_json(conn, 404, %{error: "schedule not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/schedules/:schedule_id/pause" do
    case Schedules.pause(id, schedule_id, tenant_id(conn)) do
      {:ok, schedule} -> send_json(conn, 200, schedule)
      {:error, :not_found} -> send_json(conn, 404, %{error: "schedule not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agents/:id/schedules/:schedule_id/resume" do
    case Schedules.resume(id, schedule_id, tenant_id(conn)) do
      {:ok, schedule} -> send_json(conn, 200, schedule)
      {:error, :not_found} -> send_json(conn, 404, %{error: "schedule not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/runtime/agents/:id/schedules/:schedule_id" do
    case Schedules.delete(id, schedule_id, tenant_id(conn)) do
      :ok -> send_resp(conn, 204, "")
      {:error, :not_found} -> send_json(conn, 404, %{error: "schedule not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/v1/runtime/agents/:id" do
    case Control.delete(id, tenant_id(conn)) do
      {:ok, agent} -> send_json(conn, 200, agent)
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/connect" do
    SalixWeb.Connect.upgrade(conn, tenant_id(conn))
  end

  get "/v1/runtime/environments" do
    send_json(conn, 200, EnvControl.list_environments(tenant_id(conn)))
  end

  get "/v1/runtime/groups/:group_id/environments/:id" do
    case EnvControl.get_environment(id, group_id, tenant_id(conn)) do
      {:ok, env} -> send_json(conn, 200, env)
      {:error, :not_found} -> send_json(conn, 404, %{error: "environment not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/probe" do
    case EnvControl.probe_runtime(id, device_runtime_id, group_id, tenant_id(conn)) do
      {:ok, result} ->
        send_json(conn, 200, result)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "runtime not found"})

      {:error, reason} when reason in [:connector_disconnected, :runtime_probe_unsupported] ->
        send_json(conn, 409, %{error: to_string(reason)})

      {:error, :timeout} ->
        send_json(conn, 504, %{error: "runtime probe timed out"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/sessions" do
    case EnvControl.runtime_sessions(id, device_runtime_id, group_id, tenant_id(conn)) do
      {:ok, snapshot} -> send_json(conn, 200, snapshot)
      {:error, :not_found} -> send_json(conn, 404, %{error: "runtime not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/v1/runtime/agent-groups/:group_id/agents/:id/cloud-vm/runtimes" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {:ok, %{"group_id" => ^group_id} = agent} <- SalixAgent.Control.get(id, tenant_id(conn)),
         {:ok, result} <- SalixWeb.CloudVM.Runtimes.request(agent, conn.body_params) do
      send_json(conn, 202, result)
    else
      _ -> send_json(conn, 409, %{error: "cloud_vm_runtime_unavailable"})
    end
  end

  get "/v1/runtime/groups/:group_id/cloud-vm/runtimes/:request_id" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case SalixWeb.CloudVM.Runtimes.get(tenant_id(conn), group_id, request_id) do
      {:ok, result} -> send_json(conn, 200, result)
      _ -> send_json(conn, 404, %{error: "not_found"})
    end
  end

  put "/v1/runtime/groups/:group_id/cloud-vm/runtimes/:request_id/managed-auth" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case SalixWeb.CloudVM.Runtimes.bind_account(
           tenant_id(conn),
           group_id,
           request_id,
           conn.body_params["account_id"]
         ) do
      {:ok, result} -> send_json(conn, 200, result)
      _ -> send_json(conn, 409, %{error: "runtime_account_unavailable"})
    end
  end

  delete "/v1/runtime/groups/:group_id/cloud-vm/runtimes/:request_id/managed-auth" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case SalixWeb.CloudVM.Runtimes.unbind_account(tenant_id(conn), group_id, request_id) do
      {:ok, result} -> send_json(conn, 200, result)
      _ -> send_json(conn, 409, %{error: "runtime_account_unavailable"})
    end
  end

  match "/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/managed-auth",
    via: [:get, :put, :delete] do
    operation = %{"GET" => :read, "PUT" => :bind, "DELETE" => :unbind}[conn.method]
    conn = put_resp_header(conn, "cache-control", "no-store")

    case SalixWeb.SubscriptionRuntimeAuth.managed(
           tenant_id(conn),
           group_id,
           id,
           device_runtime_id,
           operation,
           conn.params
         ) do
      {:ok, result} ->
        case SalixWeb.SubscriptionRuntimeAuth.accounts(
               tenant_id(conn),
               result["provider"],
               conn.params["account_cursor"] || ""
             ) do
          {:ok, accounts} ->
            send_json(conn, 200, Map.merge(result, accounts))

          _ ->
            send_json(
              conn,
              200,
              Map.merge(result, %{
                "accounts" => [],
                "accounts_next" => "",
                "accounts_unavailable" => true
              })
            )
        end

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "runtime_not_found"})

      {:error, :invalid_input} ->
        send_json(conn, 422, %{error: "invalid_input"})

      {:error, _} ->
        send_json(conn, 409, %{error: "runtime_account_unavailable"})
    end
  end

  get "/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/auth" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case EnvControl.runtime_auth_read(id, device_runtime_id, group_id, tenant_id(conn)) do
      {:ok, %{"auth" => auth}} -> send_json(conn, 200, %{"auth" => auth})
      {:error, reason} -> send_runtime_auth_error(conn, reason)
    end
  end

  post "/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/auth/login" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case EnvControl.runtime_auth_login_start(
           id,
           device_runtime_id,
           conn.body_params["flow"],
           group_id,
           tenant_id(conn)
         ) do
      {:ok, ceremony} -> send_json(conn, 200, ceremony)
      {:error, reason} -> send_runtime_auth_error(conn, reason)
    end
  end

  delete "/v1/runtime/groups/:group_id/environments/:id/runtimes/:device_runtime_id/auth/login" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    case EnvControl.runtime_auth_login_cancel(
           id,
           device_runtime_id,
           conn.body_params["attempt_id"],
           group_id,
           tenant_id(conn)
         ) do
      {:ok, %{"auth" => auth, "canceled" => canceled}} ->
        send_json(conn, 200, %{"auth" => auth, "canceled" => canceled})

      {:error, reason} ->
        send_runtime_auth_error(conn, reason)
    end
  end

  get "/v1/runtime/agent-groups/:group_id/agents/:id/external-worker/auth" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_scoped_group(conn, group_id, fn ->
      with_scoped_agent(conn, id, fn agent ->
        attrs = Map.put(conn.query_params, "group_id", group_id)

        case ComputeRuntimeAuth.call_for_external_worker(:read, agent, attrs) do
          {:ok, result} -> send_json(conn, 200, result)
          {:error, reason} -> send_runtime_auth_error(conn, reason)
        end
      end)
    end)
  end

  post "/v1/runtime/agent-groups/:group_id/agents/:id/external-worker/auth/login" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_scoped_group(conn, group_id, fn ->
      with_scoped_agent(conn, id, fn agent ->
        attrs = Map.put(conn.body_params, "group_id", group_id)

        case ComputeRuntimeAuth.call_for_external_worker(:login_start, agent, attrs) do
          {:ok, ceremony} -> send_json(conn, 200, ceremony)
          {:error, reason} -> send_runtime_auth_error(conn, reason)
        end
      end)
    end)
  end

  delete "/v1/runtime/agent-groups/:group_id/agents/:id/external-worker/auth/login" do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with_scoped_group(conn, group_id, fn ->
      with_scoped_agent(conn, id, fn agent ->
        attrs = Map.put(conn.body_params, "group_id", group_id)

        case ComputeRuntimeAuth.call_for_external_worker(:login_cancel, agent, attrs) do
          {:ok, result} -> send_json(conn, 200, result)
          {:error, reason} -> send_runtime_auth_error(conn, reason)
        end
      end)
    end)
  end

  delete "/v1/runtime/groups/:group_id/environments/:id" do
    case EnvControl.delete_environment(id, group_id, tenant_id(conn)) do
      {:ok, env} -> send_json(conn, 200, env)
      {:error, :not_found} -> send_json(conn, 404, %{error: "environment not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/messages/search" do
    with_scoped_agent(conn, id, fn agent ->
      case SalixAgent.Runtime.search_messages(
             agent,
             conn.query_params["q"],
             conn.query_params["limit"]
           ) do
        {:ok, results} -> send_json(conn, 200, results)
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agents/:id/sites" do
    with_scoped_agent(conn, id, fn agent ->
      case Workspace.list_sites(agent) do
        {:ok, sites} -> send_json(conn, 200, sites)
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/hosted-sites" do
    case Workspace.list_hosted_sites(tenant_id(conn),
           limit: conn.query_params["limit"],
           offset: conn.query_params["offset"]
         ) do
      {:ok, page} -> send_json(conn, 200, page)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/v1/runtime/agents/:id/files" do
    with_scoped_agent(conn, id, fn _agent -> serve_agent_file(conn, id, "/") end)
  end

  get "/v1/runtime/agents/:id/files/*path" do
    with_scoped_agent(conn, id, fn _agent ->
      serve_agent_file(conn, id, "/" <> Enum.join(path, "/"))
    end)
  end

  put "/v1/runtime/agents/:id/files/*path" do
    with_scoped_agent(conn, id, fn _agent ->
      with {:ok, body, conn} <- read_limited_body(conn) do
        case Workspace.write(id, "/" <> Enum.join(path, "/"), body,
               idempotency_key: request_idempotency_key(conn)
             ) do
          {:ok, file} -> send_json(conn, 200, file)
          {:error, :bad_path} -> send_json(conn, 400, %{error: "invalid file path"})
          {:error, :too_large} -> send_json(conn, 413, %{error: "file too large"})
          {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
          {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
        end
      else
        {:error, :too_large, conn} -> send_json(conn, 413, %{error: "file too large"})
        {:error, reason, conn} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  delete "/v1/runtime/agents/:id/files/*path" do
    recursive? = conn.query_params["recursive"] in ["true", "1", "yes"]

    with_scoped_agent(conn, id, fn _agent ->
      case Workspace.delete(id, "/" <> Enum.join(path, "/"),
             recursive: recursive?,
             idempotency_key: request_idempotency_key(conn)
           ) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, :bad_path} -> send_json(conn, 400, %{error: "invalid file path"})
        {:error, :directory_not_empty} -> send_json(conn, 409, %{error: "directory not empty"})
        {:error, :not_found} -> send_json(conn, 404, %{error: "file not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agents/:id/sessions" do
    include_hidden = conn.query_params["include_hidden"] in ["1", "true", "yes"]

    with_scoped_agent(conn, id, fn agent ->
      case SalixAgent.Runtime.list_sessions(agent, include_hidden: include_hidden) do
        {:ok, sessions} -> send_json(conn, 200, sessions)
        {:error, :not_found} -> send_json(conn, 404, %{error: "agent not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agents/:id/sessions/:sid" do
    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.get_session(agent, sid, projection: :status) do
        {:ok, session} -> send_json(conn, 200, session)
        {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agents/:id/sessions/:sid/status" do
    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.get_session_status(agent, sid) do
        {:ok, status} -> send_json(conn, 200, status)
        {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agents/:id/sessions/:sid/trace" do
    limit = conn.query_params["limit"]

    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.session_trace(agent, sid, limit: limit) do
        {:ok, trace} -> send_json(conn, 200, trace)
        {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agents/:id/sessions/:sid/fork" do
    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.fork_session(agent, sid, conn.body_params) do
        {:ok, session} ->
          send_json(conn, 201, session)

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "session not found"})

        {:error, :fork_cutoff_below_compaction} ->
          send_json(conn, 400, %{
            error: "fork cutoff message_id is below the compaction boundary"
          })

        {:error, :fork_target_conflict} ->
          send_json(conn, 409, %{
            error: "fork target session already exists for a different fork request"
          })

        {:error, :fork_identity_required} ->
          send_json(conn, 400, %{error: "fork requires a fork_request_id"})

        {:error, :invalid_session_id} ->
          send_json(conn, 400, %{error: "target_session_id is not a valid session id"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agents/:id/sessions/:sid/compact" do
    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.compact_session(agent, sid) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agents/:id/sessions/:sid/microcompact" do
    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.microcompact_session(agent, sid) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agents/:id/sessions/:sid/transcript/seed" do
    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.seed_transcript(agent, sid, conn.body_params) do
        {:ok, result} -> send_json(conn, 200, result)
        {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
        {:error, :not_found} -> send_json(conn, 404, %{error: "session not found"})
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agents/:id/sessions/:sid/tools/:tool_name" do
    with_scoped_session(conn, id, sid, fn agent ->
      case execute_session_tool_http(
             agent,
             sid,
             tool_name,
             conn.body_params,
             tenant_id(conn)
           ) do
        {:ok, %{error: true, content: content}} ->
          send_json(conn, 500, %{error: content})

        {:ok, %{content: content}} ->
          send_tool_content(conn, content)

        {:error, :busy} ->
          send_json(conn, 409, %{error: "agent is busy"})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "session not found"})

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  post "/v1/runtime/agents/:id/sessions/:sid/messages" do
    with_scoped_session(conn, id, sid, fn _agent ->
      body = conn.body_params
      content = body["content"]

      payload =
        %{}
        |> put_if(:content, content)
        |> put_if(:session_id, sid)
        |> put_if(:role, body["role"] || "user")
        |> put_if(:created_at, System.system_time(:second))

      opts =
        []
        |> Keyword.put(:create, false)
        |> maybe_opt(:source_message_id, body["source_message_id"])
        |> maybe_opt(:no_wake, body["no_wake"])

      case SalixAgent.deliver(id, payload, opts) do
        {:ok, status} ->
          send_json(conn, 202, %{accepted: true, dedupe: status, session_id: sid})

        {:error, {:bad_request, message}} ->
          send_json(conn, 400, %{error: message})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agents/:id/sessions/:sid/messages" do
    with_scoped_session(conn, id, sid, fn agent ->
      case SalixAgent.Runtime.get_session_messages(agent, sid) do
        {:ok, session} ->
          messages = session["messages"] || session[:messages] || []

          send_json(conn, 200, %{
            session_id: sid,
            status: session["status"] || session[:status],
            last_ack_message_id: session["last_ack_message_id"] || session[:last_ack_message_id],
            messages: Enum.map(messages, &message_json/1),
            # Live-window scope metadata: consumers must not read a hot
            # boundary as "no more history".
            archived_through: session["archived_through"] || 0,
            history_truncated: session["history_truncated"] || false
          })

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "session not found"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  get "/v1/runtime/agents/:id/sessions/:sid/stream" do
    with_scoped_session(conn, id, sid, fn agent -> SalixWeb.SSE.serve(conn, agent, sid) end)
  end

  # Agent-scoped activity feed. The Commaboard proxy maps a user's
  # `/v1/user/agent/activities*` to these, keeping a shared-tenant deployment
  # from exposing other agents' activity (unlike the tenant-wide
  # `/v1/runtime/agent-activities*` above).
  get "/v1/runtime/agents/:id/activities" do
    with_scoped_agent(conn, id, fn agent -> send_json(conn, 200, Activity.list_agent(agent)) end)
  end

  get "/v1/runtime/agents/:id/activities/stream" do
    with_scoped_agent(conn, id, fn agent -> SalixWeb.ActivitySSE.serve_agent(conn, agent) end)
  end

  get "/v1/im/slack/oauth/callback" do
    state = trim(conn.query_params["state"])
    code = trim(conn.query_params["code"])

    cond do
      state == "" or code == "" ->
        send_oauth_callback_page(conn, 400, "slack", "state and code are required")

      true ->
        sync_im_public_base_url()

        with {:ok, connect} <- ProviderConnects.find_slack_im_connect_by_oauth_state(state),
             {:ok, oauth} <- ProviderHTTP.exchange_slack_oauth(connect, code),
             {:ok, _completed} <- ProviderConnects.complete_slack_im_connect_oauth(connect, oauth) do
          send_oauth_callback_page(conn, 200, "slack")
        else
          {:error, :not_found} ->
            send_oauth_callback_page(conn, 404, "slack", "Slack connect not found")

          {:error, reason} ->
            send_oauth_callback_page(conn, 502, "slack", inspect(reason))
        end
    end
  end

  post "/v1/im/slack/events" do
    envelope = conn.body_params || %{}

    case slack_url_verification(envelope) do
      {:ok, challenge} ->
        send_resp(conn, 200, challenge)

      {:error, :invalid_envelope} ->
        send_json(conn, 400, %{error: "malformed Slack url_verification challenge"})

      :not_url_verification ->
        case ProviderHTTP.handle_slack_request(
               envelope["api_app_id"],
               envelope,
               conn.req_headers,
               conn.assigns[:raw_body] || ""
             ) do
          {:ok, :accepted} ->
            send_json(conn, 200, %{ok: true})

          {:ok, :duplicate} ->
            send_json(conn, 200, %{duplicate: true})

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "Slack connect not found"})

          {:error, :invalid_signature} ->
            send_json(conn, 401, %{error: "invalid Slack signature"})

          {:error, :team_mismatch} ->
            send_json(conn, 401, %{error: "Slack team mismatch"})

          {:error, :ignored} ->
            send_json(conn, 200, %{ignored: true})

          {:error, {:ignored, reason}} ->
            send_json(conn, 200, %{ignored: true, ignored_reason: to_string(reason)})

          {:error, :router_not_configured} ->
            send_json(conn, 409, %{error: "router agent not configured"})

          {:error, :scan_capacity_exhausted} ->
            send_json(conn, 503, %{error: "identity resolution over scan capacity, retry"})

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  post "/v1/im/slack/commands" do
    case ProviderHTTP.handle_slack_command(
           conn.body_params,
           conn.req_headers,
           conn.assigns[:raw_body] || ""
         ) do
      {:ok, :queued} ->
        send_resp(conn, 200, "")

      {:error, :command_text_too_long} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text: "The task description is too long to publish in full. Shorten it and try again."
        })

      {:error, :command_thread_pending} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text:
            "This command is still being processed, or its channel message could not be confirmed. Check the channel before submitting again."
        })

      {:error, :command_delivery_unavailable} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text:
            "Could not confirm task submission. A channel message or task may already exist; check the thread before submitting again."
        })

      {:error, :command_thread_failed} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text:
            "Could not publish your task prompt in this channel. No task was submitted. Try again."
        })

      {:error, :command_unavailable} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text:
            "This command is not enabled for this Slack App. Ask an administrator to configure it."
        })

      {:error, :empty_command_text} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text: "Enter a task description after #{conn.body_params["command"]}."
        })

      {:error, :command_channel_inaccessible} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text:
            "Invite this app to the channel, then try again. You can also use a channel it has joined."
        })

      {:error, :command_channel_archived} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text: "This channel is archived. Use an active channel that this app has joined."
        })

      {:error, :command_channel_scope_missing} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text:
            "This app lacks permission to read this conversation. Ask an administrator to grant the matching conversation read scope and reinstall the app."
        })

      {:error, :command_channel_check_unavailable} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text: "Could not check this app's channel access. No task was submitted. Try again."
        })

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "Slack connection not found"})

      {:error, :invalid_signature} ->
        send_json(conn, 401, %{error: "Invalid Slack signature"})

      {:error, :team_mismatch} ->
        send_json(conn, 401, %{error: "Slack workspace mismatch"})

      {:error, :invalid_envelope} ->
        send_json(conn, 400, %{error: "Invalid Slack command"})

      {:error, :ignored} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text: "This Slack connection is currently unavailable."
        })

      {:error, :router_not_configured} ->
        send_json(conn, 200, %{
          response_type: "ephemeral",
          text: "Configure a Router for this Group first."
        })

      {:error, :scan_capacity_exhausted} ->
        send_json(conn, 503, %{error: "Slack connection lookup is busy. Try again."})

      {:error, _reason} ->
        send_json(conn, 503, %{error: "Slack command delivery failed. Try again."})
    end
  end

  post "/v1/im/slack/interactions" do
    with encoded when is_binary(encoded) <- conn.body_params["payload"],
         {:ok, payload} when is_map(payload) <- Jason.decode(encoded) do
      case ProviderHTTP.handle_slack_interaction(
             payload["api_app_id"],
             payload,
             conn.req_headers,
             conn.assigns[:raw_body] || ""
           ) do
        {:ok, :accepted} ->
          send_json(conn, 200, %{ok: true})

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "Slack connect not found"})

        {:error, :invalid_signature} ->
          send_json(conn, 401, %{error: "invalid Slack signature"})

        {:error, :team_mismatch} ->
          send_json(conn, 401, %{error: "Slack team mismatch"})

        {:error, :ignored} ->
          send_json(conn, 200, %{ignored: true})

        {:error, {:ignored, reason}} ->
          send_json(conn, 200, %{ignored: true, ignored_reason: to_string(reason)})

        {:error, reason}
        when reason in [
               :invalid_checkbox_action,
               :invalid_checkbox_selection,
               :checkbox_action_not_found,
               :ambiguous_checkbox_action
             ] ->
          send_json(conn, 400, %{error: to_string(reason)})

        {:error, :scan_capacity_exhausted} ->
          send_json(conn, 503, %{error: "identity resolution over scan capacity, retry"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      _other -> send_json(conn, 400, %{error: "malformed Slack interaction payload"})
    end
  end

  post "/v1/im/feishu/events" do
    envelope = conn.body_params || %{}

    with {:ok, event_app_id} <- feishu_event_app_id(envelope),
         {:ok, query_app_id} <- optional_trimmed_binary(conn.query_params["app_id"]) do
      app_id = event_app_id || query_app_id

      case ProviderHTTP.handle_feishu_request(
             app_id,
             envelope,
             conn.req_headers,
             conn.assigns[:raw_body] || ""
           ) do
        {:ok, response} ->
          send_json(conn, 200, response)

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "Feishu connect not found"})

        {:error, :invalid_signature} ->
          send_json(conn, 401, %{error: "invalid Feishu signature"})

        {:error, :invalid_token} ->
          send_json(conn, 401, %{error: "invalid Feishu token"})

        {:error, :invalid_envelope} ->
          send_json(conn, 400, %{error: "malformed Feishu envelope"})

        {:error, :ignored} ->
          send_json(conn, 200, %{ignored: true})

        {:error, {:ignored, reason}} ->
          send_json(conn, 200, %{ignored: true, ignored_reason: to_string(reason)})

        {:error, :scan_capacity_exhausted} ->
          send_json(conn, 503, %{error: "identity resolution over scan capacity, retry"})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:error, :invalid_envelope} ->
        send_json(conn, 400, %{error: "malformed Feishu envelope"})
    end
  end

  get "/v1/admin/e2e-reports/runs" do
    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, runs} = E2EReports.list_runs(conn.query_params)
    send_json(conn, 200, %{runs: runs})
  end

  get "/v1/admin/e2e-reports/runs/:run_id" do
    conn = Plug.Conn.fetch_query_params(conn)

    case E2EReports.get_run(run_id, conn.query_params["attempt"]) do
      {:ok, run} -> send_json(conn, 200, run)
      {:error, reason} -> send_e2e_error(conn, reason)
    end
  end

  delete "/v1/admin/e2e-reports/runs/:run_id" do
    conn = Plug.Conn.fetch_query_params(conn)

    case E2EReports.delete_run(run_id, conn.query_params["attempt"]) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, reason} -> send_e2e_error(conn, reason)
    end
  end

  post "/v1/admin/e2e-reports/report-sessions" do
    case E2EReports.create_report_session(conn.body_params) do
      {:ok, session} -> send_json(conn, 201, session)
      {:error, reason} -> send_e2e_error(conn, reason)
    end
  end

  get "/v1/admin/e2e-reports/artifacts" do
    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, artifacts} = E2EReports.list_artifacts(conn.query_params)
    send_json(conn, 200, %{artifacts: artifacts})
  end

  post "/v1/admin/e2e-reports/artifacts/cleanup-preview" do
    case E2EReports.cleanup_preview(conn.body_params) do
      {:ok, preview} -> send_json(conn, 200, preview)
      {:error, reason} -> send_e2e_error(conn, reason)
    end
  end

  post "/v1/admin/e2e-reports/artifacts/cleanup" do
    case E2EReports.cleanup(conn.body_params) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, reason} -> send_e2e_error(conn, reason)
    end
  end

  get "/v1/e2e-report-sessions/:token/*path" do
    case E2EReports.serve_report_file(token, path) do
      {:ok, %{body: body, content_type: content_type}} ->
        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, body)

      {:error, reason} ->
        send_e2e_error(conn, reason)
    end
  end

  # Public path-addressed website serving for VFS website roots.
  get "/site/:id/:site" do
    SalixWeb.Site.serve(conn, id, site, [])
  end

  get "/site/:id/:site/*path" do
    SalixWeb.Site.serve(conn, id, site, path)
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # ---- helpers ----

  defp tenant_id(conn), do: conn.assigns[:tenant_id]

  defp agent_defaults_json(config, tenant_id) do
    config
    |> Map.put("defaults", SalixAgent.AgentDefaults.public_json(config, tenant_id))
    |> Map.put("effective", SalixAgent.AgentDefaults.effective_role_defaults(tenant_id))
  end

  defp serve_router_inbox_post_message(conn, group_id) do
    raw_body = conn.assigns[:raw_body]

    cond do
      conn.assigns[:auth_role] != :group_api_key ->
        send_json(conn, 401, %{error: "unauthorized"})

      conn.assigns[:raw_body_too_large] == true or
          (is_binary(raw_body) and byte_size(raw_body) > Salix.App.RouterInbox.max_body_bytes()) ->
        send_json(conn, 413, %{error: "payload_too_large"})

      not is_map(conn.body_params) or match?(%Plug.Conn.Unfetched{}, conn.body_params) ->
        send_json(conn, 400, %{error: "invalid_json"})

      true ->
        case Salix.App.RouterInbox.post_message(
               conn.assigns[:group_api_key],
               group_id,
               conn.body_params
             ) do
          {:ok, result} ->
            send_json(conn, 202, result)

          {:error, {:invalid_request, field, reason}} ->
            send_json(conn, 422, %{error: "invalid_request", field: field, reason: reason})

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "agent group not found"})

          {:error, :router_not_configured} ->
            send_json(conn, 409, %{error: "router_not_configured"})

          {:error, {:rate_limited, retry_after}} ->
            conn
            |> put_resp_header("retry-after", Integer.to_string(retry_after))
            |> send_json(429, %{error: "rate_limited"})

          {:error, :unavailable} ->
            send_json(conn, 503, %{error: "unavailable"})
        end
    end
  end

  defp serve_loop_event(conn, group_id, loop_id) do
    raw_body = conn.assigns[:raw_body]
    key = conn.assigns[:group_api_key]

    cond do
      conn.assigns[:auth_role] != :group_api_key ->
        send_json(conn, 401, %{error: "unauthorized"})

      conn.assigns[:raw_body_too_large] == true or
          (is_binary(raw_body) and byte_size(raw_body) > Salix.App.RouterInbox.max_body_bytes()) ->
        send_json(conn, 413, %{error: "payload_too_large"})

      not is_map(conn.body_params) or match?(%Plug.Conn.Unfetched{}, conn.body_params) ->
        send_json(conn, 400, %{error: "invalid_json"})

      key["group_id"] != group_id ->
        send_json(conn, 404, %{error: "loop not found"})

      true ->
        event =
          conn.body_params
          |> Map.take(["event_id", "topic", "payload"])
          |> Map.put_new("event_id", idempotency_key(conn))

        case SalixAgent.Loops.deliver_external_event(group_id, loop_id, event) do
          {:ok, reply} ->
            send_json(conn, 202, %{
              status: "accepted",
              duplicate: reply["duplicate"] == true,
              event_id: event["event_id"]
            })

          {:error, {:invalid_event, field}} ->
            send_json(conn, 422, %{error: "invalid_request", field: field})

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "loop not found"})

          {:error, {:not_active, status}} ->
            send_json(conn, 409, %{error: "loop_not_active", status: status})

          {:error, :not_resident} ->
            send_json(conn, 503, %{error: "loop_not_running"})

          {:error, :mailbox_full} ->
            conn
            |> put_resp_header("retry-after", "5")
            |> send_json(429, %{error: "mailbox_full"})

          {:error, _reason} ->
            send_json(conn, 503, %{error: "unavailable"})
        end
    end
  end

  defp idempotency_key(conn) do
    case Plug.Conn.get_req_header(conn, "idempotency-key") do
      [value | _] when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp send_group_api_key_error(conn, reason) do
    case reason do
      {:bad_request, message} -> send_json(conn, 400, %{error: message})
      :not_found -> send_json(conn, 404, %{error: "api key not found"})
      {:conflict, message} -> send_json(conn, 409, %{error: message})
      :unavailable -> send_json(conn, 503, %{error: "unavailable"})
      {:unavailable, _} -> send_json(conn, 503, %{error: "unavailable"})
      other -> send_json(conn, 500, %{error: inspect(other)})
    end
  end

  defp sync_im_public_base_url do
    SalixWeb.Application.sync_im_public_base_url()
  end

  defp send_signal_result(conn, {:ok, body}), do: send_json(conn, 200, body)

  defp send_signal_result(conn, {:error, reason}) do
    {status, error} = Salix.Control.Signal.http_error(reason)
    send_json(conn, status, %{error: error})
  end

  defp with_scoped_group(conn, group_id, fun) do
    request_tenant = tenant_id(conn)

    case {conn.assigns[:auth_role], Groups.get(group_id, request_tenant)} do
      {:tenant, {:ok, _group}} ->
        fun.()

      {:tenant, {:error, :not_found}} ->
        send_json(conn, 404, %{error: "agent group not found"})

      {_role, {:ok, _group}} ->
        send_json(conn, 404, %{error: "agent group not found"})

      {_role, {:error, :not_found}} ->
        send_json(conn, 404, %{error: "agent group not found"})

      {_role, {:error, reason}} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp with_scoped_agent(conn, agent_id, fun) do
    request_tenant = tenant_id(conn)

    case {conn.assigns[:auth_role], Control.get_record(agent_id)} do
      {:tenant, {:ok, %{"tenant_id" => tenant} = agent}} when tenant == request_tenant ->
        if Control.visible?(agent),
          do: fun.(agent),
          else: send_json(conn, 404, %{error: "agent not found"})

      {:tenant, {:ok, _agent}} ->
        send_json(conn, 404, %{error: "agent not found"})

      {:tenant, {:error, :not_found}} ->
        send_json(conn, 404, %{error: "agent not found"})

      {_role, {:ok, _agent}} ->
        send_json(conn, 404, %{error: "agent not found"})

      {_role, {:error, :not_found}} ->
        send_json(conn, 404, %{error: "agent not found"})

      {_role, {:error, reason}} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp with_scoped_session(conn, agent_id, session_id, fun) do
    if SalixStore.Ids.valid_session_id?(session_id),
      do: with_scoped_agent(conn, agent_id, fun),
      else: send_json(conn, 400, %{error: "invalid session_id"})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp decode_b64_json(value) when is_binary(value) do
    with {:ok, raw} <- Base.decode64(value),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(raw) do
      {:ok, decoded}
    else
      _ -> {:error, :invalid_encoding}
    end
  end

  defp decode_b64_json(_), do: {:error, :invalid_encoding}

  defp registry_request(params) do
    with {:ok, request} <- decode_b64_json(params["request_json_b64"]),
         {:ok, canonical} <- optional_decode_bytes(params["canonical_b64"]),
         {:ok, descriptor_canonical} <- optional_decode_bytes(params["descriptor_canonical_b64"]) do
      {:ok, request, canonical, descriptor_canonical}
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
         SalixStore.PersonalMeshProto.registry_operation_signing_input(attrs)
       )}
    else
      _ -> {:error, :invalid_operation}
    end
  end

  defp registry_snapshot_response(conn, snapshot, kind) do
    encoded =
      case kind do
        :commit -> SalixStore.PersonalMeshProto.encode_commit_response(snapshot)
        :endpoint -> SalixStore.PersonalMeshProto.encode_endpoint_response(snapshot)
        :snapshot -> SalixStore.PersonalMeshProto.encode_snapshot(snapshot).snapshot
      end

    send_json(conn, 200, %{response_b64: Base.encode64(encoded)})
  rescue
    _ -> send_json(conn, 503, %{error: "registry_signer_unavailable"})
  end

  defp registry_error(conn, {:error, reason})
       when reason in [:revision_conflict, :stale_generation, :remove_wins, :operation_conflict],
       do: send_json(conn, 409, %{error: to_string(reason)})

  defp registry_error(conn, {:error, :unavailable}),
    do: send_json(conn, 503, %{error: "registry_unavailable"})

  defp registry_error(conn, _), do: send_json(conn, 422, %{error: "invalid_registry_request"})

  defp registry_member_root(mesh_id, device_id) do
    case SalixStore.Repo.get_by(SalixStore.PersonalMeshRegistry.Member,
           mesh_id: mesh_id,
           device_id: device_id
         ) do
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
  # OAuth list endpoints return a plain list, or `{:error, :unavailable}` when the
  # control store is down. Map the fault to 503 rather than JSON-encoding the
  # tuple (which would raise Protocol.UndefinedError and 500 the request).
  defp send_json_list(conn, {:error, :unavailable}),
    do: send_json(conn, 503, %{error: "unavailable"})

  defp send_json_list(conn, list) when is_list(list), do: send_json(conn, 200, list)

  defp send_oauth_callback_response(conn, response) do
    case response do
      {:redirect, location} ->
        conn
        |> put_resp_header("location", location)
        |> send_resp(303, "")

      {:page, status, html} ->
        conn
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(status, html)

      {:json, status, body} ->
        send_json(conn, status, body)
    end
  end

  defp send_e2e_error(conn, :not_found), do: send_json(conn, 404, %{error: "not found"})
  defp send_e2e_error(conn, :invalid_token), do: send_json(conn, 401, %{error: "invalid token"})
  defp send_e2e_error(conn, :invalid_path), do: send_json(conn, 400, %{error: "invalid path"})
  defp send_e2e_error(conn, :invalid_scope), do: send_json(conn, 400, %{error: "invalid scope"})

  defp send_e2e_error(conn, :outside_prefix),
    do: send_json(conn, 400, %{error: "outside e2e reports prefix"})

  defp send_e2e_error(conn, :confirmation_required),
    do: send_json(conn, 400, %{error: "confirm must be true"})

  defp send_e2e_error(conn, :session_secret_missing),
    do: send_json(conn, 500, %{error: "session secret is not configured"})

  defp send_e2e_error(conn, {:missing, field}),
    do: send_json(conn, 400, %{error: "#{field} is required"})

  defp send_e2e_error(conn, {:partial_failure, result}) do
    send_json(conn, 500, Map.put(result, :error, "partial cleanup failure"))
  end

  defp send_e2e_error(conn, reason), do: send_json(conn, 500, %{error: inspect(reason)})

  defp send_mcp_result(conn, {:ok, result}), do: send_json(conn, 200, result)

  defp send_mcp_result(conn, {:error, {:bad_request, message}}),
    do: send_json(conn, 400, %{error: message})

  defp send_mcp_result(conn, {:error, {:device_runtime_required, message}}),
    do: send_json(conn, 400, %{error: message})

  defp send_mcp_result(conn, {:error, {:device_runtime_not_found, message}}),
    do: send_json(conn, 400, %{error: message})

  defp send_mcp_result(conn, {:error, {:device_runtime_unavailable, message}}),
    do: send_json(conn, 400, %{error: message})

  defp send_mcp_result(conn, {:error, :not_found}),
    do: send_json(conn, 404, %{error: "MCP binding not found"})

  defp send_mcp_result(conn, {:error, reason}),
    do: send_json(conn, 500, %{error: inspect(reason)})

  defp send_plugin_result(conn, result, ok_status \\ 200)
  defp send_plugin_result(conn, {:ok, result}, ok_status), do: send_json(conn, ok_status, result)

  defp send_plugin_result(conn, {:error, {:bad_request, message}}, _ok_status),
    do: send_json(conn, 400, %{error: message})

  defp send_plugin_result(conn, {:error, :exists}, _ok_status),
    do: send_json(conn, 409, %{error: "plugin already exists"})

  defp send_plugin_result(conn, {:error, :not_found}, _ok_status),
    do: send_json(conn, 404, %{error: "plugin not found"})

  defp send_plugin_result(conn, {:error, reason}, _ok_status),
    do: send_json(conn, 500, %{error: inspect(reason)})

  defp serve_meeting_agent_status(conn, group_id) do
    with_scoped_group(conn, group_id, fn ->
      case SalixMeet.Runtime.status_for_group(tenant_id(conn), group_id) do
        {:ok, meeting_agent} -> send_json(conn, 200, %{"meeting_agent" => meeting_agent})
        {:error, :not_found} -> send_json(conn, 404, %{error: "meeting agent not found"})
        {:error, {:invalid_meeting_agent, reason}} -> send_meeting_agent_conflict(conn, reason)
        {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
      end
    end)
  end

  defp serve_meeting_runtime_event(conn, group_id) do
    case conn.body_params do
      %{"event" => event} when is_map(event) ->
        token = runtime_event_token(conn, event)

        with {:ok, tenant_id, event} <- authorize_meeting_runtime_event(group_id, event, token),
             {:ok, result} <-
               SalixMeet.Runtime.deliver_event(tenant_id, group_id, event) do
          send_json(conn, 202, result)
        else
          {:error, :missing_meeting_id} ->
            send_json(conn, 400, %{error: "meeting_id is required"})

          {:error, :unauthorized} ->
            send_json(conn, 401, %{error: "unauthorized"})

          {:error, :not_found} ->
            send_json(conn, 404, %{error: "agent group not found"})

          {:error, {:invalid_meeting_agent, reason}} ->
            send_meeting_agent_conflict(conn, reason)

          {:error, reason} ->
            send_json(conn, 500, %{error: inspect(reason)})
        end

      _ ->
        send_json(conn, 400, %{error: "event is required"})
    end
  end

  defp authorize_meeting_runtime_event(group_id, event, token) do
    event = stringify_keys(event)
    meeting_id = trim(event["meeting_id"])

    if meeting_id == "" do
      {:error, :missing_meeting_id}
    else
      with {:ok, %{"state" => state}, _etag} <- SalixMeet.Store.get(meeting_id),
           state <- stringify_keys(state || %{}),
           true <- state["group_id"] == group_id,
           :ok <- verify_runtime_token(token, state["runtime_token"]) do
        {:ok, state["tenant_id"], Map.delete(event, "runtime_token")}
      else
        false -> {:error, :not_found}
        {:error, :not_found} -> {:error, :not_found}
        {:error, :unauthorized} = err -> err
        {:error, _} = err -> err
        _ -> {:error, :unauthorized}
      end
    end
  end

  defp verify_runtime_token(token, expected) do
    token = trim(token)
    expected = trim(expected)

    cond do
      token == "" or expected == "" -> {:error, :unauthorized}
      byte_size(token) != byte_size(expected) -> {:error, :unauthorized}
      Plug.Crypto.secure_compare(token, expected) -> :ok
      true -> {:error, :unauthorized}
    end
  end

  defp runtime_event_token(conn, event) do
    first_nonblank([
      event["runtime_token"],
      conn.body_params["runtime_token"],
      header(conn, "x-salix-meeting-runtime-token"),
      bearer_token(conn)
    ])
  end

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      [token | _] -> token
      _ -> ""
    end
  end

  defp header(conn, name) do
    conn
    |> Plug.Conn.get_req_header(name)
    |> List.first("")
    |> trim()
  end

  defp request_idempotency_key(conn) do
    first_nonblank([
      header(conn, "idempotency-key"),
      header(conn, "x-idempotency-key")
    ])
  end

  defp first_nonblank(values) do
    values
    |> List.wrap()
    |> Enum.map(&trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp send_meeting_agent_conflict(conn, reason) do
    send_json(conn, 409, %{
      error: "invalid meeting agent",
      reason: Atom.to_string(reason)
    })
  end

  defp serve_capability_request_list(conn, group_id) do
    case CapabilityRequests.list_group(group_id, tenant_id(conn),
           status: conn.query_params["status"],
           limit: conn.query_params["limit"]
         ) do
      {:ok, requests} -> send_json(conn, 200, %{"data" => requests})
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "agent group not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp serve_capability_request_events(conn, group_id) do
    SalixWeb.CapabilityRequestSSE.serve(conn, group_id, tenant_id(conn))
  end

  defp serve_share_location_capability_request(conn, group_id, request_id) do
    case CapabilityRequests.share_location(
           group_id,
           request_id,
           conn.body_params,
           tenant_id(conn)
         ) do
      {:ok, request} -> send_json(conn, 200, request)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "capability request not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp serve_confirm_oauth_authorization_capability_request(conn, group_id, request_id) do
    case CapabilityRequests.confirm_oauth_authorization(
           group_id,
           request_id,
           tenant_id(conn)
         ) do
      {:ok, request} -> send_json(conn, 200, request)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "capability request not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp serve_decide_host_access_capability_request(conn, group_id, request_id) do
    case CapabilityRequests.decide_host_access(
           group_id,
           request_id,
           conn.body_params,
           tenant_id(conn)
         ) do
      {:ok, request} -> send_json(conn, 200, request)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "capability request not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp serve_decide_computer_use_start_capability_request(conn, group_id, request_id) do
    case CapabilityRequests.decide_computer_use_start(
           group_id,
           request_id,
           conn.body_params,
           tenant_id(conn)
         ) do
      {:ok, request} -> send_json(conn, 200, request)
      {:error, {:bad_request, message}} -> send_json(conn, 400, %{error: message})
      {:error, :not_found} -> send_json(conn, 404, %{error: "capability request not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp send_tool_content(conn, content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, decoded} -> send_json(conn, 200, decoded)
      {:error, _} -> send_json(conn, 200, %{"result" => content})
    end
  end

  defp send_tool_content(conn, content), do: send_json(conn, 200, %{"result" => content})

  # Session actors must return immediately after admitting a user-owned tool.
  # This historical HTTP command keeps a bounded quick-result compatibility
  # window in the request process: subscribe before admission so a fast terminal
  # cannot be missed, then hydrate only the exact tool-call identity. At the
  # request-local deadline, return that durable running handle instead of putting
  # the dependency back in an agent mailbox.
  defp execute_session_tool_http(agent, session_id, tool_name, attrs, tenant_id) do
    agent_id = agent["agent_id"] || agent[:agent_id]
    topic = SalixWeb.PubSubNotifier.topic(agent_id)

    with :ok <- Phoenix.PubSub.subscribe(SalixWeb.PubSub, topic) do
      try do
        case SalixAgent.Runtime.execute_session_tool(
               agent,
               session_id,
               tool_name,
               attrs,
               tenant_id
             ) do
          {:ok, result} -> await_session_tool_http(agent_id, session_id, result)
          other -> other
        end
      after
        Phoenix.PubSub.unsubscribe(SalixWeb.PubSub, topic)
      end
    end
  end

  defp await_session_tool_http(agent_id, session_id, result) do
    if session_tool_running?(result) do
      if session_tool_callback_handoff?(result) do
        {:ok, session_tool_http_result(result)}
      else
        case session_tool_call_id(result) do
          tool_call_id when is_binary(tool_call_id) and tool_call_id != "" ->
            deadline =
              System.monotonic_time(:millisecond) + session_tool_http_wait_timeout_ms()

            await_session_tool_terminal(agent_id, session_id, tool_call_id, deadline)

          _missing_id ->
            {:error, {:bad_request, "running session tool result has no tool_call_id"}}
        end
      end
    else
      {:ok, result}
    end
  end

  defp await_session_tool_terminal(agent_id, session_id, tool_call_id, deadline) do
    case SalixAgent.Runtime.get_async_tool_call(agent_id, session_id, tool_call_id) do
      {:ok, record} ->
        case session_tool_terminal_result(record) do
          {:ok, result} ->
            {:ok, result}

          :external_callback ->
            session_tool_setup_result(agent_id, session_id, tool_call_id)

          :running ->
            wait_for_session_tool_update(agent_id, session_id, tool_call_id, deadline)
        end

      {:error, _} = error ->
        error
    end
  end

  defp wait_for_session_tool_update(agent_id, session_id, tool_call_id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      final_session_tool_read(agent_id, session_id, tool_call_id)
    else
      receive do
        {:salix_agent_event, ^agent_id, {:session_updated, ^session_id}} ->
          await_session_tool_terminal(agent_id, session_id, tool_call_id, deadline)
      after
        remaining -> final_session_tool_read(agent_id, session_id, tool_call_id)
      end
    end
  end

  defp final_session_tool_read(agent_id, session_id, tool_call_id) do
    case SalixAgent.Runtime.get_async_tool_call(agent_id, session_id, tool_call_id) do
      {:ok, record} ->
        case session_tool_terminal_result(record) do
          {:ok, result} -> {:ok, result}
          :external_callback -> session_tool_setup_result(agent_id, session_id, tool_call_id)
          :running -> {:ok, session_tool_running_result(record, tool_call_id)}
        end

      {:error, _} = error ->
        error
    end
  end

  defp session_tool_terminal_result(record) do
    case map_value(record, :status) do
      status when status in ["completed", :completed] ->
        {:ok, session_tool_stored_result(record, false)}

      status when status in ["failed", :failed] ->
        {:ok, session_tool_stored_result(record, true)}

      status when status in ["cancelled", :cancelled] ->
        reason = map_value(record, :cancel_reason) || "session tool was cancelled"
        {:ok, %{error: true, content: to_string(reason), status: "cancelled"}}

      status when status in ["running", :running] ->
        if map_value(record, :completion_mode) in ["external_callback", :external_callback],
          do: :external_callback,
          else: :running

      _non_terminal ->
        :running
    end
  end

  defp session_tool_setup_result(agent_id, session_id, tool_call_id) do
    case SalixAgent.Runtime.get_async_tool_setup_result(agent_id, session_id, tool_call_id) do
      {:ok, result} -> {:ok, session_tool_http_result(result)}
      {:error, _} = error -> error
    end
  end

  defp session_tool_http_result(result) do
    %{
      error: map_value(result, :error) in [true, "true", 1],
      content: map_value(result, :content) || "",
      status: map_value(result, :status) || "completed"
    }
  end

  defp session_tool_stored_result(record, failed?) do
    stored = map_value(record, :result)
    stored = if is_map(stored), do: stored, else: %{}

    %{
      error: failed? or map_value(stored, :error) in [true, "true", 1],
      content:
        map_value(stored, :content) || map_value(record, :error_message) ||
          if(failed?, do: "session tool failed", else: ""),
      status: if(failed?, do: "error", else: "completed")
    }
  end

  defp session_tool_running_result(record, tool_call_id) do
    content =
      %{
        "status" => "running",
        "tool_call_id" => tool_call_id,
        "message" =>
          "tool is still running asynchronously; poll or cancel it with the exact tool_call_id"
      }
      |> put_if("tool_name", map_value(record, :tool_name))
      |> put_if("auto_wait_seconds", map_value(record, :auto_wait_seconds))
      |> Jason.encode!()

    %{error: false, content: content, status: "running"}
  end

  defp session_tool_running?(result),
    do: map_value(result, :status) in ["async_running", :async_running, "running", :running]

  defp session_tool_callback_handoff?(result) do
    result
    |> map_value(:events)
    |> List.wrap()
    |> Enum.any?(fn event ->
      map_value(event, :type) == "async_tool_call_started" and
        map_value(event, :completion_mode) in ["external_callback", :external_callback]
    end)
  end

  defp session_tool_call_id(result) do
    map_value(result, :id) || map_value(result, :tool_call_id) ||
      with content when is_binary(content) <- map_value(result, :content),
           {:ok, decoded} <- Jason.decode(content),
           do: decoded["tool_call_id"]
  end

  defp session_tool_http_wait_timeout_ms do
    case Application.get_env(:salix_web, :session_tool_http_wait_timeout_ms, 3_000) do
      value when is_integer(value) and value > 0 -> min(value, 10_000)
      _invalid -> 3_000
    end
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp map_value(_map, _key), do: nil

  defp send_oauth_callback_page(conn, status, service, error_message \\ nil) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, SalixWeb.OAuthCallbackPage.render(service, error_message))
  end

  defp slack_url_verification(%{"type" => "url_verification"} = envelope) do
    case Map.fetch(envelope, "challenge") do
      {:ok, challenge} when is_binary(challenge) -> {:ok, challenge}
      _missing_or_invalid -> {:error, :invalid_envelope}
    end
  end

  defp slack_url_verification(envelope) when is_map(envelope), do: :not_url_verification
  defp slack_url_verification(_envelope), do: {:error, :invalid_envelope}

  defp feishu_event_app_id(envelope) when is_map(envelope) do
    with {:ok, header_app_id} <- nested_optional_trimmed_binary(envelope, "header", "app_id"),
         {:ok, event_app_id} <- nested_optional_trimmed_binary(envelope, "event", "app_id"),
         {:ok, top_level_app_id} <- optional_trimmed_binary_field(envelope, "app_id") do
      {:ok, Enum.find([header_app_id, event_app_id, top_level_app_id], &is_binary/1)}
    end
  end

  defp feishu_event_app_id(_envelope), do: {:error, :invalid_envelope}

  defp nested_optional_trimmed_binary(envelope, container_key, field_key) do
    case Map.fetch(envelope, container_key) do
      :error ->
        {:ok, nil}

      {:ok, container} when is_map(container) ->
        optional_trimmed_binary_field(container, field_key)

      {:ok, _invalid_container} ->
        {:error, :invalid_envelope}
    end
  end

  defp optional_trimmed_binary_field(map, key) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, value} -> optional_trimmed_binary(value)
    end
  end

  defp optional_trimmed_binary(nil), do: {:ok, nil}

  defp optional_trimmed_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp optional_trimmed_binary(_value), do: {:error, :invalid_envelope}

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp truthy?(value), do: trim(value) in ["1", "true", "yes", "on"]

  defp cloud_vm_ops_page(conn, read) do
    conn = fetch_query_params(conn)

    with {limit, ""} <- Integer.parse(conn.query_params["limit"] || "50"),
         true <- limit in 1..100,
         %{data: _, next_cursor: _} = page <-
           read.(limit: limit, cursor: conn.query_params["cursor"]) do
      send_json(conn, 200, page)
    else
      {:error, :invalid_page} -> send_json(conn, 400, %{error: "invalid_page"})
      {:error, _} -> send_json(conn, 503, %{error: "compute_unavailable"})
      _ -> send_json(conn, 400, %{error: "invalid_page"})
    end
  end

  defp read_limited_body(conn, acc \\ "", remaining \\ 10 * 1024 * 1024) do
    case Plug.Conn.read_body(conn, length: min(remaining, 1_000_000), read_length: 1_000_000) do
      {:ok, chunk, conn} when byte_size(chunk) <= remaining ->
        {:ok, acc <> chunk, conn}

      {:more, chunk, conn} when byte_size(chunk) < remaining ->
        read_limited_body(conn, acc <> chunk, remaining - byte_size(chunk))

      {:more, _chunk, conn} ->
        {:error, :too_large, conn}

      {:ok, _chunk, conn} ->
        {:error, :too_large, conn}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp serve_agent_file(conn, agent_id, path) do
    case Workspace.open(agent_id, path) do
      {:file, _file, stream, size} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> stream_resp(200, stream, size)

      {:ok, entries} ->
        send_json(conn, 200, entries)

      {:error, :not_found} ->
        send_json(conn, 404, %{error: "file not found"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  defp stream_resp(conn, status, stream, size) do
    conn
    |> put_resp_header("content-length", Integer.to_string(size))
    |> send_chunked(status)
    |> stream_chunks(stream)
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn piece, conn ->
      case Plug.Conn.chunk(conn, IO.iodata_to_binary(piece)) do
        {:ok, conn} -> {:cont, conn}
        {:error, _reason} -> {:halt, conn}
      end
    end)
  end

  defp send_runtime_auth_error(conn, :not_found),
    do: send_json(conn, 404, %{error: "runtime_auth_not_found"})

  defp send_runtime_auth_error(conn, reason)
       when reason in [
              :connector_disconnected,
              :runtime_auth_unsupported,
              :runtime_auth_conflict,
              :runtime_auth_target_changed
            ],
       do: send_json(conn, 409, %{error: Atom.to_string(reason)})

  defp send_runtime_auth_error(conn, reason)
       when reason in [:invalid_runtime_auth_flow, :invalid_runtime_auth_attempt_id],
       do: send_json(conn, 400, %{error: Atom.to_string(reason)})

  defp send_runtime_auth_error(conn, :runtime_auth_timeout),
    do: send_json(conn, 504, %{error: "runtime_auth_timeout"})

  defp send_runtime_auth_error(conn, :unavailable),
    do: send_json(conn, 503, %{error: "unavailable"})

  defp send_runtime_auth_error(conn, _reason),
    do: send_json(conn, 502, %{error: "runtime_auth_failed"})

  defp runtime_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _ -> {:error, :invalid_runtime_credential}
    end
  end

  # Run before authentication so even rejected runtime-auth requests cannot be
  # cached by an intermediary. Successful handlers repeat the header locally
  # to keep the endpoint contract obvious at the response boundary.
  defp put_runtime_auth_no_store(conn, _opts) do
    if conn.request_path in @install_operation_paths do
      put_resp_header(conn, "cache-control", "no-store")
    else
      put_runtime_no_store_by_path(conn)
    end
  end

  defp put_runtime_no_store_by_path(conn) do
    case conn.path_info do
      ["v1", "runtime", "groups", _group_id, "cloud-vm", "runtimes" | _] ->
        put_resp_header(conn, "cache-control", "no-store")

      [
        "v1",
        "runtime",
        "groups",
        _group_id,
        "environments",
        _device_id,
        "runtimes",
        _device_runtime_id,
        auth_path
        | _rest
      ]
      when auth_path in ["auth", "managed-auth"] ->
        put_resp_header(conn, "cache-control", "no-store")

      _other ->
        conn
    end
  end

  defp exact_keys?(value, keys) when is_map(value),
    do: value |> Map.keys() |> Enum.sort() == Enum.sort(keys)

  defp decode_install_operation_digest(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} when byte_size(decoded) == 32 -> {:ok, decoded}
      _ -> {:error, :invalid_request}
    end
  end

  defp decode_install_operation_digest(_value), do: {:error, :invalid_request}

  defp exchange_install_operation(conn, params) do
    with %{
           "version" => 2,
           "operation_id" => operation_id,
           "device_id" => device_id,
           "root_public_key" => root_public_key,
           "root_key_revision" => root_key_revision
         } <- params,
         true <-
           exact_keys?(params, [
             "version",
             "operation_id",
             "device_id",
             "root_public_key",
             "root_key_revision"
           ]),
         true <- is_binary(operation_id),
         true <- is_binary(root_public_key),
         {:ok, root_public_key} <- Base.decode64(root_public_key),
         {:ok, result} <-
           SalixStore.AgentVMMInstallations.exchange(
             operation_id,
             conn.assigns.install_operation_secret,
             %{
               device_id: device_id,
               root_public_key: root_public_key,
               root_key_revision: root_key_revision
             },
             &SalixStore.AgentVMMInstallMaterial.issue/2
           ) do
      send_install_operation_material(conn, result)
    else
      {:error, reason} -> send_install_operation_error(conn, reason)
      _ -> send_install_operation_error(conn, :invalid_request)
    end
  end

  defp send_install_operation_material(conn, result) do
    response =
      result.material
      |> Map.put(
        :host_identity_digest,
        Base.url_encode64(result.host_identity_digest, padding: false)
      )

    send_json(conn, 200, response)
  end

  defp send_install_operation_error(conn, reason)
       when reason in [:invalid_ticket, :not_found],
       do: send_json(conn, 401, %{error: "install_operation_rejected"})

  defp send_install_operation_error(conn, reason)
       when reason in [:ticket_expired, :ticket_revoked, :handoff_expired],
       do: send_json(conn, 410, %{error: "install_operation_closed"})

  defp send_install_operation_error(conn, reason)
       when reason in [
              :host_identity_mismatch,
              :handoff_complete,
              :exchange_not_committed
            ],
       do: send_json(conn, 409, %{error: "install_operation_conflict"})

  defp send_install_operation_error(conn, reason)
       when reason in [
              :install_material_unavailable,
              :install_material_too_large,
              :recovery_material_unavailable,
              :recovery_material_invalid,
              :unavailable
            ],
       do: send_json(conn, 503, %{error: "install_material_unavailable"})

  defp send_install_operation_error(conn, _reason),
    do: send_json(conn, 400, %{error: "invalid_install_request"})

  # This endpoint is available only to the authenticated VMM gateway. Keep the
  # vocabulary finite so operators can distinguish a bad one-time capability
  # from a broken managed-trust issuer without returning database or exception
  # text across the control boundary.
  defp managed_enrollment_rejection_reason(reason)
       when reason in [
              :registration_not_found,
              :invalid_enrollment,
              :device_identity_mismatch,
              :managed_anchor_unavailable,
              :managed_trust_signer_unavailable,
              :managed_trust_unavailable,
              :anchor_inactive,
              :authority_mismatch,
              :invalid_expiry,
              :signer_unavailable,
              :already_exists
            ],
       do: Atom.to_string(reason)

  defp managed_enrollment_rejection_reason(_reason), do: "control_unavailable"

  defp message_json(m) do
    %{
      id: m[:id] || m["id"],
      role: m[:role] || m["role"],
      content: m[:content] || m["content"],
      tool_call_id: m[:tool_call_id] || m["tool_call_id"],
      tool_calls: m[:tool_calls] || m["tool_calls"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp put_if(map, _k, nil), do: map
  defp put_if(map, k, v), do: Map.put(map, k, v)

  defp maybe_opt(opts, _k, nil), do: opts
  defp maybe_opt(opts, k, v), do: Keyword.put(opts, k, v)
end
