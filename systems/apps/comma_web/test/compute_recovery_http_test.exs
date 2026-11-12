defmodule CommaWeb.ComputeRecoveryHTTPTest do
  use SystemsClock.Case, async: false
  import Ecto.Query
  import Plug.Conn
  import Plug.Test
  alias SalixStore.{AgentVMM, Repo}

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
    SystemsRuntime.Test.put_env(:salix_web, :public_base_url, "https://api.example.test")

    SystemsRuntime.Test.put_env(
      :salix_store,
      :agent_vmm_connection_config,
      SalixStore.AgentVMMConnectionConfigFixtures.catalog()
    )

    Repo.query!(
      "TRUNCATE compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(owner) end)
    :ok
  end

  test "current same-subject login manages the same Registration and root proof replaces an expired credential" do
    {user, old, workspace} = owner_fixture()
    {:ok, new} = Comma.Accounts.create_session(user["id"])
    path = "/v1/comma/workspaces/#{workspace.id}/compute-nodes/agent-vmm/registrations"
    created = http(:post, path, old["token"], %{}, [{"idempotency-key", "first"}])
    assert created.status == 200
    body = Jason.decode!(created.resp_body)
    id = body["registration"]["id"]
    assert body["descriptor"]["registration_id"] == id

    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      SystemsRuntime.Proc.generate_key(:ecdh, :secp256r1)

    identity = %{
      device_id: "host",
      root_public_key: <<2 + Bitwise.band(:binary.last(y), 1), x::binary>>,
      root_key_revision: 1
    }

    credential = String.duplicate("a", 43)

    claim_body = %{
      version: 1,
      registration_id: id,
      device_id: identity.device_id,
      root_public_key: Base.encode64(identity.root_public_key),
      root_key_revision: 1,
      candidate_credential: Base.encode64(credential)
    }

    claim = claim_http(claim_body, "RegistrationTicket " <> body["descriptor"]["ticket"])
    assert claim.status == 200

    assert Jason.decode!(claim.resp_body)["remote_connection"]["gateway_endpoint"] ==
             "vmm.example.test:7443"

    assert :ok = AgentVMM.authenticate_registration(id, credential)
    assert http(:get, "#{path}/#{id}", new["token"]).status == 200
    assert http(:post, "#{path}/#{id}/disable", new["token"]).status == 200

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^id),
      set: [authorization_expires_at: DateTime.add(SystemsClock.utc_now(), -1, :second)]
    )

    replacement = String.duplicate("b", 43)

    challenge =
      http(:post, "#{path}/#{id}/recovery/challenge", new["token"], %{
        candidate_credential_hash: Base.encode64(:crypto.hash(:sha256, replacement))
      })

    assert challenge.status == 200
    c = Jason.decode!(challenge.resp_body)["challenge"]
    {:ok, wire} = SalixStore.AgentVMMRecovery.wire(c)
    signed = proof(identity, private, c["nonce"], wire)
    recovery_body = %{proof: signed, candidate_credential: Base.encode64(replacement)}
    recovered = http(:post, "#{path}/#{id}/recovery", new["token"], recovery_body)
    assert recovered.status == 200
    assert get_resp_header(recovered, "cache-control") == ["no-store"]
    assert Jason.decode!(recovered.resp_body)["registration_id"] == id
    assert :ok = AgentVMM.authenticate_registration(id, replacement)
    assert {:error, :unauthorized} = AgentVMM.authenticate_registration(id, credential)
    refute Repo.get!(AgentVMM.Registration, id).desired_enabled
    assert http(:post, "#{path}/#{id}/recovery", new["token"], recovery_body).status == 200
    assert http(:post, "#{path}/#{id}/revoke", old["token"]).status == 200
    assert http(:post, "#{path}/#{id}/recovery", new["token"], recovery_body).status != 200
  end

  test "claim rejects wrong schemes, changed candidates and oversized bodies before changing authorization" do
    {_user, session, workspace} = owner_fixture()
    path = "/v1/comma/workspaces/#{workspace.id}/compute-nodes/agent-vmm/registrations"
    created = http(:post, path, session["token"], %{}, [{"idempotency-key", "bounded"}])
    d = Jason.decode!(created.resp_body)["descriptor"]

    request = %{
      version: 1,
      registration_id: d["registration_id"],
      device_id: "host",
      root_public_key: Base.encode64(<<2, 0::256>>),
      root_key_revision: 1,
      candidate_credential: Base.encode64(String.duplicate("g", 43))
    }

    assert claim_http(request, "Bearer " <> d["ticket"]).status == 401
    assert claim_http(request, "RegistrationTicket wrong-ticket").status == 401

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      conn(:post, "/v1/compute/agent-vmm/registrations/claim", String.duplicate("x", 17_000))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "RegistrationTicket " <> d["ticket"])
      |> SalixWeb.Router.call(SalixWeb.Router.init([]))
    end

    assert is_nil(Repo.get!(AgentVMM.Registration, d["registration_id"]).credential_hash)
    assert claim_http(request, "RegistrationTicket " <> d["ticket"]).status == 200

    assert claim_http(
             %{request | candidate_credential: Base.encode64(String.duplicate("h", 43))},
             "RegistrationTicket " <> d["ticket"]
           ).status == 409
  end

  test "cancel before authorization creates one revoked Registration and closes the late request" do
    {_user, session, workspace} = owner_fixture()
    path = "/v1/comma/workspaces/#{workspace.id}/compute-nodes/agent-vmm/registrations"
    cancel = http(:post, path <> "/requests/lost-response/cancel", session["token"])
    assert cancel.status == 200, cancel.resp_body
    registration = Jason.decode!(cancel.resp_body)["registration"]
    assert registration["status"] == "removed"
    assert registration["host_bound"] == false
    late = http(:post, path, session["token"], %{}, [{"idempotency-key", "lost-response"}])
    assert late.status == 200, late.resp_body
    assert Jason.decode!(late.resp_body)["registration"]["id"] == registration["id"]
    assert Jason.decode!(late.resp_body)["descriptor"] == nil
    repeated = http(:post, path <> "/requests/lost-response/cancel", session["token"])
    assert repeated.status == 200
    assert Jason.decode!(repeated.resp_body)["registration"]["id"] == registration["id"]
    assert Repo.aggregate(AgentVMM.Registration, :count) == 1
    assert Repo.aggregate(SalixStore.Compute.ProviderBinding, :count) == 0
    assert Repo.aggregate(SalixStore.Compute.Workload, :count) == 0
  end

  test "unknown allocation storage failure stays parked until public Retry creates one exact new attempt" do
    {session, workspace, registration, workload, allocation} = pending_shell_fixture()
    provider = SalixEnv.ComputeProviders.AgentVMM
    assert {:ok, %{command: initial}} = provider.reconcile(allocation, workload)
    assert {:ok, admitted} = AgentVMM.claim_registration_command(registration.id, "gateway", "1")
    assert admitted.id == initial.id

    evidence = %{
      "result" => %{
        "reason" => "ERROR_REASON_UNAVAILABLE",
        "outcome" => "COMMAND_OUTCOME_UNKNOWN",
        "capacityDimension" => "CAPACITY_DIMENSION_STORAGE_HEADROOM",
        "allocation" => %{
          "allocationId" => allocation.id,
          "revision" => "1",
          "generation" => "1",
          "state" => "ALLOCATION_STATE_DRAINING"
        }
      }
    }

    assert :ok =
             AgentVMM.commit_registration_result(
               registration.id,
               "gateway",
               "1",
               admitted.id,
               "unknown_outcome",
               evidence
             )

    claim = Repo.get_by!(SalixStore.Compute.ReconcilerClaim, workload_id: workload.id)
    assert claim.last_error["kind"] == "action_required"
    assert claim.last_error["resource"] == "storage_headroom"
    assert is_nil(claim.next_retry_at)

    assert {:error, {:gateway_error, %{"resource" => "storage_headroom"}}} =
             provider.reconcile(Repo.get!(SalixStore.Compute.Allocation, allocation.id), workload)

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_DRAINING"
                 }
               ]
             })

    remove_station_fixture()
    current = Repo.get!(SalixStore.Compute.Allocation, allocation.id)
    assert current.status == "allocating"
    assert current.operation_outcome == "pending"
    for _ <- 1..2, do: SalixEnv.ComputeReconciler.sweep(32)

    assert Repo.aggregate(
             from(c in SalixStore.Compute.Command, where: c.workload_id == ^workload.id),
             :count
           ) == 1

    assert Repo.get_by!(SalixStore.Compute.ReconcilerClaim, workload_id: workload.id).attempt_count ==
             claim.attempt_count

    detail_path = "/v1/comma/workspaces/#{workspace.id}/compute/workloads/#{workload.id}"
    detail = http(:get, detail_path, session["token"])
    assert detail.status == 200, detail.resp_body
    assert Jason.decode!(detail.resp_body)["workload"]["phase"] == "action_required"

    assert Jason.decode!(detail.resp_body)["workload"]["problem"]["code"] ==
             "capacity_unavailable"

    # A changed egress intent cannot reuse the admitted allocation's limits.
    Repo.update_all(from(w in SalixStore.Compute.Workload, where: w.id == ^workload.id),
      set: [spec: Map.put(workload.spec, "egress_mode", "deny_all")]
    )

    refused = http(:post, detail_path <> "/retry", session["token"], %{generation: 1})
    assert refused.status == 409, refused.resp_body
    assert Repo.get!(SalixStore.Compute.Allocation, allocation.id).revision == current.revision
    assert Repo.get!(SalixStore.Compute.Command, initial.id).evidence == evidence

    Repo.update_all(from(w in SalixStore.Compute.Workload, where: w.id == ^workload.id),
      set: [spec: workload.spec]
    )

    retried = http(:post, detail_path <> "/retry", session["token"], %{generation: 1})
    assert retried.status == 202, retried.resp_body
    after_retry = Repo.get!(SalixStore.Compute.Allocation, allocation.id)
    assert after_retry.revision == current.revision + 1
    assert after_retry.generation == allocation.generation
    assert http(:post, detail_path <> "/retry", session["token"], %{generation: 1}).status == 202

    assert Repo.get!(SalixStore.Compute.Allocation, allocation.id).revision ==
             after_retry.revision

    assert {:ok, %{command: next}} =
             provider.reconcile(after_retry, Repo.get!(SalixStore.Compute.Workload, workload.id))

    assert next.id != initial.id
    assert next.request_id != initial.request_id

    assert next.payload["command_json"]["ensureAllocation"] ==
             initial.payload["command_json"]["ensureAllocation"]

    previous = Repo.get!(SalixStore.Compute.Command, initial.id)
    assert previous.status == "unknown_outcome"
    assert previous.evidence == evidence

    assert {:ok, claimed} = AgentVMM.claim_registration_command(registration.id, "gateway", "2")
    assert claimed.id == next.id

    assert :ok =
             AgentVMM.commit_registration_result(
               registration.id,
               "gateway",
               "2",
               next.id,
               "succeeded",
               %{
                 "result" => %{
                   "allocation" => %{
                     "allocationId" => allocation.id,
                     "revision" => "1",
                     "generation" => "1",
                     "state" => "ALLOCATION_STATE_READY"
                   }
                 }
               }
             )

    assert Repo.get!(SalixStore.Compute.Allocation, allocation.id).status == "ready"
    assert Repo.get!(SalixStore.Compute.Command, initial.id).evidence == evidence
  end

  test "Host DRAINING cannot create release intent and public Retry cannot reverse an accepted release" do
    {session, workspace, registration, workload, allocation} = pending_shell_fixture()

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "2",
               "inventoryWatermark" => 1,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_DRAINING"
                 }
               ]
             })

    assert Repo.get!(SalixStore.Compute.Allocation, allocation.id).status == "allocating"

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "3",
               "inventoryWatermark" => 2,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert Repo.get!(SalixStore.Compute.Allocation, allocation.id).status == "ready"
    assert {:ok, _} = SalixStore.Compute.stop_workload(workload.id, workload.revision, "owner")

    release =
      Repo.get_by!(SalixStore.Compute.Command,
        allocation_id: allocation.id,
        kind: "allocation.release"
      )

    assert {:ok, :ok} =
             AgentVMM.observe_registration(registration.id, "gateway", %{
               "connectionEpoch" => "4",
               "inventoryWatermark" => 3,
               "inventory" => [
                 %{
                   "allocationId" => allocation.id,
                   "revision" => "1",
                   "state" => "ALLOCATION_STATE_READY"
                 }
               ]
             })

    assert Repo.get!(SalixStore.Compute.Allocation, allocation.id).status == "draining"
    path = "/v1/comma/workspaces/#{workspace.id}/compute/workloads/#{workload.id}/retry"
    refused = http(:post, path, session["token"], %{generation: 1})
    assert refused.status == 409, refused.resp_body
    assert Repo.get!(SalixStore.Compute.Command, release.id).kind == "allocation.release"
  end

  defp pending_shell_fixture do
    {_user, session, workspace} = owner_fixture()
    path = "/v1/comma/workspaces/#{workspace.id}/compute-nodes/agent-vmm/registrations"
    created = http(:post, path, session["token"], %{}, [{"idempotency-key", "capacity"}])
    assert created.status == 200, created.resp_body
    d = Jason.decode!(created.resp_body)["descriptor"]

    claimed =
      claim_http(
        %{
          version: 1,
          registration_id: d["registration_id"],
          device_id: "capacity-host",
          root_public_key: Base.encode64(<<2, 1::256>>),
          root_key_revision: 1,
          candidate_credential: Base.encode64(String.duplicate("k", 43))
        },
        "RegistrationTicket " <> d["ticket"]
      )

    assert claimed.status == 200, claimed.resp_body

    assert {:ok, :ok} =
             AgentVMM.observe_registration(d["registration_id"], "gateway", %{
               "connectionEpoch" => "1",
               "inventoryWatermark" => 0,
               "inventory" => []
             })

    r = Repo.get!(AgentVMM.Registration, d["registration_id"])
    w = Repo.get!(SalixStore.Compute.Workload, r.initial_workload_id)
    a = Repo.get!(SalixStore.Compute.Allocation, w.allocation_id)

    remove_station_fixture()
    {session, workspace, r, w, a}
  end

  defp remove_station_fixture do
    # This test drives the initial Shell only. Group Station placement has its
    # own owner and must not add unrelated commands to this Host script.
    for station <-
          Repo.all(
            from(other in SalixStore.Compute.Workload,
              where: other.template_key == "station.default",
              limit: 32
            )
          ) do
      Repo.delete!(station)
      Repo.delete!(Repo.get!(SalixStore.Compute.Allocation, station.allocation_id))
    end
  end

  defp owner_fixture do
    suffix = SystemsRuntime.Proc.uuid()
    {:ok, user} = Comma.Accounts.create_user(%{"email" => "registration-#{suffix}@example.test"})
    {:ok, session} = Comma.Accounts.create_session(user["id"])
    tenant = SalixStore.Ids.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    workspace =
      Comma.Repo.insert!(%Comma.Data.Workspace{
        id: "wsp_#{suffix}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "1",
        salix_router_agent_id: SalixStore.Ids.new_agent_id(group),
        salix_worker_agent_id: SalixStore.Ids.new_agent_id(group),
        billing_owner_id: "billing-#{suffix}",
        name: "Registration",
        status: "active"
      })

    Comma.Repo.insert!(%Comma.Data.WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    {user, session, workspace}
  end

  defp http(method, path, token, body \\ %{}, headers \\ []) do
    connection =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("x-comma-session-transport", "bearer")

    Enum.reduce(headers, connection, fn {key, value}, current ->
      put_req_header(current, key, value)
    end)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp claim_http(body, authorization) do
    conn(:post, "/v1/compute/agent-vmm/registrations/claim", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", authorization)
    |> SalixWeb.Router.call(SalixWeb.Router.init([]))
  end

  defp proof(identity, private, nonce, wire) do
    <<0x30, _size, 0x02, r_size, rest::binary>> =
      SystemsRuntime.Proc.sign(:ecdsa, :sha256, wire, [private, :secp256r1])

    <<r::binary-size(^r_size), 0x02, s_size, s::binary-size(s_size)>> = rest
    r = :binary.decode_unsigned(r)
    s = :binary.decode_unsigned(s)
    order = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

    signature =
      <<r::unsigned-big-integer-size(256), min(s, order - s)::unsigned-big-integer-size(256)>>

    %{
      "nonce" => nonce,
      "signature" => Base.encode64(signature),
      "device_id" => identity.device_id,
      "root_public_key" => Base.encode64(identity.root_public_key),
      "root_key_revision" => 1
    }
  end
end
