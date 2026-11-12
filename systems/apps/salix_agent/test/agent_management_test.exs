defmodule SalixAgent.AgentManagementTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.{AgentManagement, Control}

  alias SalixAgent.Migrations.StationBoundWorkers

  alias SalixAgent.StationBinding
  alias SalixStore.{Ids, Keys, S3}

  @runtime %{"kind" => "runtime", "provider" => "claude", "model" => "claude-fable-5-1"}

  # A Group that may have a Cloud VM (its placement decides where). Turning
  # a bound Worker's VM on reads no Tenant provider configuration.
  defmodule UnaskedVM do
    @moduledoc false
    @behaviour SalixAgent.CloudVM
    def available?(_tenant_id, _group_id), do: raise("the VM provider was asked")
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
    assert {:ok, current} = SalixStore.AgentPGStore.read_config(id)

    assert {:ok, _} =
             SalixStore.AgentPGStore.put_config(
               id,
               Map.put(record, "hidden", true),
               current.revision
             )

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

  test "binding a Worker to the Cloud VM is its permission: no VM provider is asked", %{
    ctx: ctx
  } do
    # Binding grants permission without provisioning a VM.
    previous = SystemsRuntime.get_env(:salix_agent, :cloud_vm_mod)
    SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, UnaskedVM)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :cloud_vm_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :cloud_vm_mod)
    end)

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

    assert {:ok, created} = Control.get_record(created)
    refute match?(%{"enabled" => true}, created["vm"])
    assert StationBinding.cloud_vm?(created)

    # An archived Worker uses nothing.
    refute StationBinding.cloud_vm?(Map.put(created, "archived_at", 1))
  end

  defp compute(workload_id),
    do: %{
      "kind" => "compute_workload",
      "workload_id" => workload_id,
      "runtime_spec" => %{"provider" => "codex"}
    }

  # An External Runtime Worker as an earlier release stored it.
  defp external!(tenant, group, runtime_config) do
    worker = SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{})
    key = Keys.ctl_agent(worker["agent_id"])

    {:ok, _} =
      S3.put(key, worker |> Map.put("runtime_config", runtime_config) |> Jason.encode!())

    worker
  end

  defp stored(agent) do
    {:ok, %{body: body}} = S3.get(Keys.ctl_agent(agent["agent_id"]))
    Jason.decode!(body)
  end
end
