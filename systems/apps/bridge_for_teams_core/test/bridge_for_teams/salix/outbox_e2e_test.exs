defmodule BridgeForTeams.Salix.OutboxE2ETest do
  @moduledoc """
  End-to-end coverage of the BridgeForTeams → Salix reconcile outbox: a real
  domain mutation (via the contexts) enqueues outbox row(s), draining them with
  `Reconciler.drain_once/0` invokes the real Salix erpc boundary with arguments
  derived from the actual domain data, writes Salix control-plane records, and
  the rows end up `done`.

  This closes the loop the unit suites only cover in halves — context tests
  assert rows are *enqueued*; the reconciler test drives *synthetic* payloads.
  Here we verify the full chain with live records.

  async: false — these tests reset Salix's process-shared S3 fake backend and
  temporarily override Salix node discovery.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Agents, Environments, Orgs, ProjectIMConnects, Projects, Repo}
  alias BridgeForTeams.Salix.{Reconciler, TenantConfigChecker}
  alias BridgeForTeams.Schema.{ProjectDeviceProjection, ReconcileOutbox}
  alias SalixStore.RuntimeIds

  setup do
    SalixStore.S3.Fake.reset()
    prev_salix_vm = Application.get_env(:bridge_for_teams_core, :salix_vm)

    on_exit(fn ->
      Application.delete_env(:bridge_for_teams_core, :salix_nodes_override)
      restore_env(:bridge_for_teams_core, :salix_vm, prev_salix_vm)
    end)

    :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp drain_all do
    # Drain repeatedly until quiescent (each call claims one batch).
    case Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _} -> drain_all()
    end
  end

  defp statuses do
    Repo.all(ReconcileOutbox) |> Enum.map(& &1.status) |> Enum.uniq()
  end

  test "direct online rollout rejects early canonical writes and resumes bounded handoff" do
    {org, project, owned} = audit_fixture()

    legacy =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(
        org.salix_tenant_id,
        project.salix_group_id,
        %{"role" => "worker", "name" => "Old native Worker"}
      )

    SalixStore.Repo.query!(
      "DELETE FROM salix_cutover_markers WHERE name = 'agent_configuration_writers_v1'"
    )

    on_exit(fn ->
      :ok = SalixStore.AgentConfigurationRollout.open()
      :ok = SalixStore.AgentConfigurationRollout.complete()
    end)

    assert {:error, :agent_configuration_rollout_pending} =
             Agents.update_agent(owned, %{"name" => "Must not be acknowledged"})

    assert {:error, :agent_configuration_rollout_pending} =
             Agents.transfer_configuration(legacy["agent_id"])

    assert {:error, :agent_configuration_rollout_pending} =
             SalixAgent.Control.create(
               %{"group_id" => project.salix_group_id, "role" => "worker"},
               org.salix_tenant_id
             )

    assert {:error, :agent_configuration_rollout_pending} =
             SalixAgent.Control.archive_permanently(owned.salix_agent_id, org.salix_tenant_id)

    # Read and message admission stay usable while management is unavailable.
    assert {:ok, current} = SalixAgent.Control.get(owned.salix_agent_id)
    assert current["name"] == "Worker"

    assert {:ok, _} =
             SalixAgent.deliver(
               owned.salix_agent_id,
               %{
                 "session_id" => SalixStore.Ids.new_session_id(),
                 "role" => "user",
                 "content" => "Online handoff admission test"
               },
               source_message_id: "handoff-ordinary-message"
             )

    # A retained old-wire write still runs before the rollout boundary; its
    # current value, never the old BFT snapshot, must survive transfer.
    assert {:ok, _} =
             SalixAgent.Control.update(
               legacy["agent_id"],
               %{"name" => "Last old write"},
               org.salix_tenant_id
             )

    assert {:ok, :blocked} = SalixStore.AgentConfigurationRollout.state()

    # The release runner publishes only after core success. A page is bounded
    # and independently retryable; the existing native inventory includes rows
    # absent from the BFT association table.
    :ok = SalixStore.AgentConfigurationRollout.open()

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(BridgeForTeams.Schema.Agent, owned.id),
        configuration_authority: "legacy"
      )
    )

    Repo.update_all(from(r in ReconcileOutbox, where: r.aggregate_id == ^owned.id),
      set: [status: "pending"]
    )

    assert {:error, {:agent_transfer_failed, failed_id, :drain_agent_configuration_outbox}} =
             BridgeForTeams.Agents.ConfigurationTransfer.page(nil)

    assert failed_id == owned.id
    assert {:ok, :ready} = SalixStore.AgentConfigurationRollout.state()
    assert {:ok, _} = SalixAgent.Control.get(owned.salix_agent_id)
    drain_all()
    assert {:ok, first} = release_transfer_page(nil)
    assert first.processed <= 20
    assert {:ok, replay} = release_transfer_page(nil)
    assert replay == first
    finish_transfer_pages(first.next_cursor)
    assert {:ok, :complete} = SalixStore.AgentConfigurationRollout.state()

    assert {:ok, _} = Agents.update_agent(owned, %{"name" => "Canonical after rollout"})

    assert {:ok, %{"name" => "Last old write", "configuration_authority" => "salix"}} =
             SalixAgent.Control.get(legacy["agent_id"])

    assert {:error, :configuration_authority_transferred} =
             SalixAgent.Control.update(
               legacy["agent_id"],
               %{"name" => "Delayed stale request"},
               org.salix_tenant_id
             )

    assert {:ok, _} =
             SalixAgent.Control.create(
               %{"group_id" => project.salix_group_id, "role" => "worker"},
               org.salix_tenant_id
             )
  end

  defp release_transfer_page(cursor) do
    encoded = if cursor, do: cursor |> Jason.encode!() |> Base.encode64()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        :ok = Comma.Release.transfer_agent_configuration_page(encoded)
      end)

    line =
      output
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "COMMA_AGENT_TRANSFER_RESULT:"))

    summary = line |> String.replace_prefix("COMMA_AGENT_TRANSFER_RESULT:", "") |> Jason.decode!()

    next =
      if summary["next_cursor"], do: summary["next_cursor"] |> Base.decode64!() |> Jason.decode!()

    {:ok, %{processed: summary["processed"], next_cursor: next}}
  end

  defp finish_transfer_pages(nil), do: :ok

  defp finish_transfer_pages(cursor) do
    assert {:ok, page} = release_transfer_page(cursor)
    assert page.processed <= 20
    finish_transfer_pages(page.next_cursor)
  end

  test "authority transfer drains old obligations and fences delayed configuration" do
    {:ok, org} = Orgs.create_org(%{"name" => "Authority", "slug" => "authority"})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Authority", "slug" => "authority"})

    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "Before", "role" => "worker"})
    # Representative pre-rollout row and immutable legacy outbox command.
    Repo.update!(
      Ecto.Changeset.change(Repo.get!(BridgeForTeams.Schema.Agent, agent.id),
        configuration_authority: "legacy"
      )
    )

    {:ok, legacy_id} = Ecto.UUID.dump(agent.id)
    Repo.query!("UPDATE agents SET name = 'Before' WHERE id = $1", [legacy_id])

    assert {:error, :agent_configuration_transfer_required} =
             Agents.update_agent(agent, %{"name" => "Blocked legacy write"})

    Repo.update_all(from(r in ReconcileOutbox, where: r.aggregate_id == ^agent.id),
      set: [op: "create_agent"]
    )

    assert {:error, :drain_agent_configuration_outbox} = Agents.transfer_configuration(agent.id)
    drain_all()
    # Older product Groups may predate the billing-owner metadata. Absence is
    # not permission for a second writer; the explicit transfer fills the scope.
    group_key = SalixStore.Keys.ctl_group(project.salix_group_id)
    {:ok, %{body: body, etag: etag}} = SalixStore.S3.get(group_key)
    group = body |> Jason.decode!() |> Map.delete("billing_owner")
    {:ok, _} = SalixStore.S3.put(group_key, Jason.encode!(group), if_match: etag)

    assert {:error, :agent_configuration_transfer_required} =
             SalixAgent.Control.configure(
               agent.salix_agent_id,
               %{"name" => "Premature"},
               org.salix_tenant_id
             )

    assert {:ok, transferred} = Agents.transfer_configuration(agent.id)
    assert transferred.configuration_authority == "salix"
    assert {:ok, _} = Agents.transfer_configuration(agent.id)

    count = Repo.aggregate(ReconcileOutbox, :count)

    assert {:ok, updated} =
             Agents.update_agent(agent, %{
               "name" => "Canonical",
               "system_prompt" => "Current instructions"
             })

    assert updated.salix["name"] == "Canonical"
    assert {:ok, canonical} = SalixAgent.Control.get(agent.salix_agent_id)
    assert updated.salix == canonical
    assert Repo.get!(BridgeForTeams.Schema.Agent, agent.id).salix == %{}
    assert Repo.aggregate(ReconcileOutbox, :count) == count
    assert Repo.query!("SELECT name FROM agents WHERE id = $1", [legacy_id]).rows == [["Before"]]
    assert is_nil(Repo.get!(BridgeForTeams.Schema.Agent, agent.id).salix["name"])
    assert {:ok, %{salix: %{"name" => "Canonical"}}} = Agents.get_agent(agent.id)

    assert {:error, :configuration_authority_transferred} =
             SalixAgent.Control.update(
               agent.salix_agent_id,
               %{"system_prompt" => "Stale instructions"},
               org.salix_tenant_id
             )

    assert {:ok, %{"name" => "Canonical", "system_prompt" => "Current instructions"}} =
             SalixAgent.Control.get(agent.salix_agent_id)
  end

  test "an unacknowledged claim freezes BFT writes and resumes without restoring the old snapshot" do
    {:ok, org} = Orgs.create_org(%{"name" => "Claim retry", "slug" => "claim-retry"})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Claim retry", "slug" => "claim-retry"})

    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "Old", "role" => "worker"})
    drain_all()

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(BridgeForTeams.Schema.Agent, agent.id),
        configuration_authority: "moving"
      )
    )

    Repo.query!(
      "UPDATE agents SET name = $1 WHERE id = $2",
      ["Stale product name", Ecto.UUID.dump!(agent.id)]
    )

    assert {:error, :agent_configuration_transfer_in_progress} =
             Agents.update_agent(agent, %{"name" => "Blocked"})

    assert {:error, :agent_configuration_transfer_in_progress} = Agents.archive_agent(agent)

    assert {:ok, _} =
             SalixAgent.Control.configure(
               agent.salix_agent_id,
               %{"name" => "Changed after claim"},
               org.salix_tenant_id
             )

    assert {:ok, %{configuration_authority: "salix"}} = Agents.transfer_configuration(agent.id)
    assert {:ok, %{salix: %{"name" => "Changed after claim"}}} = Agents.get_agent(agent.id)

    assert %{rows: [["Stale product name"]]} =
             Repo.query!("SELECT name FROM agents WHERE id = $1", [Ecto.UUID.dump!(agent.id)])
  end

  test "transfer preserves a legacy soft archive and canonical restore ignores its old BFT shadow" do
    {:ok, org} = Orgs.create_org(%{"name" => "Archive transfer", "slug" => "archive-transfer"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Archive", "slug" => "archive"})
    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "Archived", "role" => "worker"})

    Repo.update_all(from(r in ReconcileOutbox, where: r.aggregate_id == ^agent.id),
      set: [op: "create_agent"]
    )

    drain_all()
    archived_at = DateTime.utc_now()

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(BridgeForTeams.Schema.Agent, agent.id),
        configuration_authority: "legacy"
      )
    )

    {:ok, legacy_id} = Ecto.UUID.dump(agent.id)

    Repo.query!("UPDATE agents SET status = 'archived', archived_at = $1 WHERE id = $2", [
      DateTime.to_naive(archived_at),
      legacy_id
    ])

    assert {:ok, _} = Agents.transfer_configuration(agent.id)
    assert {:ok, %{salix: %{"archived_at" => actual_archive}}} = Agents.get_agent(agent.id)
    assert actual_archive == DateTime.to_unix(archived_at)
    assert {:error, :not_found} = Agents.get_project_agent(project.id, agent.id)
    assert {:ok, _} = SalixAgent.Control.unarchive(agent.salix_agent_id, org.salix_tenant_id)

    assert {:ok, restored} = Agents.get_project_agent(project.id, agent.id)
    refute Map.has_key?(restored.salix, "archived_at")
  end

  defp audit_fixture do
    n = System.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Transfer fixture", "slug" => "transfer-#{n}"})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Transfer", "slug" => "transfer"})

    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "Worker", "role" => "worker"})
    drain_all()
    {org, project, agent}
  end

  test "BFT audits its own writes while Router commands stay inside Salix" do
    {:ok, org} = Orgs.create_org(%{"name" => "Audit boundary", "slug" => "audit-boundary"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Audit", "slug" => "audit"})
    {:ok, agent} = Agents.create_agent(project.id, %{"name" => "Worker", "role" => "worker"})
    drain_all()
    {:ok, router} = Agents.current_router(project)
    {:ok, record} = SalixAgent.Control.get(router.salix_agent_id)

    ctx = %{
      agent_id: router.salix_agent_id,
      session_id: record["router_session_id"],
      tool_call_id: "rename"
    }

    count = Repo.aggregate(BridgeForTeams.Schema.AuditLog, :count)

    assert {:ok, _} =
             SalixAgent.AgentManagement.run(
               :update,
               %{"agent_id" => agent.salix_agent_id, "name" => "Router change"},
               ctx
             )

    assert Repo.aggregate(BridgeForTeams.Schema.AuditLog, :count) == count

    assert {:ok, _} =
             Agents.update_agent(agent, %{"name" => "Product change"},
               actor_label: "owner@example.test"
             )

    assert [audit] =
             BridgeForTeams.Observability.list_audit_logs(org.id,
               action: "agent.config_updated",
               result: "ok"
             )

    assert audit.actor_label == "owner@example.test"
    assert audit.redacted_diff["name"] == %{"from" => "Router change", "to" => "Product change"}
  end

  test "operator native inventory transfers Salix-only legacy Workers without inventing a BFT owner" do
    {org, project, _owned} = audit_fixture()

    legacy =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(
        org.salix_tenant_id,
        project.salix_group_id,
        %{"role" => "worker", "name" => "Legacy Salix Worker"}
      )

    id = legacy["agent_id"]
    count = Repo.aggregate(BridgeForTeams.Schema.Agent, :count)
    assert {:ok, page} = Agents.page_agents(project, limit: 50)
    assert Enum.any?(page.items, &(&1.id == id))
    assert Repo.aggregate(BridgeForTeams.Schema.Agent, :count) == count
    assert {:ok, ref} = Agents.get_project_agent(project.id, id)

    assert {:error, :agent_configuration_transfer_required} =
             Agents.update_agent(ref, %{"name" => "Premature"})

    assert {:error, :not_found} =
             Agents.get_project_agent(
               project.id,
               SalixStore.Ids.new_agent_id(project.salix_group_id)
             )

    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    Mix.Tasks.BridgeForTeams.Agents.TransferConfiguration.run([
      "--project",
      project.id,
      "--limit",
      "50"
    ])

    assert_receive {:mix_shell, :info, [json]}
    result = Jason.decode!(json)
    assert Enum.find(result["results"], &(&1["salix_agent_id"] == id))["needs_transfer"]
    assert Repo.aggregate(BridgeForTeams.Schema.Agent, :count) == count
    Mix.Tasks.BridgeForTeams.Agents.TransferConfiguration.run(["--apply", "--agent", id])
    assert_receive {:mix_shell, :info, [applied]}

    assert [%{"authority" => "salix", "needs_transfer" => false}] =
             Jason.decode!(applied)["results"]

    assert {:ok, %{"name" => "Legacy Salix Worker", "configuration_authority" => "salix"}} =
             SalixAgent.Control.get(id)

    assert Repo.aggregate(BridgeForTeams.Schema.Agent, :count) == count

    assert {:ok, _} =
             SalixAgent.Control.configure(
               id,
               %{"name" => "Canonical update"},
               org.salix_tenant_id
             )
  end

  test "legacy archive key presence stays archived even without a timestamp" do
    {_org, project, agent} = audit_fixture()

    assert {:ok, _} =
             SalixStore.CasRecord.update(
               SalixStore.Keys.ctl_agent(agent.salix_agent_id),
               &Map.put(&1, "archived_at", nil)
             )

    assert {:ok, %{salix: %{"archived_at" => nil}}} = Agents.get_agent(agent.id)
    assert {:error, :not_found} = Agents.get_project_agent(project.id, agent.id)
    assert {:error, :agent_archived} = Agents.update_agent(agent, %{"name" => "Must not change"})
  end

  test "legacy Salix-owned Workers in a BFT Group remain manageable without product adoption" do
    {:ok, org} = Orgs.create_org(%{"name" => "Legacy Workers", "slug" => "legacy-workers"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Legacy", "slug" => "legacy"})
    drain_all()
    router = Repo.get_by!(BridgeForTeams.Schema.Agent, project_id: project.id, role: "router")
    {:ok, record} = SalixAgent.Control.get(router.salix_agent_id)

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        org.salix_tenant_id,
        project.salix_group_id,
        %{"name" => "Legacy Worker"}
      )

    id = worker["agent_id"]
    assert {:ok, _} = SalixAgent.Control.claim_configuration(id, org.salix_tenant_id)

    ctx = %{
      agent_id: record["agent_id"],
      session_id: record["router_session_id"],
      tool_call_id: "legacy-update"
    }

    product_count = Repo.aggregate(BridgeForTeams.Schema.Agent, :count)

    assert {:ok, %{"agent" => detail}} =
             SalixAgent.AgentManagement.run(:get, %{"agent_id" => id}, ctx)

    assert detail["agent_id"] == id

    assert {:ok, updated} =
             SalixAgent.AgentManagement.run(
               :update,
               %{"agent_id" => id, "name" => "Named legacy Worker", "purpose" => "Existing work"},
               ctx
             )

    assert updated["agent"]["name"] == "Named legacy Worker"

    assert {:ok, renamed} =
             SalixAgent.Control.configure(
               id,
               %{"name" => "Dashboard rename"},
               org.salix_tenant_id
             )

    assert renamed["name"] == "Dashboard rename"

    assert {:ok, archived} =
             SalixAgent.AgentManagement.run(
               :archive,
               %{"agent_id" => id, "user_confirmed" => true},
               ctx
             )

    assert archived["agent"]["permanent"]
    assert Repo.aggregate(BridgeForTeams.Schema.Agent, :count) == product_count
    refute Repo.get_by(BridgeForTeams.Schema.Agent, salix_agent_id: id)
    assert {:ok, %{"name" => "Dashboard rename"}} = SalixAgent.Control.get_record(id)
  end

  test "Router and dashboard metadata converge through the Salix owner, then archive is permanent" do
    {:ok, template} =
      SalixAgent.Templates.create(%{
        "name" => "Product Worker",
        "model" => "worker-model",
        "provider" => "mock"
      })

    {:ok, org} = Orgs.create_org(%{"name" => "Management", "slug" => "management"})
    org = Repo.update!(Ecto.Changeset.change(org, default_template_id: template["template_id"]))
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Managed", "slug" => "managed"})
    drain_all()
    router = Repo.get_by!(BridgeForTeams.Schema.Agent, project_id: project.id, role: "router")
    {:ok, router_record} = SalixAgent.Control.get(router.salix_agent_id)

    ctx = %{
      agent_id: router.salix_agent_id,
      session_id: router_record["router_session_id"],
      tool_call_id: "create-reviewer"
    }

    input = %{
      "name" => "Reviewer",
      "purpose" => "Initial",
      "creation_reason" => "This test needs an independent Worker",
      "runtime" => %{"kind" => "internal"}
    }

    assert {:ok, created} = SalixAgent.AgentManagement.run(:create, input, ctx)
    assert created["result"] == "applied"
    assert created["agent"]["name"] == "Reviewer"
    id = created["agent"]["agent_id"]
    refute Repo.get_by(BridgeForTeams.Schema.Agent, salix_agent_id: id)
    assert {:ok, product_agent} = Agents.get_project_agent(project.id, id)
    assert product_agent.project_id == project.id
    assert product_agent.salix["template_id"] == template["template_id"]

    assert {:ok, replayed} = SalixAgent.AgentManagement.run(:create, input, ctx)
    assert replayed["replayed"]
    assert replayed["agent"]["agent_id"] == id
    drain_all()

    assert {:ok, %{"agent" => detail}} =
             SalixAgent.AgentManagement.run(:get, %{"agent_id" => id}, ctx)

    assert detail["model"]["model_id"] == "worker-model"

    assert {:ok, accepted} =
             SalixAgent.AgentManagement.run(:update, %{"agent_id" => id, "name" => "A"}, %{
               ctx
               | tool_call_id: "rename-A"
             })

    assert accepted["result"] == "applied"
    # A stale dashboard struct submits a patch to the canonical owner.
    assert {:ok, _newer} =
             Agents.update_agent(product_agent, %{"name" => "B", "purpose" => "Backend"})

    assert Repo.get!(BridgeForTeams.Schema.Agent, product_agent.id).salix["name"] == nil
    assert {:ok, after_b} = SalixAgent.Control.get(id)

    assert Map.take(after_b, ~w(name management_purpose)) == %{
             "name" => "B",
             "management_purpose" => "Backend"
           }

    drain_all()
    assert {:ok, ^after_b} = SalixAgent.Control.get(id)

    assert {:ok, archive} =
             SalixAgent.AgentManagement.run(
               :archive,
               %{"agent_id" => id, "user_confirmed" => true},
               ctx
             )

    assert archive["agent"]["lifecycle"] == "archived"

    assert {:error, :agent_archived} =
             Agents.update_agent(product_agent, %{"name" => "stale writer"})

    assert {:error, :not_found} = Agents.archive_agent(product_agent)
    drain_all()

    assert {:ok, %{"agent" => archived}} =
             SalixAgent.AgentManagement.run(:get, %{"agent_id" => id}, ctx)

    assert archived["permanent"]

    assert {:ok, %{"agent" => archived}} =
             SalixAgent.AgentManagement.run(:get, %{"agent_id" => id}, ctx)

    assert archived["lifecycle"] == "archived"

    assert {:error, :agent_permanently_archived} =
             SalixAgent.Control.unarchive(id, org.salix_tenant_id)
  end

  test "disclosed Compute targets create and rebind a BFT Worker without provisioning resources" do
    {:ok, org} =
      Orgs.create_org(%{"name" => "Compute Management", "slug" => "compute-management"})

    {:ok, project} = Projects.create_project(org.id, %{"name" => "Compute", "slug" => "compute"})
    drain_all()
    router = Repo.get_by!(BridgeForTeams.Schema.Agent, project_id: project.id, role: "router")
    {:ok, record} = SalixAgent.Control.get(router.salix_agent_id)

    ctx =
      %{
        agent_id: record["agent_id"],
        session_id: record["router_session_id"],
        role: "router",
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    ctx =
      Map.put(
        ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize("router", :internal, ctx)
      )

    prefix = "management-#{System.unique_integer([:positive])}"

    first =
      SalixStore.TestSupport.ExternalWorkerTargetFixture.create(
        prefix <> "-a",
        project.id,
        project.salix_group_id,
        "codex",
        org.salix_tenant_id
      )

    second =
      SalixStore.TestSupport.ExternalWorkerTargetFixture.add_workload(first, prefix <> "-b", "pi")

    counts = compute_counts()

    [item] =
      management_tool!(
        "env.runtime_targets",
        %{"kind" => "compute", "provider" => "codex"},
        ctx,
        "targets-a"
      )["items"]

    assert item["selectable"]
    assert item["target"]["workload_id"] == first.workload.id

    create_args = %{
      "name" => "Compute reviewer",
      "purpose" => "Execute the test responsibility",
      "creation_reason" => "This test needs an independent Worker",
      "runtime" => item["target"]
    }

    created = management_tool!("agent.create_worker", create_args, ctx, "create-compute")
    assert created["result"] == "applied"
    id = created["agent"]["agent_id"]
    drain_all()
    detail = management_tool!("agent.get", %{"agent_id" => id}, ctx, "get-created")["agent"]

    assert detail["runtime"] == %{
             "kind" => "compute",
             "provider" => "codex",
             "workload_id" => first.workload.id
           }

    assert management_tool!("agent.create_worker", create_args, ctx, "create-compute")["agent"][
             "agent_id"
           ] == id

    [next] =
      management_tool!(
        "env.runtime_targets",
        %{"kind" => "compute", "provider" => "pi"},
        ctx,
        "targets-b"
      )["items"]

    rebind_args = %{
      "agent_id" => id,
      "target" => next["target"],
      "expected_binding_revision" => detail["binding_revision"]
    }

    rebound = management_tool!("agent.rebind_runtime", rebind_args, ctx, "rebind-compute")
    assert rebound["result"] == "applied"
    assert rebound["agent"]["runtime"]["workload_id"] == second.workload.id
    drain_all()
    detail = management_tool!("agent.get", %{"agent_id" => id}, ctx, "get-rebound")["agent"]
    assert detail["runtime"]["workload_id"] == second.workload.id

    [conflict] =
      SalixAgent.Tools.execute(
        [%{"id" => "stale-decision", "name" => "agent.rebind_runtime", "args" => rebind_args}],
        ctx
      )

    assert conflict.error
    assert conflict.content =~ "binding_conflict"
    assert compute_counts() == counts
  end

  defp compute_counts do
    for schema <- [
          SalixStore.Compute.Environment,
          SalixStore.Compute.Allocation,
          SalixStore.Compute.Workload,
          SalixStore.Compute.ExternalWorkerOperation
        ],
        do: SalixStore.Repo.aggregate(schema, :count)
  end

  defp management_tool!(name, args, ctx, id) do
    [result] = SalixAgent.Tools.execute([%{"id" => id, "name" => name, "args" => args}], ctx)
    refute result.error, inspect(result)
    Jason.decode!(result.content)
  end

  defp eventually(fun, retries \\ 100)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, retries) do
    case fun.() do
      nil ->
        Process.sleep(20)
        eventually(fun, retries - 1)

      false ->
        Process.sleep(20)
        eventually(fun, retries - 1)

      value ->
        value
    end
  end

  test "org creation reconciles a Salix tenant and its conversation link config" do
    vm_config = %{
      "default_provider" => "cloudflare",
      "providers" => %{
        "cloudflare" => %{
          "enabled" => true,
          "gateway_base_url" => "https://salix-vm-gateway-staging.example.workers.dev",
          "gateway_secret" => "gateway-secret"
        }
      }
    }

    Application.put_env(:bridge_for_teams_core, :salix_vm, vm_config)

    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})

    assert {:ok, 2} = Reconciler.drain_once()

    assert {:ok, %{"tenant_id" => tenant_id, "name" => "Acme"}} =
             Salix.Control.Tenants.get(org.salix_tenant_id)

    assert SalixStore.Ids.valid_tenant_id?(tenant_id)

    base_url =
      :bridge_for_teams_web
      |> Application.fetch_env!(:public_base_url)
      |> String.trim_trailing("/")

    assert {:ok, %{"conversation_url_template" => template}} =
             Salix.Control.Tenants.get_config(org.salix_tenant_id, "conversation_links", %{})

    assert template ==
             base_url <>
               "/tasks/{tenant_id}/{group_id}/{conversation_id}"

    assert {:ok, %{}} = Salix.Control.Tenants.get_config(org.salix_tenant_id, "vm", %{})

    assert statuses() == ["done"]
  end

  test "tenant config checker asynchronously repairs an existing tenant template" do
    vm_config = %{
      "default_provider" => "cloudflare",
      "providers" => %{
        "cloudflare" => %{
          "enabled" => true,
          "gateway_base_url" => "https://salix-vm-gateway-staging.example.workers.dev",
          "gateway_secret" => "gateway-secret"
        }
      }
    }

    Application.put_env(:bridge_for_teams_core, :salix_vm, vm_config)

    {:ok, org} = Orgs.create_org(%{"name" => "Checker", "slug" => "checker"})

    assert {:ok, 1} = Reconciler.drain_once(limit: 1)

    assert {:ok, %{}} =
             Salix.Control.Tenants.get_config(org.salix_tenant_id, "conversation_links", %{})

    assert {:ok, %{}} = Salix.Control.Tenants.get_config(org.salix_tenant_id, "vm", %{})

    start_supervised!(
      {TenantConfigChecker,
       enabled: true, initial_delay_ms: 1, interval_ms: 60_000, retry_interval_ms: 20}
    )

    template =
      eventually(fn ->
        case Salix.Control.Tenants.get_config(org.salix_tenant_id, "conversation_links", %{}) do
          {:ok, %{"conversation_url_template" => value}} when is_binary(value) and value != "" ->
            value

          _other ->
            nil
        end
      end)

    base_url =
      :bridge_for_teams_web
      |> Application.fetch_env!(:public_base_url)
      |> String.trim_trailing("/")

    assert template ==
             base_url <>
               "/tasks/{tenant_id}/{group_id}/{conversation_id}"

    assert {:ok, %{}} = Salix.Control.Tenants.get_config(org.salix_tenant_id, "vm", %{})

    assert %{status: "ok"} = TenantConfigChecker.status()
  end

  test "project creation reconciles a Salix group with its default router" do
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})
    assert Agents.list_agents(project.id) == []

    association =
      Repo.get_by!(BridgeForTeams.Schema.Agent, project_id: project.id, role: "router")

    assert {:ok, %{provisioning: "provisioning"}} = Agents.get_agent(association.id)

    drain_all()
    [router] = Agents.list_agents(project.id)

    assert {:ok,
            %{
              "group_id" => group_id,
              "tenant_id" => tenant_id,
              "name" => "Billing",
              "router_agent_id" => router_agent_id
            }} =
             Salix.Control.Groups.get(project.salix_group_id)

    assert group_id == project.salix_group_id
    assert SalixStore.Ids.valid_group_id_for_tenant?(group_id, tenant_id)
    assert tenant_id == org.salix_tenant_id
    assert router_agent_id == router.salix_agent_id

    assert {:ok, attrs} =
             SalixAgent.Control.get(router.salix_agent_id, org.salix_tenant_id)

    assert attrs["role"] == "router"
    assert attrs["group_id"] == project.salix_group_id
    assert statuses() == ["done"]
  end

  test "project Slack connect creates and deletes a group-scoped Salix connect" do
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Billing", "slug" => "billing"})

    # The Salix group must exist before the connect can be created.
    drain_all()

    assert {:ok, connect} =
             ProjectIMConnects.create_project_connect(org.id, project.id, "slack", %{
               "app_name" => "Comma",
               "app_id" => "A0E2E",
               "client_id" => "cid",
               "client_secret" => "csecret",
               "signing_secret" => "ssecret"
             })

    assert connect["provider"] == "slack"
    assert connect["group_id"] == project.salix_group_id
    assert connect["client_secret_configured"] == true
    assert connect["signing_secret_configured"] == true
    # Slack connects expose an install URL to finish the OAuth flow.
    assert is_binary(connect["oauth_url"])

    install_scopes =
      connect["oauth_url"]
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("scope")
      |> String.split(",")

    assert "files:read" in install_scopes
    assert "files:write" in install_scopes

    assert {:ok, [listed]} =
             SalixIM.ProviderConnects.list_group_im_connects(project.salix_group_id, "slack")

    assert listed["connect_id"] == connect["connect_id"]

    # Deleting the project connect removes it from the group-scoped listing.
    assert {:ok, _} =
             ProjectIMConnects.delete_project_connect(org.id, project.id, connect["connect_id"])

    assert {:ok, []} =
             SalixIM.ProviderConnects.list_group_im_connects(project.salix_group_id, "slack")

    # No reconcile rows are produced by the synchronous provider-connect path.
    assert statuses() in [["done"], []]
  end

  test "agent creation reconciles its template under tenant and group" do
    {:ok, template} =
      SalixAgent.Templates.create(%{
        "name" => "Creation",
        "provider" => "mock",
        "model" => "claude-x"
      })

    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})

    {:ok, agent} =
      Agents.create_agent(project.id, %{
        "role" => "router",
        "name" => "Router",
        "template_id" => template["template_id"]
      })

    drain_all()

    # The control-plane agent is provisioned under the org's tenant + project's
    # group, keyed by the agent's salix id.
    assert {:ok, attrs} =
             SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)

    assert attrs["agent_id"] == agent.salix_agent_id
    assert attrs["group_id"] == project.salix_group_id
    assert attrs["tenant_id"] == org.salix_tenant_id
    assert attrs["role"] == "router"
    assert attrs["template_id"] == template["template_id"]

    assert {:ok, _state} = SalixAgent.get_state(agent.salix_agent_id)

    assert statuses() == ["done"]
  end

  test "project VM default uses Salix platform Cloudflare provider without explicit provider" do
    {:ok, _} =
      SalixWeb.CloudVM.put_default_vm_config(%{
        "default_provider" => "cloudflare",
        "providers" => %{"cloudflare" => %{"enabled" => true}}
      })

    {:ok, org} = Orgs.create_org(%{"name" => "CloudVM", "slug" => "cloudvm"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})

    drain_all()

    router_agent = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    assert {:ok, router} =
             SalixAgent.Control.get(router_agent.salix_agent_id, org.salix_tenant_id)

    assert router["vm"]["enabled"] == true
    assert router["vm"]["provider"] == "cloudflare"

    assert {:ok, %{"billing_owner" => %{"vm_profile_key" => "cf-standard-2"}}} =
             Salix.Control.Groups.get(project.salix_group_id)

    assert {:error, :not_found} =
             SalixWeb.ComputeProviders.Cloudflare.get_record(project.salix_group_id)

    assert statuses() == ["done"]
  end

  test "external Codex agent creation reconciles runtime_config into Salix" do
    {:ok, org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})
    drain_all()

    device_id = SalixStore.Ids.new_device_id()
    runtime_id = "runtime-codex"
    device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
    checked_at = System.system_time(:millisecond)

    {:ok, _transport_id, env} =
      SalixEnv.Registry.connect("nonode@nohost", %{
        "tenant_id" => org.salix_tenant_id,
        "group_id" => project.salix_group_id,
        "device_id" => device_id,
        "connector_id" => "connector-#{System.unique_integer([:positive])}",
        "name" => "Mac Studio",
        "agent_runtimes" => [
          %{
            "kind" => "external",
            "provider" => "codex",
            "runtime_id" => runtime_id,
            "device_runtime_id" => device_runtime_id,
            "status" => "ready",
            "command" => "/usr/local/bin/codex",
            "version" => "codex-cli test",
            "version_detected" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "ready" => true,
            "readiness_checked_at" => checked_at,
            "readiness_valid_until" => checked_at + 60_000
          }
        ]
      })

    refresh_device_projection(project.id, device_id)

    runtime_config = %{
      "kind" => "external",
      "provider" => "codex",
      "device_id" => device_id,
      "runtime_id" => runtime_id,
      "device_runtime_id" => device_runtime_id
    }

    {:ok, agent} =
      Agents.create_agent(project.id, %{
        "role" => "worker",
        "name" => "codex-worker",
        "runtime_config" => runtime_config
      })

    # Salix agent control stores stable runtime binding facts. It must not reject
    # create_agent just because the live connector run disconnected between BFT's
    # product-side validation and asynchronous outbox reconcile.
    assert {:ok, %{"status" => "disconnected"}} =
             SalixEnv.Registry.mark_disconnected(env["connector_run_id"])

    drain_all()

    assert {:ok, attrs} =
             SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)

    assert attrs["role"] == "worker"
    assert attrs["runtime_config"] == runtime_config
    assert statuses() == ["done"]
  end

  test "canonical Connected worker creation accepts the complete initial binding atomically" do
    {:ok, org} = Orgs.create_org(%{"name" => "Canonical", "slug" => "canonical"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "P", "slug" => "p"})
    drain_all()

    device_id = SalixStore.Ids.new_device_id()
    runtime_id = "runtime-codex"
    device_runtime_id = RuntimeIds.device_runtime_id(device_id, "codex", runtime_id)
    checked_at = System.system_time(:millisecond)

    {:ok, _transport_id, _env} =
      SalixEnv.Registry.connect("nonode@nohost", %{
        "tenant_id" => org.salix_tenant_id,
        "group_id" => project.salix_group_id,
        "device_id" => device_id,
        "connector_id" => "connector-#{System.unique_integer([:positive])}",
        "agent_runtimes" => [
          %{
            "kind" => "external",
            "provider" => "codex",
            "runtime_id" => runtime_id,
            "device_runtime_id" => device_runtime_id,
            "status" => "ready",
            "command" => "/usr/local/bin/codex",
            "version" => "codex-cli test",
            "version_detected" => true,
            "auth_ready" => true,
            "native_server_startable" => true,
            "ready" => true,
            "readiness_checked_at" => checked_at,
            "readiness_valid_until" => checked_at + 60_000
          }
        ]
      })

    refresh_device_projection(project.id, device_id)

    assert {:ok, agent} =
             Agents.create_external_agent(
               project,
               %{"name" => "canonical-worker"},
               %{
                 "kind" => "connected_runtime",
                 "device_runtime_id" => device_runtime_id
               }
             )

    create_row =
      Repo.get_by!(ReconcileOutbox,
        aggregate: "agent",
        aggregate_id: agent.id,
        op: "create_owned_agent"
      )

    assert create_row.payload["attrs"]["runtime_config"] == agent.salix["runtime_config"]
    refute Map.has_key?(create_row.payload, "external_binding")
    refute Repo.get!(BridgeForTeams.Schema.Agent, agent.id).salix["runtime_config"]

    drain_all()

    assert {:ok, attrs} = SalixAgent.Control.get(agent.salix_agent_id, org.salix_tenant_id)
    assert attrs["runtime_config"] == agent.salix["runtime_config"]
    assert attrs["runtime_config"]["binding_revision"] == 1

    assert attrs["runtime_config"]["owner_scope"] == %{
             "type" => "group",
             "id" => project.salix_group_id
           }
  end

  defp refresh_device_projection(project_id, device_id, attempts \\ 20)

  defp refresh_device_projection(_project_id, _device_id, 0),
    do: flunk("device projection did not converge")

  defp refresh_device_projection(project_id, device_id, attempts) do
    assert {:ok, _result} =
             Environments.reconcile_device_projection(projection_page_limit: 100)

    if Repo.get_by(ProjectDeviceProjection, project_id: project_id, device_id: device_id) do
      :ok
    else
      refresh_device_projection(project_id, device_id, attempts - 1)
    end
  end

  test "a permanent client error marks the row failed and bumps attempts" do
    {:ok, _} =
      Reconciler.enqueue("project", "missing_group", "update_group", %{
        "group_id" => "missing_group",
        "tenant_id" => "missing_tenant",
        "attrs" => %{"name" => "Nope"}
      })

    assert {:ok, 1} = Reconciler.drain_once()

    row = Repo.one(from(r in ReconcileOutbox, where: r.op == "update_group"))
    assert row.status == "failed"
    assert row.attempts == 1
    assert row.last_error =~ "not_found"
  end

  test "a transient client error defers the row for retry (stays pending)" do
    {:ok, _org} = Orgs.create_org(%{"name" => "Acme", "slug" => "acme"})
    # :unavailable / :timeout are transient — the row is deferred, not failed.
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [])

    assert {:ok, 0} = Reconciler.drain_once()

    row = Repo.one(from(r in ReconcileOutbox, where: r.op == "create_tenant"))
    assert row.status == "pending"
    assert row.attempts == 1
    assert row.last_error =~ "transient"
  end
end
