defmodule SalixAgent.AgentManagementTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{AgentManagement, Control}
  alias SalixStore.{Ids, Keys, S3}

  setup do
    old_ports = Application.get_env(:salix_agent, :agent_management_ports)
    Application.put_env(:salix_agent, :agent_management_ports, AgentManagement.Ports.Standalone)
    start_supervised!(S3.Fake)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{"role" => "router"})

    {:ok, template} =
      SalixAgent.Templates.create(%{
        "name" => "Worker default",
        "model" => "worker-model",
        "provider" => "mock"
      })

    _ =
      SalixAgent.TestSupport.put_tenant_agent_defaults!(tenant, %{
        "worker_template_id" => template["template_id"]
      })

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()

      if old_ports,
        do: Application.put_env(:salix_agent, :agent_management_ports, old_ports),
        else: Application.delete_env(:salix_agent, :agent_management_ports)
    end)

    %{
      tenant: tenant,
      group: group,
      router: router,
      template: template,
      ctx: %{
        agent_id: router["agent_id"],
        session_id: router["router_session_id"],
        tool_call_id: "create-1"
      }
    }
  end

  @tag :private_template
  test "Router creates an internal Worker with the tenant's private default", ctx do
    {:ok, template} =
      SalixAgent.Templates.create_private(
        %{
          "name" => "Private Worker default",
          "model" => "gpt-private-worker",
          "provider" => "openai"
        },
        ctx.tenant
      )

    _ =
      SalixAgent.TestSupport.put_tenant_agent_defaults!(ctx.tenant, %{
        "worker_template_id" => template["template_id"]
      })

    assert {:ok, result} =
             AgentManagement.run(
               :create,
               %{
                 "name" => "Private Worker",
                 "purpose" => "Test private default",
                 "creation_reason" => "This test needs an independent Worker",
                 "runtime" => %{"kind" => "internal"}
               },
               ctx.ctx
             )

    assert result["agent"]["model"]["template_id"] == template["template_id"]
    assert result["agent"]["model"]["model_id"] == "gpt-private-worker"
    assert {:ok, llm} = SalixAgent.Templates.resolve_llm_for_agent(result["agent"]["agent_id"])
    assert llm["model"] == "gpt-private-worker"
  end

  test "create and exact get expose the named Worker's own default, and replay keeps its identity",
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
    assert first["agent"]["model"]["template_id"] == ctx.template["template_id"]
    refute first["agent"]["model"]["template_id"] == ctx.router["template_id"]
    assert {:ok, second} = AgentManagement.run(:create, input, ctx.ctx)
    assert second["replayed"]
    assert second["agent"]["agent_id"] == id

    assert {:error, %{"code" => "invocation_conflict"}} =
             AgentManagement.run(:create, Map.put(input, "name", "Different request"), ctx.ctx)

    assert {:ok, %{"agent" => details}} = AgentManagement.run(:get, %{"agent_id" => id}, ctx.ctx)
    assert details == second["agent"]
    assert {:ok, %{"items" => [%{"agent_id" => ^id}]}} = AgentManagement.run(:list, %{}, ctx.ctx)
  end

  test "invalid creation metadata is rejected before reserving or creating an identity", ctx do
    input = %{
      "name" => "Reviewer",
      "purpose" => "Review",
      "creation_reason" => "Independent request",
      "runtime" => %{"kind" => "internal"}
    }

    S3.Fake.reset_put_log()

    for field <- ~w(purpose creation_reason), value <- [nil, "", " \n\t "] do
      assert {:error, %{"code" => "invalid_arguments"}} =
               AgentManagement.run(:create, Map.put(input, field, value), ctx.ctx)

      assert {:error, %{"code" => "invalid_arguments"}} =
               AgentManagement.run(:create, Map.delete(input, field), ctx.ctx)
    end

    assert S3.Fake.put_log() == []
    assert {:ok, %{"items" => []}} = AgentManagement.run(:list, %{}, ctx.ctx)
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

  test "failed updates report an error and never become later background work", ctx do
    {:ok, created} =
      AgentManagement.run(
        :create,
        %{
          "name" => "Original",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"}
        },
        ctx.ctx
      )

    id = created["agent"]["agent_id"]
    S3.Fake.set_fault({:fail, 503, :put, Keys.ctl_agent(id)})

    assert {:error, _} =
             AgentManagement.run(:update, %{"agent_id" => id, "name" => "Failed change"}, ctx.ctx)

    assert {:ok, record} = Control.get(id)
    assert record["name"] == "Original"

    assert {:ok, updated} =
             AgentManagement.run(:update, %{"agent_id" => id, "purpose" => "Backend"}, ctx.ctx)

    assert updated["agent"]["name"] == "Original"
    assert updated["agent"]["purpose"] == "Backend"

    assert {:ok, retried} =
             AgentManagement.run(:update, %{"agent_id" => id, "name" => "Caller retry"}, ctx.ctx)

    assert retried["agent"]["name"] == "Caller retry"
  end

  test "concurrent field patches merge at the canonical record CAS", ctx do
    {:ok, created} =
      AgentManagement.run(
        :create,
        %{
          "name" => "Original",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"}
        },
        ctx.ctx
      )

    id = created["agent"]["agent_id"]

    tasks =
      for {key, value} <- [{"name", "Reviewer"}, {"purpose", "Backend"}] do
        Task.async(fn ->
          AgentManagement.run(:update, %{"agent_id" => id, key => value}, ctx.ctx)
        end)
      end

    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 15_000)), &match?({:ok, _}, &1))
    assert {:ok, record} = Control.get(id)
    assert record["name"] == "Reviewer"
    assert record["management_purpose"] == "Backend"
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

  test "a failed archive commit returns an error and leaves no pending intent", ctx do
    {:ok, created} =
      AgentManagement.run(
        :create,
        %{
          "name" => "Worker",
          "purpose" => "Execute the test responsibility",
          "creation_reason" => "This test needs an independent Worker",
          "runtime" => %{"kind" => "internal"}
        },
        ctx.ctx
      )

    id = created["agent"]["agent_id"]
    S3.Fake.set_fault({:fail, 503, :put, Keys.ctl_agent(id)})

    assert {:error, _} =
             AgentManagement.run(:archive, %{"agent_id" => id, "user_confirmed" => true}, ctx.ctx)

    assert {:ok, %{"agent" => detail}} = AgentManagement.run(:get, %{"agent_id" => id}, ctx.ctx)
    assert detail["archived_at"] == nil

    assert {:ok, _} =
             AgentManagement.run(:update, %{"agent_id" => id, "name" => "Still active"}, ctx.ctx)

    assert {:ok, archived} =
             AgentManagement.run(:archive, %{"agent_id" => id, "user_confirmed" => true}, ctx.ctx)

    refute Map.has_key?(archived["agent"], "runtime_shutdown")
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
end
