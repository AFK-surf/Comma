defmodule CommaWeb.ComputeRecoveryHTTPTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false
  import Ecto.Query
  import Plug.Conn
  import Plug.Test
  alias SalixStore.{AgentVMMInstallations, Repo}
  alias SalixStore.AgentVMMInstallations.Operation

  setup do
    comma_owner = CommaWeb.TestRepoSandbox.start_owner!(:multi_connection)
    previous = SystemsRuntime.get_env(:salix_web, :public_base_url)

    previous_bindings =
      SystemsRuntime.get_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled)

    SystemsRuntime.put_env(:salix_web, :public_base_url, "https://api.example.test")
    SystemsRuntime.put_env(:salix_store, :agent_vmm_environment_scoped_bindings_enabled, true)

    Repo.query!(
      "TRUNCATE agent_vmm_install_operations, compute_provider_bindings, compute_environments, compute_pools, agent_vmm_registrations CASCADE"
    )

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_web, :public_base_url, previous)

      SystemsRuntime.put_env(
        :salix_store,
        :agent_vmm_environment_scoped_bindings_enabled,
        previous_bindings
      )

      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
    end)

    :ok
  end

  test "a queued old HTTP mutation loses authority when the new Session consumes machine proof" do
    suffix = SystemsRuntime.Proc.uuid()

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
      SystemsRuntime.Proc.generate_key(:ecdh, :secp256r1)

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
             "authorization_status" => "requested",
             "registration_revocation_reason" => nil
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
      set: [status: "available", observation: %{"connection_epoch" => "7"}]
    )

    Repo.update_all(from(w in SalixStore.Compute.Workload, where: w.id == ^"workload-#{suffix}"),
      set: [observed_state: "ready"]
    )

    Repo.update_all(from(a in SalixStore.Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        status: "ready",
        provider_observation: %{
          "container_status" => "running",
          "runtime_verified_host_epoch" => "7"
        }
      ]
    )

    running_shell =
      http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => target})

    assert [%{"phase" => "ready"}] = Jason.decode!(running_shell.resp_body)["workloads"]

    Repo.update_all(from(b in SalixStore.Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [status: "unavailable"]
    )

    disconnected_shell =
      http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => target})

    assert [%{"phase" => "waiting_connection"}] =
             Jason.decode!(disconnected_shell.resp_body)["workloads"]

    # A bounded reconnect inventory may omit this allocation and retain its old facts.
    Repo.update_all(from(b in SalixStore.Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [
        status: "available",
        observation: %{"connection_epoch" => "8", "inventory_snapshot_bounded" => true}
      ]
    )

    stale_shell =
      http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => target})

    assert [%{"phase" => "starting"}] = Jason.decode!(stale_shell.resp_body)["workloads"]

    Repo.update_all(from(a in SalixStore.Compute.Allocation, where: a.id == ^allocation.id),
      set: [
        provider_observation: %{
          "container_status" => "running",
          "runtime_verified_host_epoch" => "8"
        }
      ]
    )

    refreshed_shell =
      http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => target})

    assert [%{"phase" => "ready"}] = Jason.decode!(refreshed_shell.resp_body)["workloads"]

    Repo.update_all(from(w in SalixStore.Compute.Workload, where: w.id == ^"workload-#{suffix}"),
      set: [observed_state: "pending"]
    )

    recovering_shell =
      http(:post, "#{resource_path}/local-workloads", new["token"], %{"target" => target})

    assert [%{"phase" => "starting", "observed_state" => "pending"}] =
             Jason.decode!(recovering_shell.resp_body)["workloads"]

    Repo.update_all(from(b in SalixStore.Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [status: "available", observation: %{}]
    )

    Repo.update_all(from(w in SalixStore.Compute.Workload, where: w.id == ^"workload-#{suffix}"),
      set: [observed_state: "pending"]
    )

    Repo.update_all(from(a in SalixStore.Compute.Allocation, where: a.id == ^allocation.id),
      set: [status: "pending", provider_observation: %{}]
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

    workload_path = "/v1/comma/workspaces/#{workspace.id}/compute/workloads/workload-#{suffix}"
    assert http(:get, workload_path, outsider_session["token"]).status == 403
    read = http(:get, workload_path, new["token"])
    assert read.status == 200
    assert Jason.decode!(read.resp_body)["workload"]["name"] == "Shell"

    assert Jason.decode!(read.resp_body)["workload"]["location"]["registration_id"] ==
             original.registration_id

    renamed =
      http(:patch, workload_path, new["token"], %{"name" => " Build Shell ", "revision" => 1})

    assert renamed.status == 200
    assert Jason.decode!(renamed.resp_body)["workload"]["name"] == "Build Shell"

    # The last rename wins; a stale revision does not reject it.
    late = http(:patch, workload_path, new["token"], %{"name" => "Late Shell", "revision" => 1})
    assert late.status == 200
    assert Jason.decode!(late.resp_body)["workload"]["name"] == "Late Shell"

    assert http(:patch, workload_path, new["token"], %{"name" => ""}).status == 400

    assert Jason.decode!(http(:get, workload_path, new["token"]).resp_body)["workload"]["name"] ==
             "Late Shell"

    assert http(:post, "#{workload_path}/retry", outsider_session["token"], %{
             "revision" => 2,
             "generation" => 1
           }).status == 403

    Repo.update_all(from(w in SalixStore.Compute.Workload, where: w.id == ^"workload-#{suffix}"),
      set: [observed_state: "failed"]
    )

    # A command with an unknown outcome blocks neither retry nor deletion, and is never replayed.
    assert {:ok, unknown} =
             SalixStore.Compute.enqueue_command(%{
               id: "unknown-#{suffix}",
               allocation_id: allocation.id,
               workload_id: "workload-#{suffix}",
               request_id: "unknown-#{suffix}",
               kind: "runtime.exec",
               classification: "side_effecting",
               target_generation: 1,
               target_revision: allocation.revision,
               deadline_at: DateTime.add(SystemsClock.utc_now(), 60, :second),
               payload: %{}
             })

    unknown_started_at = SystemsClock.utc_now()

    Repo.update_all(from(c in SalixStore.Compute.Command, where: c.id == ^unknown.id),
      set: [status: "unknown_outcome", delivery_started_at: unknown_started_at]
    )

    # Retry is fenced by generation only; the stale revision 1 is ignored.
    retried =
      http(:post, "#{workload_path}/retry", new["token"], %{
        "revision" => 1,
        "generation" => 1
      })

    assert retried.status == 202
    assert Jason.decode!(retried.resp_body)["workload"]["id"] == "workload-#{suffix}"
    assert Jason.decode!(retried.resp_body)["workload"]["revision"] == 4

    assert Repo.get!(SalixStore.Compute.Workload, "workload-#{suffix}").allocation_id ==
             allocation.id

    assert http(:post, "#{workload_path}/retry", new["token"], %{"generation" => 2}).status ==
             409

    assert http(:post, "#{workload_path}/deletion", outsider_session["token"], %{
             "request_id" => "delete",
             "revision" => 3,
             "generation" => 1
           }).status == 403

    assert http(:post, "#{workload_path}/deletion", new["token"], %{
             "request_id" => "delete",
             "generation" => 2
           }).status == 409

    deletion =
      http(:post, "#{workload_path}/deletion", new["token"], %{
        "request_id" => "delete",
        "revision" => 1,
        "generation" => 1
      })

    assert deletion.status == 202
    assert Jason.decode!(deletion.resp_body)["workload"]["phase"] == "deleting"

    assert http(:post, "#{workload_path}/deletion", new["token"], %{
             "request_id" => "delete",
             "revision" => 3,
             "generation" => 1
           }).status == 202

    assert Jason.decode!(http(:get, workload_path, new["token"]).resp_body)["workload"][
             "deletion"
           ]["request_id"] == "delete"

    Repo.update_all(from(a in SalixStore.Compute.Allocation, where: a.id == ^allocation.id),
      set: [status: "ready", provider_observation: %{"allocation_revision" => 7}]
    )

    assert {:ok, %{command: disposal}} =
             SalixStore.ComputeWorkloadDeletion.advance(
               SalixStore.Repo.get!(SalixStore.Compute.Allocation, allocation.id),
               SalixStore.Repo.get!(SalixStore.Compute.Workload, "workload-#{suffix}")
             )

    assert disposal.kind == "allocation.dispose"
    unknown = Repo.get!(SalixStore.Compute.Command, unknown.id)
    assert unknown.status == "unknown_outcome"
    assert unknown.delivery_started_at == unknown_started_at
    waiting = Jason.decode!(http(:get, workload_path, new["token"]).resp_body)["workload"]
    assert waiting["phase"] == "waiting_connection"
    assert waiting["deletion"]["error"] == "original_device_offline"
    assert waiting["actions"]["delete"] == false
    assert disposal.allocation_id == allocation.id

    creation_path = "/v1/comma/workspaces/#{workspace.id}/compute/workloads"

    creation_attrs = %{
      "environment_id" => original.environment_id,
      "kind" => "shell",
      "name" => "Named Shell",
      "request_id" => "named-#{suffix}"
    }

    created = http(:post, creation_path, new["token"], creation_attrs)
    assert created.status == 201
    same = http(:post, creation_path, new["token"], creation_attrs)
    assert same.status == 201

    assert Jason.decode!(same.resp_body)["workload"]["id"] ==
             Jason.decode!(created.resp_body)["workload"]["id"]

    assert http(:post, creation_path, new["token"], Map.put(creation_attrs, "name", "different")).status ==
             409

    created_id = Jason.decode!(created.resp_body)["workload"]["id"]
    now = SystemsClock.utc_now()

    Repo.insert_all(
      SalixStore.Compute.ExternalWorkerBinding,
      for index <- 1..33 do
        %{
          id: "binding-use-#{suffix}-#{index}",
          tenant_id: original.tenant_id,
          agent_id: "agent-#{index}",
          source_kind: "compute_workload",
          workload_id: created_id,
          status: "active",
          binding_revision: 1,
          runtime_spec: %{},
          created_at: now,
          updated_at: now
        }
      end
    )

    details = http(:get, "#{creation_path}/#{created_id}", new["token"])
    assert details.status == 200
    detail = Jason.decode!(details.resp_body)["workload"]
    assert detail["runtime_policy"]["image"] =~ "comma.local/runtime/shell@"
    assert detail["runtime_policy"]["entrypoint"] == []
    assert detail["runtime_policy"]["resources"]["pid_max"] == 512
    refute Map.has_key?(detail["runtime_policy"], "env")
    assert length(detail["uses"]) == 32
    assert detail["uses_truncated"]
    assert Enum.all?(detail["uses"], &(&1["kind"] == "agent"))
    refute detail["actions"]["delete"]
    assert http(:get, "#{creation_path}/#{created_id}", outsider_session["token"]).status == 403

    # A retired External Worker's leftover bindings neither own nor block its Workload.
    Repo.update_all(from(w in SalixStore.Compute.Workload, where: w.id == ^created_id),
      set: [kind: "external_worker", template_key: "external.codex"]
    )

    retired =
      Jason.decode!(http(:get, "#{creation_path}/#{created_id}", new["token"]).resp_body)[
        "workload"
      ]

    assert retired["uses"] == []
    assert retired["owner"] == nil
    assert retired["actions"]["delete"]

    parent = SystemsRuntime.Proc.self()

    blocker =
      SystemsRuntime.Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(from(o in Operation, where: o.id == ^operation_id, lock: "FOR UPDATE"))
          SystemsRuntime.Proc.send(parent, :locked)
          SystemsRuntime.Proc.receive(do: (:release -> :ok))
        end)
      end)

    assert_receive :locked

    consume =
      SystemsRuntime.Task.async(fn ->
        http(:post, "#{path}/#{operation_id}/recovery/consume", new["token"], %{"proof" => proof})
      end)

    wait_for_owner_waiters(1)

    old_mutation =
      SystemsRuntime.Task.async(fn ->
        http(:post, "#{path}/#{operation_id}/disable", old["token"])
      end)

    wait_for_owner_waiters(2)
    SystemsRuntime.Proc.send(blocker.pid, :release)
    assert {:ok, :ok} = SystemsRuntime.Task.await(blocker, :infinity)
    assert SystemsRuntime.Task.await(consume, :infinity).status == 200
    stale = SystemsRuntime.Task.await(old_mutation, :infinity)
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

    current = http(:get, "#{path}/#{operation_id}", new["token"])
    assert Jason.decode!(current.resp_body)["operation"]["registration_revocation_reason"] == nil

    # Expiry of the 7-day authorization is the one reason the client reinstalls on its own.
    assert {:ok, _} =
             SalixStore.AgentVMM.expire_authorizations(
               32,
               DateTime.add(SystemsClock.utc_now(), 8 * 86_400, :second)
             )

    expired = http(:get, "#{path}/#{operation_id}", new["token"])

    assert Jason.decode!(expired.resp_body)["operation"]["registration_revocation_reason"] ==
             "authorization_expired"
  end

  defp wait_for_owner_waiters(expected, attempts \\ 3000)
  defp wait_for_owner_waiters(_, 0), do: flunk("HTTP requests did not reach the owner row lock")

  defp wait_for_owner_waiters(expected, attempts) do
    [[count]] =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%agent_vmm_install_operations%FOR UPDATE%'"
      ).rows

    if count < expected do
      SystemsRuntime.Proc.sleep(10)
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
