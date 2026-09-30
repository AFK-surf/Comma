defmodule BridgeForTeamsWeb.MacMiniProvisionerFlowTest do
  @moduledoc """
  End-to-end API tests for the BFT runner control-plane slice.

  These drive the real Endpoint pipeline with org API keys so the tests cover
  authentication, scope checks, request claiming, one-time connector-token
  handoff, and non-secret provisioning status callbacks.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Schema.{ApiKey, MacMiniInstallCode}
  alias BridgeForTeams.{Environments, Observability, Orgs, Projects, Repo}
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeamsWeb.DashboardEndpoint

  setup do
    previous_salix_public_base_url = Application.get_env(:salix_web, :public_base_url)
    Application.put_env(:salix_web, :public_base_url, "https://salix.example.test")

    on_exit(fn ->
      case previous_salix_public_base_url do
        nil -> Application.delete_env(:salix_web, :public_base_url)
        value -> Application.put_env(:salix_web, :public_base_url, value)
      end
    end)

    SalixStore.S3.Fake.reset()

    {:ok, org} =
      Orgs.create_org(%{"name" => "Org", "slug" => "org-#{System.unique_integer([:positive])}"})

    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Proj",
        "slug" => "proj-#{System.unique_integer([:positive])}"
      })

    drain_all()

    %{org: org, project: project, api_key: api_key_for(org)}
  end

  defp drain_all do
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp api_key_for(org, scopes \\ ["runners:write"]) do
    raw = "prov-#{System.unique_integer([:positive])}"

    %ApiKey{}
    |> ApiKey.changeset(%{
      org_id: org.id,
      name: "mac-mini-provisioner",
      key_hash: Sessions.hash_token(raw),
      scopes: scopes
    })
    |> Repo.insert!()

    raw
  end

  defp bound_api_key_for(org, stable_id) do
    raw = "bound-prov-#{System.unique_integer([:positive])}"

    api_key =
      %ApiKey{}
      |> ApiKey.changeset(%{
        org_id: org.id,
        name: "bound-mac-mini-provisioner",
        key_hash: Sessions.hash_token(raw),
        scopes: ["runners:write"]
      })
      |> Repo.insert!()

    now = DateTime.utc_now()

    %MacMiniInstallCode{}
    |> MacMiniInstallCode.changeset(%{
      org_id: org.id,
      api_key_id: api_key.id,
      code_hash: Sessions.hash_token("install-#{raw}"),
      server_build_id: String.duplicate("a", 40),
      runner_stable_id: stable_id,
      expires_at: DateTime.add(now, 60, :second),
      consumed_at: now
    })
    |> Repo.insert!()

    raw
  end

  defp authed(method, path, token, body, headers \\ []) do
    build_conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_headers(headers)
    |> DashboardEndpoint.call([])
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {key, value}, conn ->
      put_req_header(conn, key, value)
    end)
  end

  defp register_provisioner(org, token, attrs \\ %{}, headers \\ []) do
    base = %{
      "stable_id" => "mac-mini-#{System.unique_integer([:positive])}",
      "name" => "Lab Mac mini",
      "host_identity" => "lab-host",
      "os_summary" => "macOS",
      "version" => "0.1.0",
      "capabilities" => %{"salix_connect" => true},
      "capacity" => 2
    }

    conn =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners",
        token,
        Map.merge(base, attrs),
        headers
      )

    assert conn.status == 201

    %{"runner" => provisioner} = Jason.decode!(conn.resp_body)
    provisioner
  end

  test "register and heartbeat require an org API key with provisioner scope", %{
    org: org,
    api_key: api_key
  } do
    provisioner = register_provisioner(org, api_key, %{}, [{"x-request-id", "req-api-register"}])

    refute Map.has_key?(provisioner, "token")
    assert provisioner["org_id"] == org.id
    assert provisioner["status"] == "online"
    assert provisioner["last_seen_at"]

    assert [registered] =
             Observability.list_events(org.id,
               resource_type: "mac_mini_provisioner",
               resource_id: provisioner["id"],
               event_type: "runner.registered"
             )

    assert registered.correlation_id == "req-api-register"
    assert registered.evidence["request_id"] == "req-api-register"

    conn =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{provisioner["id"]}/heartbeat",
        api_key,
        %{
          "current_connector_count" => 1,
          "capabilities" => %{
            "salix_connect" => true,
            "component_versions" => %{"salix-connect" => "0.1.0"}
          }
        },
        [{"x-request-id", "req-api-heartbeat-online"}]
      )

    assert conn.status == 200
    %{"runner" => heartbeat} = Jason.decode!(conn.resp_body)
    assert heartbeat["current_connector_count"] == 1
    assert heartbeat["capabilities"]["component_versions"]["salix-connect"] == "0.1.0"

    degraded_conn =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{provisioner["id"]}/heartbeat",
        api_key,
        %{"status" => "degraded"},
        [{"x-request-id", "req-api-heartbeat-degraded"}]
      )

    assert degraded_conn.status == 200

    assert [degraded_event] =
             Observability.list_events(org.id,
               resource_type: "mac_mini_provisioner",
               resource_id: provisioner["id"],
               event_type: "runner.status_changed",
               status: "degraded"
             )

    assert degraded_event.correlation_id == "req-api-heartbeat-degraded"
    assert degraded_event.evidence["request_id"] == "req-api-heartbeat-degraded"

    scoped_out = api_key_for(org, ["projects:read"])

    forbidden =
      authed(:post, "/v1/orgs/#{org.id}/runners", scoped_out, %{
        "stable_id" => "mac-mini-nope",
        "name" => "Nope"
      })

    assert forbidden.status == 403
  end

  test "installer-minted runner key cannot heartbeat a different runner", %{org: org} do
    admin_key = api_key_for(org)
    runner_a = register_provisioner(org, admin_key, %{"stable_id" => "runner-a"})
    runner_b = register_provisioner(org, admin_key, %{"stable_id" => "runner-b"})
    runner_a_key = bound_api_key_for(org, "runner-a")

    own =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{runner_a["id"]}/heartbeat",
        runner_a_key,
        %{}
      )

    assert own.status == 200

    foreign =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{runner_b["id"]}/heartbeat",
        runner_a_key,
        %{}
      )

    assert foreign.status == 403
  end

  test "heartbeat delivers one install descriptor only to its exact runner", %{
    org: org,
    project: project,
    api_key: api_key
  } do
    suffix = System.unique_integer([:positive])
    first = register_provisioner(org, api_key, %{"stable_id" => "runner-first-#{suffix}"})
    second = register_provisioner(org, api_key, %{"stable_id" => "runner-second-#{suffix}"})

    assert {:ok, operation} =
             BridgeForTeams.Compute.request_agent_vmm_install(org, project, %{
               "request_id" => "heartbeat-install-#{suffix}",
               "runner_id" => first["stable_id"]
             })

    wrong =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{second["id"]}/heartbeat",
        api_key,
        %{}
      )

    assert wrong.status == 200
    wrong_response = Jason.decode!(wrong.resp_body)
    refute Map.has_key?(wrong_response, "agent_vmm_install")

    assert wrong_response["agent_vmm_controls"] == %{
             "version" => 1,
             "items" => [],
             "next_cursor" => nil
           }

    exact =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{first["id"]}/heartbeat",
        api_key,
        %{}
      )

    assert exact.status == 200
    assert get_resp_header(exact, "cache-control") == ["no-store"]
    response = Jason.decode!(exact.resp_body)
    descriptor = response["agent_vmm_install"]
    assert descriptor["operation_id"] == operation.id
    assert descriptor["version"] == 1

    assert descriptor["exchange_url"] ==
             "https://salix.example.test/v1/compute/agent-vmm/install-operations/exchange"

    assert is_binary(descriptor["one_time_secret"])
    assert response["agent_vmm_controls"]["items"] == []

    stored = Repo.get!(BridgeForTeams.Schema.MacMiniProvisioner, first["id"])
    refute inspect(stored) =~ descriptor["one_time_secret"]
  end

  test "heartbeat acknowledges an exact terminal install report before redelivery", %{
    org: org,
    project: project,
    api_key: api_key
  } do
    suffix = System.unique_integer([:positive])
    runner = register_provisioner(org, api_key, %{"stable_id" => "runner-failure-#{suffix}"})

    assert {:ok, operation} =
             BridgeForTeams.Compute.request_agent_vmm_install(org, project, %{
               "request_id" => "heartbeat-failure-#{suffix}",
               "runner_id" => runner["stable_id"]
             })

    response =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{runner["id"]}/heartbeat",
        api_key,
        %{
          "agent_vmm_install_failures" => [
            %{
              "operation_id" => operation.id,
              "failure_code" => "agent_vmm.install_failed"
            }
          ]
        }
      )

    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["agent_vmm_install_failure_acks"] == [operation.id]
    refute Map.has_key?(body, "agent_vmm_install")

    assert {:ok, stored} =
             BridgeForTeams.Compute.get_agent_vmm_install(org, project, operation.id)

    assert stored.authorization_status == "action_required"
    assert stored.error_code == "agent_vmm.install_failed"
  end

  test "claim returns a one-time connector token and stores only its hash", %{
    org: org,
    project: project,
    api_key: api_key
  } do
    provisioner = register_provisioner(org, api_key)

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner["id"],
               "name" => "prod-mac",
               "alias" => "prod"
             })

    conn =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{provisioner["id"]}/claim",
        api_key,
        %{}
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["action"] == "create"
    refute Map.has_key?(body["connect"], "token_hash")
    refute Map.has_key?(body["connect"], "meta")

    assert %{"token" => token, "env" => env} = body["connect"]
    assert String.starts_with?(token, "salix_conn_")

    assert env == %{
             "SALIX_CONNECTOR_TOKEN" => token,
             "SALIX_SERVER" => body["connect"]["server"]
           }

    assert body["device_request"]["id"] == request.id
    assert body["device_request"]["status"] == "preflight"

    assert body["launch"] == %{
             "name" => "prod-mac",
             "alias" => "prod",
             "root" => "agents/bft_" <> String.replace(request.id, "-", "_")
           }

    assert {:ok, reloaded} = Environments.get_device_provision_request(request.id)
    assert reloaded.status == "preflight"
    assert reloaded.connector_token_hash == Sessions.hash_token(token)
    refute inspect(reloaded) =~ token

    assert {:ok, tenant_id, token_record} =
             SalixEnv.ConnectorTokens.validate_connector_token(token)

    assert tenant_id == org.salix_tenant_id
    assert token_record["group_id"] == project.salix_group_id
    assert token_record["meta"]["provision_request_id"] == request.id
    assert token_record["meta"]["provisioner_id"] == provisioner["id"]

    status_path =
      "/v1/orgs/#{org.id}/runners/#{provisioner["id"]}/provision-requests/#{request.id}/status"

    waiting =
      authed(
        :post,
        status_path,
        api_key,
        %{
          "status" => "waiting_for_attach",
          "connector_run_id" => "env_spoofed_by_worker",
          "progress" => %{
            "stage" => "waiting_for_attach",
            "dry_run" => true,
            "pid" => 1234,
            "restart_count" => 1,
            "root" => "/tmp/work/agents/bft_req_1",
            "cleanup" => %{
              "mode" => "remove_on_stop",
              "removed" => ["root"],
              "raw_path" => token
            },
            "launch" => %{
              "argv_shape" => ["salix-connect", "--connector-token", "<token>"],
              "argv" => ["salix-connect", token]
            },
            "raw_token" => token,
            "stdout" => "secret #{token}"
          }
        },
        [{"x-request-id", "req-api-status-waiting"}]
      )

    assert waiting.status == 200
    waiting_body = Jason.decode!(waiting.resp_body)
    refute Map.has_key?(waiting_body, "connect")
    assert waiting_body["provision_request"]["status"] == "waiting_for_attach"
    assert waiting_body["provision_request"]["connector_run_id"] == nil
    assert waiting_body["provision_request"]["progress"]["stage"] == "waiting_for_attach"
    assert waiting_body["provision_request"]["progress"]["dry_run"] == true
    assert waiting_body["provision_request"]["progress"]["restart_count"] == 1
    assert waiting_body["provision_request"]["progress"]["cleanup"]["mode"] == "remove_on_stop"
    assert waiting_body["provision_request"]["progress"]["cleanup"]["removed"] == ["root"]
    assert waiting_body["provision_request"]["progress"]["launch"]["argv_shape"]
    refute Map.has_key?(waiting_body["provision_request"]["progress"], "raw_token")
    refute Map.has_key?(waiting_body["provision_request"]["progress"], "stdout")
    refute Map.has_key?(waiting_body["provision_request"]["progress"]["cleanup"], "raw_path")
    refute Map.has_key?(waiting_body["provision_request"]["progress"]["launch"], "argv")
    refute inspect(waiting_body) =~ token

    connected_attempt =
      authed(:post, status_path, api_key, %{
        "status" => "connected",
        "connector_run_id" => "env_mac_prod",
        "progress" => %{"stage" => "connected", "connector_run_id" => "env_mac_prod"}
      })

    assert connected_attempt.status == 422
    assert Jason.decode!(connected_attempt.resp_body)["error"] == "unsupported_provisioner_status"

    show =
      authed(
        :get,
        "/v1/orgs/#{org.id}/runners/#{provisioner["id"]}/provision-requests/#{request.id}",
        api_key,
        %{}
      )

    assert show.status == 200
    show_body = Jason.decode!(show.resp_body)
    assert show_body["provision_request"]["status"] == "waiting_for_attach"
    assert show_body["provision_request"]["connector_run_id"] == nil
    assert show_body["provision_request"]["progress"]["stage"] == "waiting_for_attach"
    refute Map.has_key?(show_body, "connect")
    refute inspect(show_body) =~ token

    assert {:ok, waiting_request} = Environments.get_device_provision_request(request.id)
    assert waiting_request.connector_run_id == nil
    assert waiting_request.connector_token_hash == Sessions.hash_token(token)
    assert waiting_request.progress["stage"] == "waiting_for_attach"

    waiting_events =
      Observability.list_events(org.id,
        resource_type: "device_provision_request",
        resource_id: request.id
      )

    waiting_event =
      Enum.find(waiting_events, &(&1.event_type == "device.provision.waiting_for_attach"))

    assert waiting_event.evidence["request_id"] == "req-api-status-waiting"
  end

  test "claim returns stop action before create work without exposing token", %{
    org: org,
    project: project,
    api_key: api_key
  } do
    provisioner = register_provisioner(org, api_key)

    assert {:ok, request} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner["id"],
               "name" => "prod-mac",
               "alias" => "prod"
             })

    assert {:ok, connected} =
             Environments.update_device_provision_request_status(
               request,
               "connected",
               %{"connector_run_id" => "env_mac_prod"}
             )

    assert {:ok, _stop_requested} = Environments.request_device_provision_stop(connected.id)

    assert {:ok, _pending_create} =
             Environments.create_device_provision_request(project.id, %{
               "provisioner_id" => provisioner["id"],
               "name" => "next-mac"
             })

    conn =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{provisioner["id"]}/claim",
        api_key,
        %{"available_capacity" => 0}
      )

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["action"] == "stop"
    assert body["connect"] == %{}
    refute inspect(body) =~ "salix_conn_"
    assert body["launch"]["provision_request_id"] == request.id
    assert body["launch"]["connector_run_id"] == "env_mac_prod"
    assert body["device_request"]["status"] == "stopping"
  end

  test "claim with no pending request returns no content", %{org: org, api_key: api_key} do
    provisioner = register_provisioner(org, api_key)

    conn =
      authed(
        :post,
        "/v1/orgs/#{org.id}/runners/#{provisioner["id"]}/claim",
        api_key,
        %{}
      )

    assert conn.status == 204
    assert conn.resp_body == ""
  end

  test "org API keys cannot operate another org provisioner route", %{api_key: api_key} do
    {:ok, other_org} =
      Orgs.create_org(%{
        "name" => "Other",
        "slug" => "other-#{System.unique_integer([:positive])}"
      })

    conn =
      authed(:post, "/v1/orgs/#{other_org.id}/runners", api_key, %{
        "stable_id" => "mac-mini-cross-org",
        "name" => "Cross org"
      })

    assert conn.status == 403

    assert [] = Environments.list_mac_mini_provisioners(other_org.id)
  end
end
