defmodule SalixAgent.AgentManagementTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.{AgentManagement, Control}

  alias SalixAgent.Migrations.{
    GroupCloudVMSwitch,
    RetireExternalRuntimeConfig,
    StationBoundWorkers
  }

  alias SalixAgent.StationBinding
  alias SalixStore.{Ids, Keys, RuntimeIds, S3}

  @runtime %{"kind" => "runtime", "provider" => "claude", "model" => "claude-fable-5-1"}

  # A Group that may have a Cloud VM (its placement decides where). Turning
  # a bound Worker's VM on reads no Tenant provider configuration.
  defmodule UnaskedVM do
    @moduledoc false
    @behaviour SalixAgent.CloudVM
    def validate_group_enabled(_tenant_id, _group_id), do: raise("the VM provider was asked")
    defdelegate ensure_provisioning(agent), to: SalixAgent.CloudVM.None
    defdelegate mark_agent_settled(agent_id), to: SalixAgent.CloudVM.None
    defdelegate start(agent_id, worker_id, budget_ms), to: SalixAgent.CloudVM.None
  end

  setup do
    old_ports = SystemsRuntime.get_env(:salix_agent, :agent_management_ports)

    SystemsRuntime.put_env(
      :salix_agent,
      :agent_management_ports,
      AgentManagement.Ports.Standalone
    )

    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{"role" => "router"})

    SalixAgent.TestSupport.configure_platform_tier!(
      "worker",
      "https://platform-model.example.test/v1",
      "worker-model"
    )

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if old_ports,
        do: SystemsRuntime.put_env(:salix_agent, :agent_management_ports, old_ports),
        else: SystemsRuntime.delete_env(:salix_agent, :agent_management_ports)
    end)

    %{
      tenant: tenant,
      group: group,
      router: router,
      ctx: %{
        agent_id: router["agent_id"],
        session_id: router["router_session_id"],
        tool_call_id: "create-1"
      }
    }
  end

  test "create and exact get expose the Worker's platform default, and replay keeps its identity",
       ctx do
    input = %{
      "name" => "  Reviewer  ",
      "purpose" => "Backend review",
      "creation_reason" => "This test needs an independent Worker",
      "runtime" => %{"kind" => "internal"}
    }

    assert {:ok, first} = AgentManagement.run(:create, input, ctx.ctx)
    assert first["result"] == "applied"
    id = first["agent"]["agent_id"]
    assert first["agent"]["name"] == "Reviewer"
    assert first["agent"]["model"]["source"] == "platform_default"
    # It runs the Worker tier's model, not the Router's.
    assert {:ok, llm} = SalixAgent.AgentModel.resolve_llm_for_agent(id)
    assert llm["model"] == "worker-model"
    assert {:ok, second} = AgentManagement.run(:create, input, ctx.ctx)
    assert second["replayed"]
    assert second["agent"]["agent_id"] == id

    assert {:error, %{"code" => "invocation_conflict"}} =
             AgentManagement.run(:create, Map.put(input, "name", "Different request"), ctx.ctx)

    assert {:ok, %{"agent" => details}} = AgentManagement.run(:get, %{"agent_id" => id}, ctx.ctx)
    assert details == second["agent"]
    assert {:ok, %{"items" => [%{"agent_id" => ^id}]}} = AgentManagement.run(:list, %{}, ctx.ctx)
  end

  test "creation audit survives purpose changes and replay; legacy reasons stay unknown", ctx do
    input = %{
      "name" => "Reviewer",
      "purpose" => "Review backend changes",
      "creation_reason" => "The user requested independent review",
      "runtime" => %{"kind" => "internal"}
    }

    assert {:ok, first} = AgentManagement.run(:create, input, ctx.ctx)
    id = first["agent"]["agent_id"]
    audit = first["agent"]["creation_audit"]

    assert audit == %{
             "kind" => "router_tool",
             "reason" => input["creation_reason"],
             "router_agent_id" => ctx.router["agent_id"],
             "session_id" => ctx.ctx.session_id,
             "tool_call_id" => ctx.ctx.tool_call_id
           }

    assert {:ok, stored} = Control.get_record(id)
    assert stored["management_creation_audit"] == audit

    assert {:ok, changed} =
             AgentManagement.run(
               :update,
               %{"agent_id" => id, "purpose" => "Review security changes"},
               ctx.ctx
             )

    assert changed["agent"]["creation_audit"] == audit
    assert {:ok, replay} = AgentManagement.run(:create, input, ctx.ctx)
    assert replay["agent"]["purpose"] == "Review security changes"
    assert replay["agent"]["creation_audit"] == audit

    assert {:error, %{"code" => "invocation_conflict"}} =
             AgentManagement.run(
               :create,
               Map.put(input, "creation_reason", "Different reason"),
               ctx.ctx
             )

    legacy = SalixAgent.TestSupport.create_control_agent_in_group!(ctx.tenant, ctx.group)

    assert {:ok, %{"agent" => details}} =
             AgentManagement.run(:get, %{"agent_id" => legacy["agent_id"]}, ctx.ctx)

    assert details["purpose"] == ""
    assert details["creation_audit"] == nil
  end

  test "domain Worker survives Router session rotation without undoing owner changes", ctx do
    input = %{
      "name" => "Preparation",
      "purpose" => "Meeting research",
      "runtime" => %{"kind" => "internal"}
    }

    assert {:ok, first} =
             AgentManagement.ensure_owned_worker("meeting-preparation", input, ctx.ctx)

    id = first["agent"]["agent_id"]

    assert {:ok, _} =
             AgentManagement.run(:update, %{"agent_id" => id, "name" => "Owner rename"}, ctx.ctx)

    rotated = %{ctx.ctx | session_id: "another-router-session", tool_call_id: "another-call"}

    assert {:ok, second} =
             AgentManagement.ensure_owned_worker("meeting-preparation", input, rotated)

    assert second["agent"]["agent_id"] == id
    assert second["agent"]["name"] == "Owner rename"

    assert second["agent"]["creation_audit"] == %{
             "kind" => "domain",
             "owner_key" => "meeting-preparation",
             "router_agent_id" => ctx.router["agent_id"]
           }

    assert {:ok, %{"items" => [%{"agent_id" => ^id}]}} = AgentManagement.run(:list, %{}, rotated)

    assert {:ok, _} =
             AgentManagement.run(:archive, %{"agent_id" => id, "user_confirmed" => true}, rotated)

    assert {:error, _} =
             AgentManagement.ensure_owned_worker("meeting-preparation", input, rotated)

    assert {:ok, %{"items" => [%{"agent_id" => ^id}]}} =
             AgentManagement.run(:list, %{"lifecycle" => "all"}, rotated)
  end

  test "editable purpose remains descriptive even when it matches an internal policy purpose",
       ctx do
    {:ok, created} =
      AgentManagement.run(
        :create,
        %{
          "name" => "Description",
          "purpose" => "comma_recommendation",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"}
        },
        ctx.ctx
      )

    id = created["agent"]["agent_id"]
    assert created["agent"]["purpose"] == "comma_recommendation"
    {:ok, stored} = Control.get(id)
    assert stored["purpose"] == ""
    assert stored["management_purpose"] == "comma_recommendation"
    assert SalixAgent.AgentRuntimeConfig.from_control(stored)[:purpose] == ""

    assert {:ok, changed} =
             AgentManagement.run(:update, %{"agent_id" => id, "purpose" => "Backend review"}, %{
               ctx.ctx
               | tool_call_id: "change-purpose"
             })

    assert changed["agent"]["purpose"] == "Backend review"
    {:ok, stored} = Control.get(id)
    assert stored["purpose"] == ""
  end

  test "a hidden identity cannot be mistaken for an accepted but unapplied creation", ctx do
    {:ok, created} =
      AgentManagement.run(
        :create,
        %{
          "name" => "Hidden",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"}
        },
        ctx.ctx
      )

    id = created["agent"]["agent_id"]
    {:ok, record} = Control.get_record(id)
    assert {:ok, _} = S3.put(Keys.ctl_agent(id), Jason.encode!(Map.put(record, "hidden", true)))

    assert {:error, %{"code" => "agent_not_found"}} =
             AgentManagement.run(:get, %{"agent_id" => id}, ctx.ctx)

    assert {:ok, %{"items" => []}} = AgentManagement.run(:list, %{}, ctx.ctx)

    assert {:error, %{"code" => "agent_not_found"}} =
             AgentManagement.run(
               :create,
               %{
                 "name" => "Hidden",
                 "purpose" => "Execute the test responsibility",
                 "creation_reason" => "This test needs an independent Worker",
                 "runtime" => %{"kind" => "internal"}
               },
               ctx.ctx
             )
  end

  test "archive requires strict boolean true and only changes lifecycle", ctx do
    {:ok, created} =
      AgentManagement.run(
        :create,
        %{
          "name" => "Retired",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"}
        },
        ctx.ctx
      )

    id = created["agent"]["agent_id"]
    S3.Fake.reset_put_log()

    for bad <- [false, "true", 1, nil] do
      assert {:error, _} =
               AgentManagement.run(
                 :archive,
                 %{"agent_id" => id, "user_confirmed" => bad},
                 ctx.ctx
               )
    end

    assert {:error, _} = AgentManagement.run(:archive, %{"agent_id" => id}, ctx.ctx)
    assert S3.Fake.put_log() == []

    assert {:ok, archived} =
             AgentManagement.run(:archive, %{"agent_id" => id, "user_confirmed" => true}, ctx.ctx)

    assert archived["agent"]["lifecycle"] == "archived"
    assert archived["agent"]["permanent"]
    refute Map.has_key?(archived["agent"], "runtime_shutdown")
    assert {:ok, %{"agent" => detail}} = AgentManagement.run(:get, %{"agent_id" => id}, ctx.ctx)
    assert Map.drop(detail, ["model", "creation_audit"]) == archived["agent"]
    assert detail["lifecycle"] == "archived"
    assert {:error, :agent_permanently_archived} = Control.unarchive(id, ctx.tenant)
  end

  test "the tool failure channel carries safe errors and Worker/foreign access is rejected",
       ctx do
    worker = SalixAgent.TestSupport.create_control_agent_in_group!(ctx.tenant, ctx.group)

    assert {:error, %{"code" => "forbidden"}} =
             AgentManagement.run(:list, %{}, %{ctx.ctx | agent_id: worker["agent_id"]})

    assert {:error, %{"code" => "agent_not_found"}} =
             AgentManagement.run(
               :get,
               %{"agent_id" => SalixAgent.TestSupport.new_agent_id()},
               ctx.ctx
             )

    assert {:tool_failure, content, "invalid_arguments", "user_reportable", _, []} =
             SalixAgent.Tools.AgentManagement.call(
               :get,
               %{"agent_id" => worker["agent_id"], "tenant_id" => "forged"},
               ctx.ctx
             )

    assert Jason.decode!(content)["code"] == "invalid_arguments"

    # The safe message stays public through tool execution and presentation.
    # It does not open private repair.
    tool_ctx = Map.merge(ctx.ctx, %{role: "router", runtime_kind: :internal})

    tool_ctx =
      Map.put(
        tool_ctx,
        :tool_disclosure,
        SalixAgent.ToolDisclosure.materialize_static("router", :internal, tool_ctx)
      )

    [result] =
      SalixAgent.Tools.execute(
        [
          %{
            id: "missing-get",
            name: "agent.get",
            args: %{"agent_id" => SalixAgent.TestSupport.new_agent_id()}
          }
        ],
        tool_ctx
      )

    assert result.error_class == "agent_not_found"
    labeled = SalixAgent.VisibleReplyPolicy.label_result(result)
    assert labeled.diagnostic_visibility == "user_reportable"
    assert labeled.public_summary == Jason.decode!(result.content)["message"]
    assert SalixAgent.VisibleReplyPolicy.transition(:clean, [labeled]) == :none
  end

  # Workers bound to a station (`SalixAgent.StationBinding`): Agent Control
  # checks the binding, the Router tools create and move such Workers, and the
  # release migration (`SalixAgent.Migrations.StationBoundWorkers`) binds every
  # External Runtime Worker to its device's station, or a Compute Workload
  # Worker to the Group's Cloud VM.

  test "a Router creates a Worker bound to a station and moves it to another", %{ctx: ctx} do
    input = %{
      "name" => "Builder",
      "purpose" => "Builds on the laptop",
      "creation_reason" => "The user wants Claude Code on the laptop",
      "runtime" => %{"kind" => "station", "device_id" => "dev-laptop"},
      "model" => @runtime
    }

    assert {:ok, %{"result" => "applied", "agent" => agent}} =
             AgentManagement.run(:create, input, ctx)

    assert agent["runtime"] == %{
             "kind" => "station",
             "runs_on" => %{"kind" => "station", "device_id" => "dev-laptop"},
             "provider" => "claude"
           }

    assert agent["binding_revision"] == 1
    assert agent["model"]["model_id"] == "claude-fable-5-1"

    # A station needs a runtime model; External Runtime targets are retired.
    for {extra, code} <- [
          {%{"model" => nil}, "station_model_required"},
          {%{"runtime" => %{"kind" => "connected", "device_runtime_id" => "rt"}},
           "external_runtime_retired"}
        ] do
      request = input |> Map.merge(extra) |> Map.reject(fn {_key, value} -> is_nil(value) end)

      assert {:error, %{"code" => ^code}} =
               AgentManagement.run(:create, request, %{ctx | tool_call_id: code})
    end

    rebind = %{
      "agent_id" => agent["agent_id"],
      "target" => %{"kind" => "cloud_vm"},
      "expected_binding_revision" => 1
    }

    assert {:ok, %{"result" => "applied", "agent" => moved}} =
             AgentManagement.run(:rebind, rebind, ctx)

    assert moved["runtime"]["runs_on"] == %{"kind" => "cloud_vm"}
    assert moved["binding_revision"] == 2
    # The model stays when the rebind names none.
    assert moved["model"]["model_id"] == "claude-fable-5-1"

    # The same move again is a replay; another one at the old revision conflicts.
    assert {:ok, %{"result" => "unchanged"}} = AgentManagement.run(:rebind, rebind, ctx)

    assert {:error, %{"code" => "binding_conflict"}} =
             AgentManagement.run(
               :rebind,
               %{rebind | "target" => %{"kind" => "station", "device_id" => "dev-desk"}},
               ctx
             )

    # A Worker may run each of its Tasks on a sandbox of its own.
    assert {:ok, %{"result" => "applied", "agent" => sandboxed}} =
             AgentManagement.run(
               :rebind,
               %{rebind | "target" => %{"kind" => "sandbox"}, "expected_binding_revision" => 2},
               ctx
             )

    assert sandboxed["runtime"]["runs_on"] == %{"kind" => "sandbox"}
    assert sandboxed["binding_revision"] == 3
  end

  test "the release migration binds External Runtime Workers to their station", %{
    tenant: tenant,
    group: group
  } do
    connected = external!(tenant, group, connected("dev-laptop", "codex", "gpt-5.5"))
    unknown_model = external!(tenant, group, connected("dev-desk", "claude", "no-such-model"))

    cloud_vm =
      external!(tenant, group, connected(RuntimeIds.cloud_vm_device_id(group), "claude", nil))

    workload =
      external!(tenant, group, %{
        "kind" => "compute_workload",
        "workload_id" => "wl-1",
        "runtime_spec" => %{"provider" => "codex"}
      })

    pi = external!(tenant, group, connected("dev-pi", "pi", nil))
    internal = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{})

    assert {:ok, %{station: 2, cloud_vm: 2, archived: 1}} =
             StationBoundWorkers.run()

    assert stored(connected)["station_binding"] == %{
             "runs_on" => %{"kind" => "station", "device_id" => "dev-laptop"},
             "model" => %{"kind" => "runtime", "provider" => "codex", "model" => "gpt-5.5"},
             "binding_revision" => 1
           }

    # A model the catalog does not know for the runtime: the station default.
    assert stored(unknown_model)["station_binding"]["model"] == %{
             "kind" => "runtime",
             "provider" => "claude"
           }

    assert stored(cloud_vm)["station_binding"]["runs_on"] == %{"kind" => "cloud_vm"}

    # A Compute Workload Worker runs on the Group's Cloud VM.
    assert stored(workload)["station_binding"] == %{
             "runs_on" => %{"kind" => "cloud_vm"},
             "model" => %{"kind" => "runtime", "provider" => "codex"},
             "binding_revision" => 1
           }

    # Pi has no station runtime: archived with the reason, not deleted.
    assert %{"archived_at" => _, "archive_reason" => reason} = stored(pi)
    assert reason =~ "pi"
    refute Map.has_key?(stored(pi), "station_binding")
    refute Map.has_key?(stored(internal), "station_binding")

    assert {:ok, %{station: 0, cloud_vm: 0, archived: 0}} =
             StationBoundWorkers.run()

    # The next release pass removes the External Runtime configuration and a
    # leftover External Session reservation, and keeps the station binding,
    # the archive and every internal record.
    legacy = external!(tenant, group, %{"kind" => "external", "provider" => "codex"})
    admission = %{"kind" => "external_session", "session_id" => "ses1_0000000000000000990"}

    {:ok, _} =
      S3.put(
        Keys.ctl_agent(legacy["agent_id"]),
        legacy |> stored() |> Map.put("session_admission", admission) |> Jason.encode!()
      )

    internal_before = stored(internal)

    assert {:ok, 6} = RetireExternalRuntimeConfig.run()
    assert stored(legacy)["runtime_config"] == %{"kind" => "internal"}
    refute Map.has_key?(stored(legacy), "session_admission")
    assert stored(workload)["runtime_config"] == %{"kind" => "internal"}
    assert stored(internal) == internal_before
    assert stored(connected)["runtime_config"] == %{"kind" => "internal"}
    assert stored(connected)["station_binding"]["runs_on"]["device_id"] == "dev-laptop"
    assert stored(pi)["runtime_config"] == %{"kind" => "internal"}
    assert %{"archived_at" => _, "archive_reason" => ^reason} = stored(pi)
    assert {:ok, 0} = RetireExternalRuntimeConfig.run()
  end

  test "binding a Worker to the Cloud VM is its permission: no VM provider is asked", %{
    tenant: tenant,
    group: group,
    ctx: ctx
  } do
    # A release job wires no VM provider; a provider that would be asked fails
    # the test. The pass binds the Worker and leaves its `vm` as it was.
    previous = SystemsRuntime.get_env(:salix_agent, :cloud_vm_mod)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, UnaskedVM)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :cloud_vm_mod)
    end)

    migrated = external!(tenant, group, compute("wl-on"))
    vm_before = stored(migrated)["vm"]
    assert {:ok, %{cloud_vm: 1}} = StationBoundWorkers.run()
    assert stored(migrated)["station_binding"]["runs_on"] == %{"kind" => "cloud_vm"}
    assert stored(migrated)["vm"] == vm_before
    assert StationBinding.cloud_vm?(stored(migrated))

    assert {:ok, %{"agent" => %{"agent_id" => created}}} =
             AgentManagement.run(
               :create,
               %{
                 "name" => "On the Cloud VM",
                 "purpose" => "Runs on the Cloud VM",
                 "creation_reason" => "The user wants Codex on the Cloud VM",
                 "runtime" => %{"kind" => "cloud_vm"},
                 "model" => %{"kind" => "runtime", "provider" => "codex"}
               },
               ctx
             )

    created = stored(%{"agent_id" => created})
    refute match?(%{"enabled" => true}, created["vm"])
    assert StationBinding.cloud_vm?(created)

    # An archived Worker uses nothing.
    refute StationBinding.cloud_vm?(Map.put(created, "archived_at", 1))
  end

  test "the Group Cloud VM switch pass turns on each Group whose live Agent used its Cloud VM, and after the rollout removes every Agent's vm",
       %{tenant: tenant, group: group, router: router} do
    # Records as an earlier release stored them: the Router had VM access.
    with_vm!(router, true)
    off_group = Ids.new_group_id(tenant)
    off = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, off_group, %{})
    with_vm!(off, false)
    archived_group = Ids.new_group_id(tenant)
    archived = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, archived_group, %{})
    with_vm!(archived, true, %{"archived_at" => 1})
    bound_group = Ids.new_group_id(tenant)
    bound = external!(tenant, bound_group, compute("wl-bound"))
    # A BFT Project's Group with its switch off: its Worker is only bound.
    bound_project_group = Ids.new_group_id(tenant)

    SalixAgent.TestSupport.create_control_group!(bound_project_group, %{
      "billing_owner" => %{"surface" => "bridge"}
    })

    bound_project = external!(tenant, bound_project_group, compute("wl-bound-project"))
    assert {:ok, %{cloud_vm: 2}} = StationBoundWorkers.run()

    for g <- [group, off_group, archived_group, bound_group, bound_project_group],
        do: refute(SalixAgent.CloudVM.group_enabled?(g))

    # Before the rollout: switches turn on, and old nodes still read `vm`.
    assert {:ok, %{groups: 2, agents: 0}} = GroupCloudVMSwitch.run()

    assert SalixAgent.CloudVM.group_enabled?(group)
    assert SalixAgent.CloudVM.group_enabled?(bound_group)
    refute SalixAgent.CloudVM.group_enabled?(off_group)
    refute SalixAgent.CloudVM.group_enabled?(archived_group)
    refute SalixAgent.CloudVM.group_enabled?(bound_project_group)
    assert SalixAgent.CloudVM.allowed?(stored(router))
    assert stored(router)["vm"] == %{"enabled" => true}

    # During the rollout a node of the release before gives two Agents VM
    # access: one of a Group no product owns, one of a BFT Project's Group,
    # whose product decides its switch after the rollout.
    late_group = Ids.new_group_id(tenant)
    late = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, late_group, %{})
    with_vm!(late, true)
    project_group = Ids.new_group_id(tenant)

    project_agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, project_group, %{})

    SalixAgent.TestSupport.create_control_group!(project_group, %{
      "billing_owner" => %{"surface" => "bridge"}
    })

    with_vm!(project_agent, true)

    assert {:ok, %{groups: 1, agents: 5, next_cursor: nil}} =
             GroupCloudVMSwitch.page(nil, after_rollout: true)

    assert SalixAgent.CloudVM.group_enabled?(late_group)
    refute SalixAgent.CloudVM.group_enabled?(project_group)

    refute SalixAgent.CloudVM.group_enabled?(bound_project_group)

    for agent <- [router, off, archived, bound, bound_project, late, project_agent],
        do: refute(Map.has_key?(stored(agent), "vm"))

    # Run again, it changes nothing.
    assert {:ok, %{groups: 0, agents: 0}} = GroupCloudVMSwitch.run()
    assert {:ok, %{groups: 0, agents: 0}} = GroupCloudVMSwitch.page(nil, after_rollout: true)
  end

  test "the passes after the rollout resume after the last page done, and do nothing once done" do
    marker = "group_cloud_vm_switch_v1"
    SalixStore.Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [marker])

    on_exit(fn ->
      SalixStore.Repo.query!("DELETE FROM salix_cutover_markers WHERE name = $1", [marker])
    end)

    me = SystemsRuntime.Proc.self()

    step = fn answer ->
      fn position ->
        SystemsRuntime.Proc.send(me, {:step, position})
        answer
      end
    end

    two = %{"stage" => "project_cloud_vm", "source" => "prj_2"}

    assert {:ok, %{processed: 3, done: false}} =
             GroupCloudVMSwitch.after_rollout_page(
               step.(
                 {:ok, %{processed: 3, next: %{"stage" => "group_cloud_vm", "source" => "a"}}}
               )
             )

    assert_received {:step, nil}

    assert {:ok, %{processed: 2, done: false}} =
             GroupCloudVMSwitch.after_rollout_page(step.({:ok, %{processed: 2, next: two}}))

    assert_received {:step, %{"stage" => "group_cloud_vm", "source" => "a"}}

    # The run is cut off in the next page: the one after it runs that page
    # again, from where the last page done left off.
    assert {:error, :timeout} = GroupCloudVMSwitch.after_rollout_page(step.({:error, :timeout}))
    assert_received {:step, ^two}

    assert {:ok, %{processed: 1, done: true}} =
             GroupCloudVMSwitch.after_rollout_page(step.({:ok, %{processed: 1, next: nil}}))

    assert_received {:step, ^two}

    assert %{rows: [[%{"phase" => "complete", "processed" => 6}]]} =
             SalixStore.Repo.query!(
               "SELECT evidence FROM salix_cutover_markers WHERE name = $1",
               [marker]
             )

    # Done: every later run passes without a page.
    assert {:ok, %{processed: 0, done: true}} =
             GroupCloudVMSwitch.after_rollout_page(step.({:error, :ran_again}))

    refute_received {:step, _position}
  end

  defp with_vm!(agent, enabled, extra \\ %{}) do
    key = Keys.ctl_agent(agent["agent_id"])

    {:ok, _} =
      S3.put(
        key,
        stored(agent)
        |> Map.put("vm", %{"enabled" => enabled})
        |> Map.merge(extra)
        |> Jason.encode!()
      )
  end

  defp compute(workload_id),
    do: %{
      "kind" => "compute_workload",
      "workload_id" => workload_id,
      "runtime_spec" => %{"provider" => "codex"}
    }

  defp connected(device_id, provider, model) do
    %{
      "kind" => "connected_runtime",
      "provider" => provider,
      "device_id" => device_id,
      "runtime_id" => "rt",
      "device_runtime_id" => RuntimeIds.device_runtime_id(device_id, provider, "rt")
    }
    |> then(&if(model, do: Map.put(&1, "model", model), else: &1))
  end

  # An External Runtime Worker as an earlier release stored it.
  defp external!(tenant, group, runtime_config) do
    worker = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{})
    key = Keys.ctl_agent(worker["agent_id"])
    {:ok, %{body: body}} = S3.get(key)

    {:ok, _} =
      S3.put(
        key,
        body |> Jason.decode!() |> Map.put("runtime_config", runtime_config) |> Jason.encode!()
      )

    worker
  end

  defp stored(agent) do
    {:ok, %{body: body}} = S3.get(Keys.ctl_agent(agent["agent_id"]))
    Jason.decode!(body)
  end
end
