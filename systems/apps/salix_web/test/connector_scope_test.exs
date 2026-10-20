defmodule SalixWeb.ConnectorScopeTest do
  require SystemsRuntime.Proc

  @moduledoc """
  The `local_file_read` connector credential scope is server-authoritative:
  it bounds what the socket will route, what the control plane projects, how
  long the credential lives, and which stable device it may re-attach to.
  """
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

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
                Map.put(record, "registration_expires_at", SystemsClock.system_time(:second) - 1)
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
      ref = SystemsRuntime.Proc.make_ref()

      assert {:ok, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_rpc, ref, SystemsRuntime.Proc.self(),
                  rpc_frame("rpc-exec", "exec", %{"command" => "id"})},
                 state
               )

      settle_receive({:env_rpc_reply, ^ref, {:error, :connector_scope_forbidden}})
      read_ref_stream = SystemsRuntime.Proc.make_ref()

      assert {:ok, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_read_stream, read_ref_stream, SystemsRuntime.Proc.self(),
                  rpc_frame("stream-read", "read_stream", %{"path" => "/etc/hosts"})},
                 state
               )

      settle_receive(
        {:env_read_stream_reply, ^read_ref_stream, {:error, :connector_scope_forbidden}}
      )

      write_ref = SystemsRuntime.Proc.make_ref()

      assert {:ok, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_write_stream, :begin, write_ref, SystemsRuntime.Proc.self(),
                  rpc_frame("stream-write", "write_stream", %{"path" => "/tmp/x"})},
                 state
               )

      settle_receive({:env_write_stream_reply, ^write_ref, {:error, :connector_scope_forbidden}})
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

      ref = SystemsRuntime.Proc.make_ref()

      assert {:push, {:text, _frame}, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_read_stream, ref, SystemsRuntime.Proc.self(),
                  rpc_frame("stream-ref", "read_ref", %{"local_file_ref" => "lfi1_x"})},
                 state
               )

      settle_receive({:env_read_stream_reply, ^ref, {:ok, _stream, nil}})
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
      assert restricted_environment["permission_message"] =~ "Access to Full"

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
  end

  describe "credential lifecycle" do

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

      # Revoking an already revoked credential is idempotent.
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

    test "an expired admission is rejected before device creation", %{
      tenant_id: tenant_id,
      group_id: group_id
    } do
      # This direct boundary covers the pre-CAS expiry rejection. The
      # fault-injected and live-WebSocket regressions below cover a credential
      # that expires after the check while the external device PUT is paused;
      # that path uses exact post-CAS compensation.
      long_expired = SystemsClock.system_time(:second) - 3_600

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

      read_ref = SystemsRuntime.Proc.make_ref()

      assert {:stop, {:shutdown, :connector_token_revoked}, _state} =
               SalixWeb.ConnectorSocket.handle_info(
                 {:env_read_stream, read_ref, SystemsRuntime.Proc.self(),
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

      settle_receive({:env_read_stream_reply, ^read_ref, {:error, :connector_credential_revoked}})

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
end
