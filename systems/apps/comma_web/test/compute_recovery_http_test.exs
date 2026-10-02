defmodule CommaWeb.ComputeRecoveryHTTPTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Plug.Conn
  import Plug.Test
  alias SalixStore.{AgentVMMInstallations, Repo}
  alias SalixStore.AgentVMMInstallations.Operation

  setup do
    comma_owner = CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
    previous = Application.get_env(:salix_web, :public_base_url)

    previous_bindings =
      Application.get_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)

    Application.put_env(:salix_web, :public_base_url, "https://api.example.test")
    Application.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)

    Repo.query!(
      "TRUNCATE agent_vmm_install_operations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    on_exit(fn ->
      Application.put_env(:salix_web, :public_base_url, previous)

      Application.put_env(
        :salix_store,
        :agent_vmm_environment_scoped_bindings_enabled,
        previous_bindings
      )

      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
    end)

    :ok
  end

  test "a queued old HTTP mutation loses authority when the new Session consumes machine proof" do
    suffix = Ecto.UUID.generate()

    assert {:ok, user} =
             Comma.Accounts.create_user(%{"email" => "recovery-#{suffix}@example.test"})

    assert {:ok, old} = Comma.Accounts.create_session(user["id"])
    assert {:ok, new} = Comma.Accounts.create_session(user["id"])
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
        name: "Recovery",
        status: "active"
      })

    Comma.Repo.insert!(%Comma.Data.WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    path = "/v1/comma/workspaces/#{workspace.id}/compute-nodes/agent-vmm/install-operations"
    response = http(:post, path, old["token"], %{}, [{"idempotency-key", suffix}])
    assert response.status == 200
    descriptor = Jason.decode!(response.resp_body)["descriptor"]
    operation_id = descriptor["operation_id"]

    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      :crypto.generate_key(:ecdh, :secp256r1)

    identity = %{
      device_id: "host-#{suffix}",
      root_public_key: <<2 + Bitwise.band(:binary.last(y), 1), x::binary>>,
      root_key_revision: 1
    }

    assert {:ok, exchanged} =
             AgentVMMInstallations.exchange(
               operation_id,
               descriptor["one_time_secret"],
               identity,
               fn _, _ -> {:ok, %{"fixture" => true}} end
             )

    assert {:ok, original} =
             AgentVMMInstallations.acknowledge(
               operation_id,
               descriptor["one_time_secret"],
               exchanged.host_identity_digest
             )

    challenge_response = http(:post, "#{path}/#{operation_id}/recovery/challenge", new["token"])
    assert challenge_response.status == 200
    assert get_resp_header(challenge_response, "cache-control") == ["no-store"]
    challenge = Jason.decode!(challenge_response.resp_body)["recovery"]["challenge"]
    assert {:ok, wire} = SalixStore.AgentVMMRecovery.wire(challenge)
    proof = proof(identity, private, challenge["nonce"], wire)

    preview =
      http(:post, "#{path}/#{operation_id}/recovery/preview", new["token"], %{"proof" => proof})

    assert preview.status == 200
    assert Repo.get!(Operation, operation_id).delivery_target_id == old["id"]

    # An accepted exchange cannot be abandoned, even by the original account owner.
    assert http(:post, "#{path}/#{operation_id}/recovery/abandon", new["token"], %{
             "confirmed" => true
           }).status == 409

    unfinished =
      http(:post, path, old["token"], %{}, [{"idempotency-key", "unfinished-#{suffix}"}])

    unfinished_id = Jason.decode!(unfinished.resp_body)["descriptor"]["operation_id"]
    lookup = http(:get, "#{path}/requests/unfinished-#{suffix}", new["token"])
    assert lookup.status == 200

    assert Jason.decode!(lookup.resp_body)["operation"] == %{
             "id" => unfinished_id,
             "registration_id" => Repo.get!(Operation, unfinished_id).registration_id,
             "scope_key" => workspace.id,
             "authorization_status" => "requested"
           }

    assert Repo.get!(Operation, unfinished_id).delivery_target_id == old["id"]
    assert http(:get, "#{path}/requests/#{suffix}", new["token"]).status == 409
    assert http(:get, "#{path}/requests/not-this-request", new["token"]).status == 404
    assert http(:post, "#{path}/#{unfinished_id}/recovery/abandon", new["token"]).status == 400

    for _retry <- 1..2 do
      abandoned =
        http(:post, "#{path}/#{unfinished_id}/recovery/abandon", new["token"], %{
          "confirmed" => true
        })

      assert abandoned.status == 200
      assert Jason.decode!(abandoned.resp_body)["operation"]["authorization_status"] == "revoked"
    end

    assert Repo.get(
             SalixStore.AgentVMM.Registration,
             Repo.get!(Operation, unfinished_id).registration_id
           ) == nil

    binding =
      Repo.get_by!(SalixStore.Compute.ProviderBinding, provider_ref: original.registration_id)

    Repo.update_all(from(b in SalixStore.Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [status: "available"]
    )

    assert {:ok, allocation} =
             SalixStore.Compute.allocate(%{
               id: "allocation-#{suffix}",
               environment_id: original.environment_id,
               provider_binding_id: binding.id,
               generation: 1
             })

    assert {:ok, _workload} =
             SalixStore.Compute.create_workload(%{
               id: "workload-#{suffix}",
               environment_id: original.environment_id,
               allocation_id: allocation.id,
               generation: 1,
               kind: "shell",
               template_key: "shell.default"
             })

    resource_path = "/v1/comma/workspaces/#{workspace.id}/compute-nodes/agent-vmm"

    target = %{
      "registration_id" => original.registration_id,
      "allocation_id" => allocation.id,
      "generation" => "1"
    }

    valid_mapping =
      http(:post, "#{resource_path}/local-mappings", new["token"], %{"targets" => [target]})

    assert valid_mapping.status == 200

    assert [%{"can_read" => true, "can_operate" => false}] =
             Jason.decode!(valid_mapping.resp_body)["mappings"]

    for wrong <- [
          Map.put(target, "generation", "2"),
          Map.put(target, "registration_id", "another-registration")
        ] do
      assert Jason.decode!(
               http(:post, "#{resource_path}/local-mappings", new["token"], %{
                 "targets" => [wrong]
               }).resp_body
             )["mappings"] == []

      assert http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => wrong}).status ==
               404
    end

    work = http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => target})
    assert work.status == 200
    assert length(Jason.decode!(work.resp_body)["workloads"]) == 1
    assert [%{"phase" => "waiting_connection"}] = Jason.decode!(work.resp_body)["workloads"]

    Repo.update_all(from(b in SalixStore.Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [observation: %{"connection_epoch" => "invalid"}]
    )

    invalid_phase =
      http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => target})

    assert [%{"phase" => "action_required"}] = Jason.decode!(invalid_phase.resp_body)["workloads"]

    Repo.update_all(from(b in SalixStore.Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [observation: %{}]
    )

    assert {:ok, outsider} =
             Comma.Accounts.create_user(%{"email" => "outsider-#{suffix}@example.test"})

    assert {:ok, outsider_session} = Comma.Accounts.create_session(outsider["id"])

    denied =
      http(:post, "#{resource_path}/local-workloads", outsider_session["token"], %{
        "target" => target
      })

    assert denied.status == 403
    refute denied.resp_body =~ "workload-#{suffix}"

    parent = self()

    blocker =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(o in Operation, where: o.id == ^operation_id, lock: "FOR UPDATE"))
          send(parent, :locked)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :locked

    consume =
      Task.async(fn ->
        http(:post, "#{path}/#{operation_id}/recovery/consume", new["token"], %{"proof" => proof})
      end)

    wait_for_owner_waiters(1)

    old_mutation =
      Task.async(fn -> http(:post, "#{path}/#{operation_id}/disable", old["token"]) end)

    wait_for_owner_waiters(2)
    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker)
    assert Task.await(consume).status == 200
    stale = Task.await(old_mutation)
    assert stale.status == 409
    assert Jason.decode!(stale.resp_body)["error"] == "authorization_changed"
    recovered = Repo.get!(Operation, operation_id)
    assert recovered.delivery_target_id == new["id"]
    assert recovered.registration_id == original.registration_id
    assert recovered.environment_id == original.environment_id

    assert Repo.get!(SalixStore.AgentVMM.Registration, original.registration_id).status !=
             "revoked"

    assert http(:get, "#{path}/requests/unfinished-#{suffix}", outsider_session["token"]).status ==
             403

    assert http(:get, "#{path}/#{operation_id}", old["token"]).status == 404

    assert http(:post, "#{path}/#{operation_id}/recovery/consume", new["token"], %{
             "proof" => proof
           }).status == 409
  end

  defp wait_for_owner_waiters(expected, attempts \\ 100)
  defp wait_for_owner_waiters(_, 0), do: flunk("HTTP requests did not reach the owner row lock")

  defp wait_for_owner_waiters(expected, attempts) do
    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%agent_vmm_install_operations%FOR UPDATE%'"
      ).rows

    if count < expected do
      Process.sleep(10)
      wait_for_owner_waiters(expected, attempts - 1)
    end
  end

  defp http(method, path, token, body \\ %{}, headers \\ []) do
    connection =
      conn(method, path, Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("x-comma-session-transport", "bearer")

    Enum.reduce(headers, connection, fn {key, value}, current ->
      put_req_header(current, key, value)
    end)
    |> CommaWeb.Router.call(CommaWeb.Router.init([]))
  end

  defp proof(identity, private, nonce, wire) do
    <<0x30, _size, 0x02, r_size, rest::binary>> =
      :crypto.sign(:ecdsa, :sha256, wire, [private, :secp256r1])

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
