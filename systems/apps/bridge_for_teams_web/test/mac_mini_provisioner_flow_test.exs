defmodule BridgeForTeamsWeb.MacMiniProvisionerFlowTest do
  @moduledoc """
  End-to-end API tests for the BFT runner control-plane slice.

  These drive the real Endpoint pipeline with org API keys so the tests cover
  authentication, scope checks and the heartbeat's Agent VMM handoffs.
  """
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.Schema.{ApiKey, MacMiniInstallCode}
  alias BridgeForTeams.{Environments, Observability, Orgs, Projects, Repo}
  alias BridgeForTeams.Salix.Reconciler
  alias BridgeForTeamsWeb.DashboardEndpoint

  setup do
    previous_salix_public_base_url = SystemsRuntime.get_env(:salix_web, :public_base_url)
    SystemsRuntime.put_env(:salix_web, :public_base_url, "https://salix.example.test")

    on_exit(fn ->
      case previous_salix_public_base_url do
        nil -> SystemsRuntime.delete_env(:salix_web, :public_base_url)
        value -> SystemsRuntime.put_env(:salix_web, :public_base_url, value)
      end
    end)

    SalixStore.S3.Fake.reset()

    {:ok, org} =
      Orgs.create_org(%{
        "name" => "Org",
        "slug" => "org-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      })

    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Proj",
        "slug" => "proj-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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
    raw = "prov-#{SystemsRuntime.Proc.unique_integer([:positive])}"

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
    raw = "bound-prov-#{SystemsRuntime.Proc.unique_integer([:positive])}"

    api_key =
      %ApiKey{}
      |> ApiKey.changeset(%{
        org_id: org.id,
        name: "bound-mac-mini-provisioner",
        key_hash: Sessions.hash_token(raw),
        scopes: ["runners:write"]
      })
      |> Repo.insert!()

    now = SystemsClock.utc_now()

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
      "stable_id" => "mac-mini-#{SystemsRuntime.Proc.unique_integer([:positive])}",
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
          "capabilities" => %{
            "component_versions" => %{"agent-vmm-host" => "0.1.0"}
          }
        },
        [{"x-request-id", "req-api-heartbeat-online"}]
      )

    assert conn.status == 200
    %{"runner" => heartbeat} = Jason.decode!(conn.resp_body)
    assert heartbeat["capabilities"]["component_versions"]["agent-vmm-host"] == "0.1.0"

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
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
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
    refute Map.has_key?(wrong_response, "agent_vmm_registration")

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
    descriptor = response["agent_vmm_registration"]
    assert descriptor["registration_id"] == operation.id
    assert descriptor["version"] == 1

    assert descriptor["claim_url"] ==
             "https://salix.example.test/v1/compute/agent-vmm/registrations/claim"

    assert is_binary(descriptor["ticket"])
    assert response["agent_vmm_controls"]["items"] == []

    stored = Repo.get!(BridgeForTeams.Schema.MacMiniProvisioner, first["id"])
    refute inspect(stored) =~ descriptor["ticket"]
  end

  test "heartbeat acknowledges an exact terminal install report before redelivery", %{
    org: org,
    project: project,
    api_key: api_key
  } do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
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
          "agent_vmm_registration_failures" => [
            %{
              "registration_id" => operation.id,
              "failure_code" => "agent_vmm.install_failed"
            }
          ]
        }
      )

    assert response.status == 200
    body = Jason.decode!(response.resp_body)
    assert body["agent_vmm_registration_failure_acks"] == [operation.id]
    refute Map.has_key?(body, "agent_vmm_registration")

    assert {:ok, stored} =
             BridgeForTeams.Compute.get_agent_vmm_install(org, project, operation.id)

    assert stored.status == "action_required"
    assert stored.error_code == "agent_vmm.install_failed"
  end

  test "org API keys cannot operate another org provisioner route", %{api_key: api_key} do
    {:ok, other_org} =
      Orgs.create_org(%{
        "name" => "Other",
        "slug" => "other-#{SystemsRuntime.Proc.unique_integer([:positive])}"
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
