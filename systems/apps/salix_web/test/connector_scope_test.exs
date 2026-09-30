defmodule SalixWeb.ConnectorScopeTest do
  @moduledoc """
  The `local_file_read` connector credential scope is server-authoritative:
  it bounds what the socket will route, what the control plane projects, how
  long the credential lives, and which stable device it may re-attach to.
  """
  use ExUnit.Case, async: false

  alias SalixEnv.{ConnectorTokens, Control, Registry}
  alias SalixStore.{Keys, S3}

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Scope test"})
    tenant_id = tenant["tenant_id"]
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Scope WS"}, tenant_id)
    {:ok, tenant_id: tenant_id, group_id: group["group_id"]}
  end

  defp rpc_frame(id, method, params) do
    %{"id" => id, "type" => "request", "method" => method, "params" => params}
  end

  test "initial registration deadline does not expire an enrolled credential", ctx do
    {:ok, enrolled} =
      ConnectorTokens.create_group_connector_token(ctx.group_id, ctx.tenant_id, %{
        "registration_expires_in_seconds" => 60
      })

    {:ok, _, record} = ConnectorTokens.validate_connector_token(enrolled["token"])
    assert :ok = ConnectorTokens.admit_registration(record["token_hash"])
    key = Keys.ctl_connector_token(record["token_hash"])
    {:ok, %{body: body}} = S3.get(key)

    stored =
      Jason.decode!(body) |> Map.put("registration_expires_at", System.system_time(:second) - 1)

    {:ok, _} = S3.put(key, Jason.encode!(stored))
    assert {:ok, _, _} = ConnectorTokens.validate_connector_token(enrolled["token"])
    assert :ok = ConnectorTokens.admit_registration(record["token_hash"])

    assert :ok =
             ConnectorTokens.revoke_group_connector_token(
               ctx.group_id,
               ctx.tenant_id,
               enrolled["token"]
             )

    assert {:error, _} = ConnectorTokens.admit_registration(record["token_hash"])
  end

  test "expired or revoked credentials cannot make their first registration", ctx do
    for action <- [:expire, :revoke] do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(ctx.group_id, ctx.tenant_id, %{
          "registration_expires_in_seconds" => 60
        })

      {:ok, _, record} = ConnectorTokens.validate_connector_token(minted["token"])

      case action do
        :expire ->
          key = Keys.ctl_connector_token(record["token_hash"])

          {:ok, _} =
            S3.put(
              key,
              Jason.encode!(
                Map.put(record, "registration_expires_at", System.system_time(:second) - 1)
              )
            )

        :revoke ->
          :ok =
            ConnectorTokens.revoke_group_connector_token(
              ctx.group_id,
              ctx.tenant_id,
              minted["token"]
            )
      end

      assert {:error, _} = ConnectorTokens.validate_connector_token(minted["token"])
      assert {:error, :unauthorized} = ConnectorTokens.admit_registration(record["token_hash"])
    end
  end

  describe "socket routing" do
    test "a scoped socket refuses exec-class rpc, read_stream, and write_stream" do
      state = %SalixWeb.ConnectorSocket.State{scope: "local_file_read"}
      ref = make_ref()

      assert {:ok, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_rpc, ref, self(), rpc_frame("rpc-exec", "exec", %{"command" => "id"})},
                 state
               )

      assert_receive {:env_rpc_reply, ^ref, {:error, :connector_scope_forbidden}}

      read_ref_stream = make_ref()

      assert {:ok, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_read_stream, read_ref_stream, self(),
                  rpc_frame("stream-read", "read_stream", %{"path" => "/etc/hosts"})},
                 state
               )

      assert_receive {:env_read_stream_reply, ^read_ref_stream,
                      {:error, :connector_scope_forbidden}}

      write_ref = make_ref()

      assert {:ok, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_write_stream, :begin, write_ref, self(),
                  rpc_frame("stream-write", "write_stream", %{"path" => "/tmp/x"})},
                 state
               )

      assert_receive {:env_write_stream_reply, ^write_ref, {:error, :connector_scope_forbidden}}
    end

    test "a generation-authorized scoped socket accepts the read_ref transport", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read"
        })

      {:ok, _transport, connected} =
        connect_scoped(tenant_id, group_id, minted,
          connection_generation: 1,
          transport_id: "transport-read-ref-authorized"
        )

      state = %SalixWeb.ConnectorSocket.State{
        scope: "local_file_read",
        tenant_id: tenant_id,
        group_id: group_id,
        device_id: minted["device_id"],
        connector_id: minted["connector_id"],
        credential_generation: minted["credential_generation"],
        connector_run_id: connected["connector_run_id"],
        connection_generation: connected["connection_generation"]
      }

      ref = make_ref()

      assert {:push, {:text, _frame}, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_read_stream, ref, self(),
                  rpc_frame("stream-ref", "read_ref", %{"local_file_ref" => "lfi1_x"})},
                 state
               )

      assert_receive {:env_read_stream_reply, ^ref, {:ok, _stream, nil}}
    end

    test "a pre-generation scoped socket fails closed and must reconnect" do
      ref = make_ref()

      assert {:stop, {:shutdown, :connector_token_revoked}, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_read_stream, ref, self(),
                  rpc_frame("legacy-stream-ref", "read_ref", %{
                    "local_file_ref" => "lfi1_legacy"
                  })},
                 %SalixWeb.ConnectorSocket.State{scope: "local_file_read"}
               )

      assert_receive {:env_read_stream_reply, ^ref, {:error, :connector_credential_revoked}}
    end

    test "an unscoped socket keeps full routing" do
      state = %SalixWeb.ConnectorSocket.State{}
      ref = make_ref()

      assert {:push, {:text, _frame}, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_rpc, ref, self(), rpc_frame("rpc-read", "read", %{"path" => "/x"})},
                 state
               )
    end
  end

  describe "control projection" do
    test "a scoped run is never projected as a command environment", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_scope"}
        })

      device_id = minted["device_id"]

      assert {:ok, _transport, _device} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 minted,
                 %{
                   "capabilities" => %{
                     "local_file_import_v1" => true,
                     "local_file_index_version" => 2
                   }
                 },
                 connection_generation: 1,
                 transport_id: "transport-scope-test"
               )

      assert {:ok, environments} = Control.list_group_environments(group_id, tenant_id)
      scoped = Enum.find(environments, &(&1["device_id"] == device_id))
      assert scoped
      assert scoped["environments"] in [nil, []]
      assert scoped["environment_id"] in [nil, ""]
    end

    test "a full token projects only the connector-reported current-generation scope" do
      base = %{
        "connection_generation" => 9,
        "connector_run_id" => "run_comma_dynamic",
        "device_id" => "dev_comma_dynamic",
        "group_id" => "wsp_dynamic",
        "status" => "connected",
        "tenant_id" => "ten_dynamic"
      }

      restricted =
        Map.put(base, "meta", %{
          "capabilities" => %{"scope" => "local_file_read"},
          "connector_scope" => "local_file_read",
          "connector_scope_generation" => 9
        })
        |> Control.environment_json()

      assert [restricted_environment] = restricted["environments"]
      assert restricted["environment_id"] == restricted_environment["environment_id"]
      assert restricted_environment["status"] == "permission_required"
      assert restricted_environment["requires_permission"] == true
      assert restricted_environment["capabilities"]["exec"] == false
      assert restricted_environment["permission_message"] =~ "Allow operations"

      full =
        Map.put(base, "meta", %{
          "capabilities" => %{"persistent_processes" => true},
          "connector_scope" => "",
          "connector_scope_generation" => 9
        })
        |> Control.environment_json()

      assert [%{"environment_provider" => "connector"} = environment] =
               full["environments"]

      assert full["environment_id"] == environment["environment_id"]

      stale_full =
        Map.put(base, "meta", %{
          "capabilities" => %{"persistent_processes" => true},
          "connector_scope" => "",
          "connector_scope_generation" => 8
        })
        |> Control.environment_json()

      assert stale_full["environments"] in [nil, []]
      assert stale_full["environment_id"] in [nil, ""]
    end

    test "Registry publishes the explicit startup scope at the exact connection generation",
         %{tenant_id: tenant_id, group_id: group_id} do
      {:ok, credential} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "expires_in_seconds" => 2 * 60 * 60
        })

      meta = %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => credential["device_id"],
        "connector_id" => credential["connector_id"],
        "credential_generation" => credential["credential_generation"],
        "capabilities" => %{"persistent_processes" => true}
      }

      assert {:ok, _transport, connected} =
               Registry.connect(to_string(node()), meta,
                 connection_generation: 7,
                 connector_scope: "local_file_read",
                 credential_generation: credential["credential_generation"],
                 token_expires_at: credential["expires_at"],
                 transport_id: "transport-comma-startup-scope"
               )

      assert connected["connection_generation"] == 7
      assert connected["meta"]["connector_scope"] == "local_file_read"
      assert connected["meta"]["connector_scope_generation"] == 7
      assert connected["meta"]["capabilities"]["scope"] == "local_file_read"
      assert connected["meta"]["capabilities"]["persistent_processes"] == true

      restricted = Control.environment_json(connected)

      assert [%{"status" => "permission_required"} = environment] =
               restricted["environments"]

      assert restricted["environment_id"] == environment["environment_id"]
    end
  end

  describe "credential lifecycle" do
    test "a scoped mint is short-lived by default and clamped when asked for more", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, defaulted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read"
        })

      assert defaulted["scope"] == "local_file_read"
      now = System.system_time(:second)
      assert_in_delta defaulted["expires_at"], now + 2 * 60 * 60, 60

      {:ok, clamped} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "expires_in_seconds" => 30 * 24 * 60 * 60
        })

      assert_in_delta clamped["expires_at"], now + 24 * 60 * 60, 60

      assert {:error, {:bad_request, _reason}} =
               ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
                 "scope" => "computer_use"
               })
    end

    test "pre-generation scoped credentials fail closed until reminted", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      legacy_hash = "legacy_scoped_token_hash"
      device_id = SalixStore.Ids.new_device_id()

      assert {:ok, _} =
               S3.put(
                 Keys.ctl_connector_token(legacy_hash),
                 Jason.encode!(%{
                   "token_hash" => legacy_hash,
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => "conn_legacy_scoped",
                   "scope" => "local_file_read"
                 }),
                 if_none_match: "*"
               )

      refute ConnectorTokens.credential_active?(legacy_hash)

      assert {:error, :connector_credential_revoked} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => "conn_legacy_scoped",
                   "scope" => "local_file_read"
                 },
                 connection_generation: 1,
                 transport_id: "transport-legacy-scoped"
               )
    end

    test "a production-format legacy unscoped token is durably fenced and its live RPC owner is stopped",
         %{
           tenant_id: tenant_id,
           group_id: group_id
         } do
      raw_token = "salix_conn_legacy_unscoped_production_format"
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      device_id = SalixStore.Ids.new_device_id()
      connector_id = "conn_legacy_unscoped"

      legacy_record = %{
        "token_hash" => token_hash,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => device_id,
        "connector_id" => connector_id,
        "name" => "Legacy unrestricted connector",
        "alias" => "Legacy unrestricted connector",
        "meta" => %{"owner_user_id" => "usr_legacy"},
        "created_at" => System.system_time(:second),
        "expires_at" => nil
      }

      assert {:ok, _} =
               S3.put(
                 Keys.ctl_connector_token(token_hash),
                 Jason.encode!(legacy_record),
                 if_none_match: "*"
               )

      assert {:ok, ^tenant_id, ^legacy_record} =
               ConnectorTokens.validate_connector_token(raw_token)

      assert {:ok, transport_id, connected} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => connector_id,
                   "owner_user_id" => "usr_legacy"
                 },
                 connection_generation: 1,
                 transport_id: "transport-legacy-unrestricted"
               )

      owner = start_rpc_owner(transport_id)
      owner_monitor = Process.monitor(owner)

      assert {:ok, %{"method" => "exec"}} =
               SalixEnv.Connector.Live.request(
                 connected["connector_run_id"],
                 "exec",
                 %{"command" => "printf legacy"}
               )

      # This is the production DELETE backend invoked by both Comma and Salix
      # control surfaces. Completion must mean the unrestricted owner stopped,
      # not merely that the legacy token object disappeared.
      assert :ok =
               ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, raw_token)

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 1_000

      assert {:error, :disconnected} =
               SalixEnv.Connector.Live.request(
                 connected["connector_run_id"],
                 "exec",
                 %{"command" => "printf must-not-run"}
               )

      assert {:ok, fenced} = Registry.get_device(tenant_id, group_id, device_id)
      assert fenced["status"] == "disconnected"
      assert connector_id in fenced["revoked_legacy_connector_ids"]
      assert {:error, :not_found} = S3.get(Keys.ctl_connector_token(token_hash))

      assert {:error, :connector_credential_revoked} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => connector_id
                 },
                 connection_generation: 2,
                 transport_id: "transport-legacy-replay"
               )
    end

    test "a generation successor durably carries an unreachable legacy predecessor into DELETE",
         %{
           tenant_id: tenant_id,
           group_id: group_id
         } do
      raw_token = "salix_conn_legacy_migration_partitioned"
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      device_id = SalixStore.Ids.new_device_id()
      connector_id = "conn_legacy_migration_partitioned"

      legacy_record = %{
        "token_hash" => token_hash,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => device_id,
        "connector_id" => connector_id,
        "name" => "Legacy migration predecessor",
        "alias" => "Legacy migration predecessor",
        "meta" => %{"owner_user_id" => "usr_legacy"},
        "created_at" => System.system_time(:second),
        "expires_at" => nil
      }

      assert {:ok, _} =
               S3.put(
                 Keys.ctl_connector_token(token_hash),
                 Jason.encode!(legacy_record),
                 if_none_match: "*"
               )

      assert {:ok, _transport, legacy_run} =
               Registry.connect(
                 "partitioned-legacy-owner@unreachable",
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => connector_id,
                   "owner_user_id" => "usr_legacy"
                 },
                 connection_generation: 1,
                 transport_id: "transport-legacy-migration-partitioned"
               )

      assert {:ok, successor_credential} =
               ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
                 "scope" => "local_file_read",
                 "stable_device_id" => device_id,
                 "meta" => %{"owner_user_id" => "usr_legacy"}
               })

      assert {:ok, _transport, successor} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 successor_credential,
                 connection_generation: 2,
                 transport_id: "transport-legacy-migration-successor"
               )

      assert {:ok, migrated} = Registry.get_device(tenant_id, group_id, device_id)
      assert migrated["connector_run_id"] == successor["connector_run_id"]

      pending_key = "legacy:" <> connector_id
      assert [legacy_target] = migrated["pending_connector_revocations"][pending_key]
      assert legacy_target["connector_id"] == connector_id
      assert legacy_target["credential_generation"] == nil
      assert legacy_target["connector_run_id"] == legacy_run["connector_run_id"]
      assert legacy_target["transport_id"] == "transport-legacy-migration-partitioned"
      assert legacy_target["node"] == "partitioned-legacy-owner@unreachable"

      # The failure names the exact target so an operator with out-of-band
      # evidence (the node's Pod is gone) can confirm that one owner stop
      # explicitly instead of guessing which of the accumulated targets blocked.
      legacy_run_id = legacy_run["connector_run_id"]

      assert {:error,
              {:owner_stop_unconfirmed,
               {:owner_node_unavailable,
                %{
                  "node" => "partitioned-legacy-owner@unreachable",
                  "connector_run_id" => ^legacy_run_id,
                  "transport_id" => "transport-legacy-migration-partitioned"
                }}}} =
               ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, raw_token)

      # DELETE completion cannot drop the operation handle while an exact
      # unrestricted predecessor stop remains unconfirmed.
      assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(token_hash))
      assert {:ok, retryable} = Registry.get_device(tenant_id, group_id, device_id)
      assert connector_id in retryable["revoked_legacy_connector_ids"]
      assert [^legacy_target] = retryable["pending_connector_revocations"][pending_key]
      assert retryable["connector_run_id"] == successor["connector_run_id"]
    end

    test "retirement fails closed on an unreachable current owner, then completes once attested dead",
         %{tenant_id: tenant_id, group_id: group_id} do
      raw_token = "salix_conn_legacy_retire_unreachable"
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      device_id = SalixStore.Ids.new_device_id()
      connector_id = "conn_legacy_retire_unreachable"
      put_legacy_token_record!(token_hash, tenant_id, group_id, device_id, connector_id)

      assert {:ok, _transport, legacy_run} =
               Registry.connect(
                 "dead-legacy-owner@gone",
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => connector_id,
                   "owner_user_id" => "usr_legacy"
                 },
                 connection_generation: 1,
                 transport_id: "transport-legacy-retire-unreachable"
               )

      legacy_run_id = legacy_run["connector_run_id"]

      # No attestation: the revocation fences the device, cannot confirm the
      # owner on the missing node, and the retirement halts there.
      assert {:error,
              {:owner_stop_unconfirmed,
               {:owner_node_unavailable,
                %{"node" => "dead-legacy-owner@gone", "connector_run_id" => ^legacy_run_id}}}} =
               ConnectorTokens.retire_legacy_connector(token_hash, device_id, group_id, tenant_id)

      assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(token_hash))
      assert {:ok, fenced} = Registry.get_device(tenant_id, group_id, device_id)
      assert fenced["status"] == "disconnected"
      assert connector_id in fenced["revoked_legacy_connector_ids"]

      assert [%{"connector_run_id" => ^legacy_run_id}] =
               Registry.pending_legacy_stop_targets(fenced, connector_id)

      # A wrong attestation is still no attestation.
      assert {:error, {:owner_node_not_attested_dead, "dead-legacy-owner@gone"}} =
               ConnectorTokens.retire_legacy_connector(token_hash, device_id, group_id, tenant_id,
                 dead_nodes: ["some-other-node@gone"]
               )

      assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(token_hash))
      assert {:ok, _still_fenced} = Registry.get_device(tenant_id, group_id, device_id)

      # The operator attests the node dead: the target is confirmed, the
      # revocation completes, the token record is proven gone, the device goes.
      assert :ok =
               ConnectorTokens.retire_legacy_connector(token_hash, device_id, group_id, tenant_id,
                 dead_nodes: ["dead-legacy-owner@gone"]
               )

      assert {:error, :not_found} = S3.get(Keys.ctl_connector_token(token_hash))
      assert {:error, :not_found} = Registry.get_device(tenant_id, group_id, device_id)

      assert {:ok, :already_retired} =
               ConnectorTokens.retire_legacy_connector(token_hash, device_id, group_id, tenant_id,
                 dead_nodes: ["dead-legacy-owner@gone"]
               )
    end

    test "retirement halts before touching a device whose unreachable predecessor is not attested dead",
         %{tenant_id: tenant_id, group_id: group_id} do
      raw_token = "salix_conn_legacy_retire_successor"
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      device_id = SalixStore.Ids.new_device_id()
      connector_id = "conn_legacy_retire_successor"
      put_legacy_token_record!(token_hash, tenant_id, group_id, device_id, connector_id)

      assert {:ok, _transport, legacy_run} =
               Registry.connect(
                 "partitioned-legacy-owner@unreachable",
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => connector_id,
                   "owner_user_id" => "usr_legacy"
                 },
                 connection_generation: 1,
                 transport_id: "transport-legacy-retire-successor-predecessor"
               )

      assert {:ok, successor_credential} =
               ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
                 "scope" => "local_file_read",
                 "stable_device_id" => device_id,
                 "meta" => %{"owner_user_id" => "usr_legacy"}
               })

      assert {:ok, _transport, successor} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 successor_credential,
                 connection_generation: 2,
                 transport_id: "transport-legacy-retire-successor"
               )

      assert {:ok, before} = Registry.get_device(tenant_id, group_id, device_id)
      assert [pending_target] = Registry.pending_legacy_stop_targets(before, connector_id)
      assert pending_target["connector_run_id"] == legacy_run["connector_run_id"]

      assert {:error, {:owner_node_not_attested_dead, "partitioned-legacy-owner@unreachable"}} =
               ConnectorTokens.retire_legacy_connector(token_hash, device_id, group_id, tenant_id)

      # Halted before the revocation: token, device, pending target and the
      # successor's current run are all untouched.
      assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(token_hash))
      assert {:ok, untouched} = Registry.get_device(tenant_id, group_id, device_id)
      assert untouched["connector_run_id"] == successor["connector_run_id"]
      assert [^pending_target] = Registry.pending_legacy_stop_targets(untouched, connector_id)
      refute connector_id in List.wrap(untouched["revoked_legacy_connector_ids"])
    end

    test "retirement refuses an unknown hash, a foreign scope, and a generation credential",
         %{tenant_id: tenant_id, group_id: group_id} do
      raw_token = "salix_conn_legacy_retire_preflight"
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      device_id = SalixStore.Ids.new_device_id()
      connector_id = "conn_legacy_retire_preflight"
      put_legacy_token_record!(token_hash, tenant_id, group_id, device_id, connector_id)

      assert {:ok, _transport, _run} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => connector_id,
                   "owner_user_id" => "usr_legacy"
                 },
                 connection_generation: 1,
                 transport_id: "transport-legacy-retire-preflight"
               )

      unknown_hash =
        :crypto.hash(:sha256, "salix_conn_never_minted") |> Base.encode16(case: :lower)

      assert {:error, :token_record_not_found} =
               ConnectorTokens.retire_legacy_connector(
                 unknown_hash,
                 device_id,
                 group_id,
                 tenant_id
               )

      assert {:error, :invalid_token_hash} =
               ConnectorTokens.retire_legacy_connector(
                 token_hash <> ".json",
                 device_id,
                 group_id,
                 tenant_id
               )

      assert {:error, :token_scope_mismatch} =
               ConnectorTokens.retire_legacy_connector(
                 token_hash,
                 SalixStore.Ids.new_device_id(),
                 group_id,
                 tenant_id
               )

      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:error, :not_a_legacy_credential} =
               ConnectorTokens.retire_legacy_connector(
                 minted["token_hash"],
                 minted["device_id"],
                 group_id,
                 tenant_id
               )

      # Every refusal happened before any write.
      assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(token_hash))

      assert {:ok, %{"status" => "connected"}} =
               Registry.get_device(tenant_id, group_id, device_id)

      assert {:ok, _minted_object} = S3.get(Keys.ctl_connector_token(minted["token_hash"]))
    end

    test "a generation successor confirms the exact local legacy predecessor stop",
         %{
           tenant_id: tenant_id,
           group_id: group_id
         } do
      raw_token = "salix_conn_legacy_migration_local"
      token_hash = :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
      device_id = SalixStore.Ids.new_device_id()
      connector_id = "conn_legacy_migration_local"

      legacy_record = %{
        "token_hash" => token_hash,
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "device_id" => device_id,
        "connector_id" => connector_id,
        "name" => "Local legacy migration predecessor",
        "alias" => "Local legacy migration predecessor",
        "meta" => %{"owner_user_id" => "usr_legacy"},
        "created_at" => System.system_time(:second),
        "expires_at" => nil
      }

      assert {:ok, _} =
               S3.put(
                 Keys.ctl_connector_token(token_hash),
                 Jason.encode!(legacy_record),
                 if_none_match: "*"
               )

      assert {:ok, legacy_transport, legacy_run} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => connector_id,
                   "owner_user_id" => "usr_legacy"
                 },
                 connection_generation: 1,
                 transport_id: "transport-legacy-migration-local"
               )

      owner = start_rpc_owner(legacy_transport)
      owner_monitor = Process.monitor(owner)

      assert {:ok, %{"method" => "process_start"}} =
               SalixEnv.Connector.Live.request(
                 legacy_run["connector_run_id"],
                 "process_start",
                 %{"command" => "printf legacy"}
               )

      assert {:ok, successor_credential} =
               ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
                 "scope" => "local_file_read",
                 "stable_device_id" => device_id,
                 "meta" => %{"owner_user_id" => "usr_legacy"}
               })

      assert {:ok, _transport, successor} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 successor_credential,
                 connection_generation: 2,
                 transport_id: "transport-legacy-migration-local-successor"
               )

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, _reason}, 1_000

      assert {:ok, migrated} = Registry.get_device(tenant_id, group_id, device_id)
      assert migrated["connector_run_id"] == successor["connector_run_id"]

      assert get_in(migrated, ["pending_connector_revocations", "legacy:" <> connector_id]) in [
               nil,
               []
             ]

      assert :ok =
               ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, raw_token)

      assert {:error, :not_found} = S3.get(Keys.ctl_connector_token(token_hash))

      assert {:error, :disconnected} =
               SalixEnv.Connector.Live.request(
                 legacy_run["connector_run_id"],
                 "process_start",
                 %{"command" => "printf must-not-run"}
               )
    end

    test "a failed token write rolls back its fresh device reservation", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      device_prefix = Keys.ctl_group_devices_prefix(tenant_id, group_id)

      mint =
        gated_task(fn ->
          ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
            "scope" => "local_file_read",
            "meta" => %{"owner_user_id" => "usr_owner"}
          })
        end)

      :ok =
        S3.Fake.set_fault_for(
          mint.pid,
          {:fail, 503, :put, {:prefix, Keys.ctl_connector_tokens_prefix()}}
        )

      # Even a write in the same object family cannot consume another caller's
      # fault. This is the cross-talk that made the full CI suite occasionally
      # mint successfully instead of exercising rollback.
      foreign_token_key = Keys.ctl_connector_token("foreign-fault-probe")
      assert {:ok, _} = S3.put(foreign_token_key, "{}", if_none_match: "*")
      assert :ok = S3.delete(foreign_token_key)

      start_gated_task(mint)
      assert {:error, {:http, 503}} = Task.await(mint)

      refute S3.Fake.dump()
             |> Map.keys()
             |> Enum.any?(&String.starts_with?(&1, device_prefix))
    end

    test "a failed rotation restores the exact previous device authority", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, first} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, connected} =
               connect_scoped(tenant_id, group_id, first,
                 connection_generation: 1,
                 transport_id: "transport-rotation-rollback"
               )

      assert {:ok, before_rotation} =
               Registry.get_device(tenant_id, group_id, first["device_id"])

      rotation =
        gated_task(fn ->
          ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
            "scope" => "local_file_read",
            "stable_device_id" => first["device_id"],
            "meta" => %{"owner_user_id" => "usr_owner"}
          })
        end)

      :ok =
        S3.Fake.set_fault_for(
          rotation.pid,
          {:fail, 503, :put, {:prefix, Keys.ctl_connector_tokens_prefix()}}
        )

      start_gated_task(rotation)
      assert {:error, {:http, 503}} = Task.await(rotation)

      assert {:ok, ^before_rotation} =
               Registry.get_device(tenant_id, group_id, first["device_id"])

      assert ConnectorTokens.credential_active?(first["token_hash"])

      assert {:ok, _transport, ^before_rotation} =
               Registry.get_by_connector_run_id(connected["connector_run_id"])
    end

    test "an ambiguous landed token write settles without rolling back authority", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      mint =
        gated_task(fn ->
          ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
            "scope" => "local_file_read",
            "meta" => %{"owner_user_id" => "usr_owner"}
          })
        end)

      :ok =
        S3.Fake.set_fault_for(
          mint.pid,
          {:ambiguous_after, :put, {:prefix, Keys.ctl_connector_tokens_prefix()}}
        )

      start_gated_task(mint)
      assert {:ok, minted} = Task.await(mint)
      assert {:ok, ^tenant_id, record} = ConnectorTokens.validate_connector_token(minted["token"])
      assert record["credential_generation"] == minted["credential_generation"]

      assert {:ok, device} = Registry.get_device(tenant_id, group_id, minted["device_id"])
      assert device["active_connector_id"] == minted["connector_id"]
      assert device["active_credential_generation"] == minted["credential_generation"]
    end

    test "stable device reuse requires the registry owner to match", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, first} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = first["device_id"]

      assert {:ok, _transport, _device} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 first,
                 connection_generation: 1,
                 transport_id: "transport-device-reuse"
               )

      {:ok, reused} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert reused["device_id"] == device_id

      assert {:error, :stable_device_unavailable} =
               ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
                 "scope" => "local_file_read",
                 "stable_device_id" => device_id,
                 "meta" => %{"owner_user_id" => "usr_other"}
               })

      assert {:error, :stable_device_unavailable} =
               ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
                 "scope" => "local_file_read",
                 "stable_device_id" => "dev_never_registered",
                 "meta" => %{"owner_user_id" => "usr_owner"}
               })
    end

    test "revocation invalidates the credential and disconnects its device", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      raw = minted["token"]
      device_id = minted["device_id"]
      assert {:ok, ^tenant_id, _record} = ConnectorTokens.validate_connector_token(raw)

      assert {:ok, _transport, device} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 minted,
                 connection_generation: 1,
                 transport_id: "transport-revoke-test"
               )

      assert device["status"] == "connected"

      assert :ok = ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, raw)
      assert {:error, :unauthorized} = ConnectorTokens.validate_connector_token(raw)
      assert {:ok, disconnected} = Registry.get_device(tenant_id, group_id, device_id)
      assert disconnected["status"] == "disconnected"

      # Revoking an unknown or foreign credential leaks nothing.
      assert :ok = ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, raw)
    end

    test "revoking a predecessor credential never severs the successor's run", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, first} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = first["device_id"]

      assert {:ok, _transport, _device} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 first,
                 connection_generation: 1,
                 transport_id: "transport-fence-old"
               )

      {:ok, second} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, replacement} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 second,
                 connection_generation: 2,
                 transport_id: "transport-fence-new"
               )

      assert replacement["status"] == "connected"

      # The delayed teardown of the predecessor entry revokes T1 after T2
      # already replaced the run. The successor's connection must survive.
      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 first["token"]
               )

      assert {:ok, current} = Registry.get_device(tenant_id, group_id, device_id)
      assert current["status"] == "connected"
      assert current["connector_id"] == second["connector_id"]
    end

    test "a successor CAS durably carries the predecessor stop obligation into revoke", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, first} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = first["device_id"]

      assert {:ok, _transport, old_run} =
               connect_scoped(
                 "partitioned-predecessor@unreachable",
                 tenant_id,
                 group_id,
                 first,
                 %{},
                 connection_generation: 1,
                 transport_id: "transport-cas-predecessor"
               )

      device_key = Keys.ctl_group_device(tenant_id, group_id, device_id)
      :ok = S3.Fake.set_fault({:pause, :put, device_key})

      revoke =
        Task.async(fn ->
          ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, first["token"])
        end)

      wait_until(&S3.Fake.paused?/0)

      {:ok, second} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, successor} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 second,
                 connection_generation: 2,
                 transport_id: "transport-cas-successor"
               )

      assert :ok = S3.Fake.release_pause()

      assert {:error, {:owner_stop_unconfirmed, _reason}} = Task.await(revoke)

      assert {:ok, current} = Registry.get_device(tenant_id, group_id, device_id)
      assert current["connector_run_id"] == successor["connector_run_id"]
      assert current["connector_id"] == second["connector_id"]

      pending =
        current["pending_connector_revocations"][
          Integer.to_string(first["credential_generation"])
        ]

      assert Enum.any?(pending, fn target ->
               target["connector_run_id"] == old_run["connector_run_id"] and
                 target["transport_id"] == "transport-cas-predecessor"
             end)

      assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(first["token_hash"]))
    end

    test "revocation of a foreign group's credential is refused", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, other} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read"
        })

      assert {:error, :not_found} =
               ConnectorTokens.revoke_group_connector_token(
                 "grp_other",
                 tenant_id,
                 other["token"]
               )
    end

    test "an admitted socket stops itself when its credential expires" do
      state = %SalixWeb.ConnectorSocket.State{scope: "local_file_read"}

      assert {:stop, {:shutdown, :connector_token_expired}, _state} =
               SalixWeb.ConnectorSocket.handle_info(:connector_token_expired, state)
    end

    test "an expired credential can still disconnect its exact physical run", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "expires_in_seconds" => 60
        })

      assert {:ok, _transport, connected} =
               connect_scoped(tenant_id, group_id, minted,
                 connection_generation: 1,
                 transport_id: "transport-expired-disconnect"
               )

      assert ConnectorTokens.credential_active?(minted["token_hash"])

      # Expire the persisted authority after admission, without racing the
      # one-second mint/connect window or sleeping on the wall clock.
      expired_at = System.system_time(:second) - 1

      for {key, field} <- [
            {Keys.ctl_connector_token(minted["token_hash"]), "expires_at"},
            {Keys.ctl_group_device(tenant_id, group_id, minted["device_id"]),
             "active_credential_expires_at"}
          ] do
        assert {:ok, object} = S3.get(key)
        expired = object.body |> Jason.decode!() |> Map.put(field, expired_at)
        assert {:ok, _} = S3.put(key, Jason.encode!(expired), if_match: object.etag)
      end

      refute ConnectorTokens.credential_active?(minted["token_hash"])

      assert {:ok, disconnected} = Registry.mark_disconnected(connected["connector_run_id"])
      assert disconnected["status"] == "disconnected"
      refute Map.has_key?(disconnected, "connector_run_id")
    end

    test "a revoked credential generation can neither reconnect nor displace a successor", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, first} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = first["device_id"]

      assert {:ok, _transport, _device} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 first,
                 connection_generation: 1,
                 transport_id: "transport-tombstone-old"
               )

      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 first["token"]
               )

      # The revocation high-water mark is checked in the same device CAS used
      # by connect: a late reconnect cannot create or replace a run.
      assert {:error, :connector_credential_revoked} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 first,
                 connection_generation: 2,
                 transport_id: "transport-tombstone-replay"
               )

      # A successor credential for the same stable device is unaffected.
      {:ok, second} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, successor} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 second,
                 connection_generation: 3,
                 transport_id: "transport-tombstone-new"
               )

      assert successor["status"] == "connected"

      # And the old generation still cannot displace that successor.
      assert {:error, :connector_credential_revoked} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 first,
                 connection_generation: 4,
                 transport_id: "transport-tombstone-displace"
               )

      assert {:ok, current} = Registry.get_device(tenant_id, group_id, device_id)
      assert current["status"] == "connected"
      assert current["connector_id"] == second["connector_id"]
    end

    test "revocation is durably fenced before the device ever registers", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, first} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = first["device_id"]

      # Mint reserves the generation before returning the token. Revocation
      # therefore has durable authority to advance even before first connect;
      # already-authenticated requests cannot CREATE authority on their own.
      assert :ok =
               ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, first["token"])

      assert {:ok, fenced} = Registry.get_device(tenant_id, group_id, device_id)
      assert fenced["revoked_through_generation"] >= first["credential_generation"]

      # Both delayed pre-auth requests are refused at admission.
      for generation <- [1, 2] do
        assert {:error, :connector_credential_revoked} =
                 Registry.connect(
                   to_string(node()),
                   %{
                     "tenant_id" => tenant_id,
                     "group_id" => group_id,
                     "device_id" => device_id,
                     "connector_id" => first["connector_id"],
                     "owner_user_id" => "usr_owner",
                     "scope" => "local_file_read",
                     "credential_generation" => first["credential_generation"]
                   },
                   connection_generation: generation,
                   credential_generation: first["credential_generation"],
                   transport_id: "transport-prereg-#{generation}"
                 )
      end

      # A successor credential connects normally and cannot be displaced by
      # the revoked identity afterwards.
      {:ok, second} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, successor} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 second,
                 connection_generation: 1,
                 transport_id: "transport-prereg-successor"
               )

      assert successor["status"] == "connected"
    end

    test "an expired admission is rejected before device creation", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      # This direct boundary covers the pre-CAS expiry rejection. The
      # fault-injected and live-WebSocket regressions below cover a credential
      # that expires after the check while the external device PUT is paused;
      # that path uses exact post-CAS compensation.
      long_expired = System.system_time(:second) - 3_600

      assert {:error, :connector_credential_expired} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => "dev_paused_expired",
                   "connector_id" => "conn_paused_expired",
                   "owner_user_id" => "usr_owner",
                   "scope" => "local_file_read"
                 },
                 connection_generation: 1,
                 token_expires_at: long_expired,
                 transport_id: "transport-paused-expired"
               )

      assert {:error, :not_found} =
               Registry.get_device(tenant_id, group_id, "dev_paused_expired")
    end

    test "a device CAS paused across expiry is compensated before it can remain current", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "expires_in_seconds" => 2,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, predecessor_transport, _predecessor_run} =
               connect_scoped(tenant_id, group_id, minted,
                 connection_generation: 1,
                 transport_id: "transport-expiry-predecessor"
               )

      predecessor_owner = start_rpc_owner(predecessor_transport)
      predecessor_monitor = Process.monitor(predecessor_owner)

      device_key = Keys.ctl_group_device(tenant_id, group_id, minted["device_id"])
      :ok = S3.Fake.set_fault({:pause, :put, device_key})

      connect =
        Task.async(fn ->
          connect_scoped(tenant_id, group_id, minted,
            connection_generation: 2,
            transport_id: "transport-expired-after-precheck"
          )
        end)

      wait_until(&S3.Fake.paused?/0)
      wait_until(fn -> System.system_time(:second) >= minted["expires_at"] end, 400)
      assert :ok = S3.Fake.release_pause()

      assert {:error, :connector_credential_expired} = Task.await(connect)

      assert {:ok, compensated} =
               Registry.get_device(tenant_id, group_id, minted["device_id"])

      assert compensated["status"] == "disconnected"
      refute Map.has_key?(compensated, "connector_run_id")

      # Expiry settlement exact-disconnects only the candidate written by the
      # paused CAS. It must not call predecessor retirement before returning
      # the expiry error, even though the predecessor is no longer current.
      assert Process.alive?(predecessor_owner)
      refute_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor_owner, _reason}, 50

      Process.exit(predecessor_owner, :kill)
      assert_receive {:DOWN, ^predecessor_monitor, :process, ^predecessor_owner, :killed}, 1_000
    end

    test "an admission paused at device CAS cannot replace its successor after revoke",
         %{
           tenant_id: tenant_id,
           group_id: group_id
         } do
      {:ok, stale} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = stale["device_id"]

      device_key = Keys.ctl_group_device(tenant_id, group_id, device_id)
      :ok = S3.Fake.set_fault({:pause, :put, device_key})

      stale_connect =
        Task.async(fn ->
          Registry.connect(
            to_string(node()),
            %{
              "tenant_id" => tenant_id,
              "group_id" => group_id,
              "device_id" => device_id,
              "connector_id" => stale["connector_id"],
              "owner_user_id" => "usr_owner",
              "scope" => "local_file_read",
              "credential_generation" => stale["credential_generation"]
            },
            connection_generation: 1,
            credential_generation: stale["credential_generation"],
            token_expires_at: stale["expires_at"],
            transport_id: "transport-expiry-stale"
          )
        end)

      wait_until(&S3.Fake.paused?/0)

      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 stale["token"]
               )

      {:ok, replacement} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, successor} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => replacement["connector_id"],
                   "owner_user_id" => "usr_owner",
                   "scope" => "local_file_read",
                   "credential_generation" => replacement["credential_generation"]
                 },
                 connection_generation: 2,
                 credential_generation: replacement["credential_generation"],
                 token_expires_at: replacement["expires_at"],
                 transport_id: "transport-expiry-successor"
               )

      assert :ok = S3.Fake.release_pause()

      assert {:error, :connector_credential_revoked} = Task.await(stale_connect)
      assert {:ok, current} = Registry.get_device(tenant_id, group_id, device_id)
      assert current["connector_run_id"] == successor["connector_run_id"]
      assert current["connector_id"] == replacement["connector_id"]
    end

    test "the generation fence denies admission while the token record still exists", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = minted["device_id"]

      assert {:ok, _transport, connected} =
               connect_scoped(
                 tenant_id,
                 group_id,
                 minted,
                 connection_generation: 1,
                 transport_id: "transport-tombstone-fence"
               )

      # Land only the durable generation fence and leave the token object
      # untouched. Record deletion is cleanup, never the authorization fence.
      assert {:ok, _device, _stop_target} =
               Registry.revoke_connector_credential(
                 tenant_id,
                 group_id,
                 device_id,
                 minted["connector_id"],
                 minted["credential_generation"]
               )

      assert {:ok, _tenant, _record} = ConnectorTokens.validate_connector_token(minted["token"])
      refute ConnectorTokens.credential_active?(minted["token_hash"])

      read_ref = make_ref()

      assert {:stop, {:shutdown, :connector_token_revoked}, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_read_stream, read_ref, self(),
                  rpc_frame("revoked-use-time-read", "read_ref", %{
                    "local_file_ref" => "lfi1_revoked"
                  })},
                 %SalixWeb.ConnectorSocket.State{
                   env_id: connected["transport_id"],
                   connector_run_id: connected["connector_run_id"],
                   connection_generation: connected["connection_generation"],
                   tenant_id: tenant_id,
                   group_id: group_id,
                   device_id: device_id,
                   connector_id: minted["connector_id"],
                   credential_generation: minted["credential_generation"],
                   scope: "local_file_read"
                 }
               )

      assert_receive {:env_read_stream_reply, ^read_ref, {:error, :connector_credential_revoked}}

      assert {:stop, {:shutdown, :connector_token_revoked}, _state} =
               SalixWeb.ConnectorSocket.init(
                 env_id: "env-tombstone-fence",
                 connector_run_id: "run-tombstone-fence",
                 connection_generation: 2,
                 tenant_id: tenant_id,
                 group_id: group_id,
                 device_id: device_id,
                 connector_id: minted["connector_id"],
                 credential_generation: minted["credential_generation"],
                 scope: "local_file_read",
                 token_hash: minted["token_hash"]
               )
    end

    test "the monotonic revocation high-water mark has no fixed-count eviction window", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = minted["device_id"]

      last =
        Enum.reduce(1..20, minted, fn _index, previous ->
          {:ok, successor} =
            ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
              "scope" => "local_file_read",
              "stable_device_id" => device_id,
              "meta" => %{"owner_user_id" => "usr_owner"}
            })

          assert :ok =
                   ConnectorTokens.revoke_group_connector_token(
                     group_id,
                     tenant_id,
                     previous["token"]
                   )

          successor
        end)

      assert {:ok, device} = Registry.get_device(tenant_id, group_id, device_id)
      assert device["active_credential_generation"] == last["credential_generation"]
      assert device["revoked_through_generation"] == last["credential_generation"] - 1

      assert {:error, :connector_credential_revoked} =
               Registry.connect(
                 to_string(node()),
                 %{
                   "tenant_id" => tenant_id,
                   "group_id" => group_id,
                   "device_id" => device_id,
                   "connector_id" => minted["connector_id"],
                   "owner_user_id" => "usr_owner",
                   "scope" => "local_file_read",
                   "credential_generation" => minted["credential_generation"]
                 },
                 connection_generation: 1,
                 credential_generation: minted["credential_generation"],
                 transport_id: "transport-generation-retention"
               )
    end

    test "an older delayed revoke cannot roll the generation fence backward", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      device_id = minted["device_id"]

      {:ok, successor} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 successor["token"]
               )

      assert :ok =
               ConnectorTokens.revoke_group_connector_token(group_id, tenant_id, minted["token"])

      assert {:ok, device} = Registry.get_device(tenant_id, group_id, device_id)
      assert device["revoked_through_generation"] == successor["credential_generation"]
    end

    test "a later high-water mark cannot falsely settle an ambiguous older owner stop", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, first} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, old_run} =
               connect_scoped(tenant_id, group_id, first,
                 connection_generation: 1,
                 transport_id: "transport-ambiguous-old-owner"
               )

      {:ok, successor} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "stable_device_id" => first["device_id"],
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      # Revoking the not-yet-connected successor advances the global fence,
      # but the top-level physical run still belongs to the first credential.
      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 successor["token"]
               )

      device_key = Keys.ctl_group_device(tenant_id, group_id, first["device_id"])
      :ok = S3.Fake.set_fault({:ambiguous_before, :put, device_key})

      assert {:error, {:ambiguous, {:credential_revocation, connector_id}}} =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 first["token"]
               )

      assert connector_id == first["connector_id"]
      assert {:ok, retained_token} = S3.get(Keys.ctl_connector_token(first["token_hash"]))
      assert retained_token.body != ""

      assert {:ok, still_current} = Registry.get_device(tenant_id, group_id, first["device_id"])
      assert still_current["connector_run_id"] == old_run["connector_run_id"]

      # Retry records and confirms the exact owner obligation before deleting
      # the token; the pre-existing high-water mark never substitutes for it.
      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 first["token"]
               )

      assert {:error, :not_found} = S3.get(Keys.ctl_connector_token(first["token_hash"]))
    end

    test "an admission that raced a revocation stops instead of serving", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert ConnectorTokens.credential_active?(minted["token_hash"])

      # A socket whose /v1/connect validated the token before the durable
      # generation fence re-checks after owner registration and must refuse to
      # serve. Token-record deletion is only cleanup after containment.
      assert :ok =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 minted["token"]
               )

      refute ConnectorTokens.credential_active?(minted["token_hash"])

      assert {:stop, {:shutdown, :connector_token_revoked}, _state} =
               SalixWeb.ConnectorSocket.init(
                 env_id: "env-admission-race",
                 connector_run_id: "run-admission-race",
                 connection_generation: 1,
                 tenant_id: tenant_id,
                 group_id: group_id,
                 device_id: minted["device_id"],
                 connector_id: minted["connector_id"],
                 credential_generation: minted["credential_generation"],
                 scope: "local_file_read",
                 token_hash: minted["token_hash"]
               )
    end

    test "a delayed socket init for a superseded exact run cannot serve with the same token", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, first_transport, first_run} =
               connect_scoped(tenant_id, group_id, minted,
                 connection_generation: 1,
                 transport_id: "transport-same-token-first"
               )

      assert {:ok, _second_transport, second_run} =
               connect_scoped(tenant_id, group_id, minted,
                 connection_generation: 2,
                 transport_id: "transport-same-token-second"
               )

      assert {:ok, true} =
               Registry.connector_run_credential_active?(
                 tenant_id,
                 group_id,
                 minted["device_id"],
                 minted["connector_id"],
                 minted["credential_generation"],
                 second_run["connector_run_id"],
                 second_run["connection_generation"]
               )

      parent = self()

      late_init =
        spawn(fn ->
          result =
            SalixWeb.ConnectorSocket.init(
              env_id: first_transport,
              connector_run_id: first_run["connector_run_id"],
              connection_generation: first_run["connection_generation"],
              tenant_id: tenant_id,
              group_id: group_id,
              device_id: minted["device_id"],
              connector_id: minted["connector_id"],
              credential_generation: minted["credential_generation"],
              scope: "local_file_read",
              token_hash: minted["token_hash"]
            )

          send(parent, {:late_init_result, result})
        end)

      late_monitor = Process.monitor(late_init)

      assert_receive {:late_init_result, {:stop, {:shutdown, :connector_token_revoked}, _state}},
                     1_000

      assert_receive {:DOWN, ^late_monitor, :process, ^late_init, _reason}, 1_000
    end

    test "revocation remains retryable when the remote socket owner cannot confirm stop", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      {:ok, minted} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "scope" => "local_file_read",
          "meta" => %{"owner_user_id" => "usr_owner"}
        })

      assert {:ok, _transport, device} =
               connect_scoped(
                 "partitioned-owner@unreachable",
                 tenant_id,
                 group_id,
                 minted,
                 %{},
                 connection_generation: 1,
                 transport_id: "transport-partitioned-owner"
               )

      assert {:error, {:owner_stop_unconfirmed, _reason}} =
               ConnectorTokens.revoke_group_connector_token(
                 group_id,
                 tenant_id,
                 minted["token"]
               )

      # The durable fence must already fail closed even though cleanup is
      # pending, while the token record remains available for a later retry.
      refute ConnectorTokens.credential_active?(minted["token_hash"])

      assert {:error, :disconnected} =
               SalixEnv.Connector.Live.read_stream(
                 device["connector_run_id"],
                 rpc_frame("revoked-read", "read_ref", %{"local_file_ref" => "lfi1_revoked"})
               )

      assert {:ok, _token_object} = S3.get(Keys.ctl_connector_token(minted["token_hash"]))
    end
  end

  defp put_legacy_token_record!(token_hash, tenant_id, group_id, device_id, connector_id) do
    record = %{
      "token_hash" => token_hash,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "device_id" => device_id,
      "connector_id" => connector_id,
      "name" => "Legacy retirement",
      "alias" => "Legacy retirement",
      "meta" => %{"owner_user_id" => "usr_legacy"},
      "created_at" => System.system_time(:second),
      "expires_at" => nil
    }

    {:ok, _} =
      S3.put(Keys.ctl_connector_token(token_hash), Jason.encode!(record), if_none_match: "*")

    :ok
  end

  describe "operator recovery of generation credentials" do
    test "attested recovery preserves the device and permits a successor after rollout",
         %{tenant_id: tenant_id, group_id: group_id} do
      {:ok, token} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "meta" => %{"owner_user_id" => "usr_recovery"}
        })

      device_id = token["device_id"]
      hash = :crypto.hash(:sha256, token["token"]) |> Base.encode16(case: :lower)
      {:ok, _, _} = connect_scoped("retired-pod@gone", tenant_id, group_id, token, %{}, [])

      assert {:error, {:owner_stop_unconfirmed, _}} =
               ConnectorTokens.recover_connector_token(hash, device_id, group_id, tenant_id)

      assert {:ok, fenced} = Registry.get_device(tenant_id, group_id, device_id)
      assert fenced["revoked_through_generation"] == token["credential_generation"]
      assert {:ok, _} = S3.get(Keys.ctl_connector_token(hash))
      refute ConnectorTokens.credential_active?(hash)

      assert {:error, {:owner_stop_unconfirmed, _}} =
               ConnectorTokens.recover_connector_token(hash, device_id, group_id, tenant_id,
                 dead_nodes: ["different-pod@gone"]
               )

      assert :ok =
               ConnectorTokens.recover_connector_token(hash, device_id, group_id, tenant_id,
                 dead_nodes: ["retired-pod@gone"]
               )

      assert {:error, :not_found} = S3.get(Keys.ctl_connector_token(hash))
      assert {:ok, preserved} = Registry.get_device(tenant_id, group_id, device_id)
      assert preserved["revoked_through_generation"] == token["credential_generation"]
      refute Map.has_key?(preserved, "pending_connector_revocations")

      assert {:ok, :already_revoked} =
               ConnectorTokens.recover_connector_token(hash, device_id, group_id, tenant_id)

      {:ok, successor} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_recovery"}
        })

      assert {:ok, _, _} = connect_scoped(tenant_id, group_id, successor, [])
    end

    test "scope mismatch cannot fence or clear another credential",
         %{tenant_id: tenant_id, group_id: group_id} do
      {:ok, token} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "meta" => %{"owner_user_id" => "usr_recovery"}
        })

      hash = :crypto.hash(:sha256, token["token"]) |> Base.encode16(case: :lower)
      {:ok, _, before} = connect_scoped("retired-pod@gone", tenant_id, group_id, token, %{}, [])

      assert {:error, :token_scope_mismatch} =
               ConnectorTokens.recover_connector_token(hash, "wrong-device", group_id, tenant_id,
                 dead_nodes: ["retired-pod@gone"]
               )

      assert {:ok, ^before} = Registry.get_device(tenant_id, group_id, token["device_id"])
      assert ConnectorTokens.credential_active?(hash)
    end

    test "an older recovery neither revokes a successor nor clears its pending owners",
         %{tenant_id: tenant_id, group_id: group_id} do
      {:ok, old} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "meta" => %{"owner_user_id" => "usr_recovery"}
        })

      device_id = old["device_id"]
      hash = :crypto.hash(:sha256, old["token"]) |> Base.encode16(case: :lower)
      {:ok, _, _} = connect_scoped("old-pod@gone", tenant_id, group_id, old, %{}, [])

      {:ok, successor} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "stable_device_id" => device_id,
          "meta" => %{"owner_user_id" => "usr_recovery"}
        })

      {:ok, _, _} = connect_scoped("newer-pod@gone", tenant_id, group_id, successor, %{}, [])
      {:ok, _, current} = connect_scoped(tenant_id, group_id, successor, [])
      {:ok, before} = Registry.get_device(tenant_id, group_id, device_id)
      successor_key = to_string(successor["credential_generation"])
      successor_pending = before["pending_connector_revocations"][successor_key]
      assert [_] = successor_pending

      assert :ok =
               ConnectorTokens.recover_connector_token(hash, device_id, group_id, tenant_id,
                 dead_nodes: ["old-pod@gone", "newer-pod@gone"]
               )

      assert {:ok, after_recovery} = Registry.get_device(tenant_id, group_id, device_id)
      assert after_recovery["connector_run_id"] == current["connector_run_id"]
      assert after_recovery["status"] == "connected"
      assert after_recovery["pending_connector_revocations"][successor_key] == successor_pending

      assert ConnectorTokens.credential_active?(
               :crypto.hash(:sha256, successor["token"])
               |> Base.encode16(case: :lower)
             )
    end

    test "attestation never substitutes for a reachable owner's stop",
         %{tenant_id: tenant_id, group_id: group_id} do
      {:ok, token} =
        ConnectorTokens.create_group_connector_token(group_id, tenant_id, %{
          "meta" => %{"owner_user_id" => "usr_recovery"}
        })

      {:ok, transport, _} = connect_scoped(tenant_id, group_id, token, [])
      owner = start_rpc_owner(transport)
      monitor = Process.monitor(owner)
      hash = :crypto.hash(:sha256, token["token"]) |> Base.encode16(case: :lower)

      assert :ok =
               ConnectorTokens.recover_connector_token(
                 hash,
                 token["device_id"],
                 group_id,
                 tenant_id,
                 dead_nodes: [to_string(node())]
               )

      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 1_000
    end
  end

  defp connect_scoped(tenant_id, group_id, credential, opts) do
    connect_scoped(to_string(node()), tenant_id, group_id, credential, %{}, opts)
  end

  defp connect_scoped(tenant_id, group_id, credential, extra_meta, opts) do
    connect_scoped(to_string(node()), tenant_id, group_id, credential, extra_meta, opts)
  end

  defp connect_scoped(owner_node, tenant_id, group_id, credential, extra_meta, opts) do
    meta =
      Map.merge(
        %{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "device_id" => credential["device_id"],
          "connector_id" => credential["connector_id"],
          "scope" => "local_file_read",
          "credential_generation" => credential["credential_generation"]
        },
        extra_meta
      )

    opts =
      opts
      |> Keyword.put(:credential_generation, credential["credential_generation"])
      |> Keyword.put(:token_expires_at, credential["expires_at"])

    Registry.connect(owner_node, meta, opts)
  end

  defp start_rpc_owner(transport_id) do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, _} = Elixir.Registry.register(SalixEnv.Bridges, transport_id, :connector)
        send(parent, {:rpc_owner_ready, self()})
        rpc_owner_loop(transport_id)
      end)

    assert_receive {:rpc_owner_ready, ^owner}, 1_000
    owner
  end

  defp rpc_owner_loop(transport_id) do
    receive do
      {:env_rpc, ref, from, %{"method" => method}} ->
        send(from, {:env_rpc_reply, ref, {:ok, %{"method" => method}}})
        rpc_owner_loop(transport_id)

      {:env_owner_takeover, ^transport_id, _replacement} ->
        :ok
    end
  end

  defp gated_task(fun) when is_function(fun, 0) do
    owner = self()

    Task.async(fn ->
      receive do
        {:start_gated_task, ^owner} -> fun.()
      end
    end)
  end

  defp start_gated_task(%Task{pid: pid}) do
    send(pid, {:start_gated_task, self()})
    :ok
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("timed out waiting for deterministic test barrier")
end
