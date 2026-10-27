defmodule CommaWeb.SalixClientTaskRunTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.CommaWeb", "Elixir.SalixWeb", "Elixir.SalixEnv"]

  import Ecto.Query
  alias CommaWeb.SalixClient
  alias SalixIM.ConversationServer
  alias SalixStore.{AgentVMM, CodingSandboxes, Compute, Ids, Repo, StationTaskSessions}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()
    SalixAgent.TestSupport.configure_platform_models!()
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Task run"})

    on_exit(fn ->
      Repo.query!("DELETE FROM station_task_sessions WHERE group_id = $1", [group])
      environments = from(e in Compute.Environment, where: e.tenant_id == ^tenant, select: e.id)

      Repo.delete_all(
        from(w in Compute.Workload, where: w.environment_id in subquery(environments))
      )

      Repo.delete_all(
        from(a in Compute.Allocation, where: a.environment_id in subquery(environments))
      )

      Repo.delete_all(
        from(b in Compute.ProviderBinding, where: b.environment_id in subquery(environments))
      )

      Repo.delete_all(from(e in Compute.Environment, where: e.tenant_id == ^tenant))
      Repo.delete_all(from(r in AgentVMM.Registration, where: r.tenant_id == ^tenant))
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous)
    end)

    %{
      tenant: tenant,
      group: group,
      workspace: %{"salix_tenant_id" => tenant, "default_group_id" => group}
    }
  end

  test "a coding sandbox reports its subscription runtime default rather than the platform model",
       f do
    conversation =
      task!(f, %{
        "runs_on" => %{"kind" => "sandbox"},
        "repo" => %{"owner" => "acme", "name" => "api"}
      })

    {:ok, _workload} =
      CodingSandboxes.create(%{
        tenant_id: f.tenant,
        group_id: f.group,
        conversation_id: conversation,
        workspace: "comma:" <> f.group,
        repo: %{"owner" => "acme", "name" => "api"},
        start: %{"runtime" => "codex"}
      })

    assert {:ok, %{"place" => %{"kind" => "sandbox"}, "model" => model}} =
             SalixClient.task_run(f.workspace, conversation)

    assert model == %{
             "kind" => "runtime",
             "provider" => "codex",
             "name" => nil,
             "vendor" => "openai"
           }
  end

  test "a dynamic Group VMM Station reports the platform default and keeps an explicit model",
       f do
    device = vmm_station!(f)
    conversation = task!(f)
    join!(f, conversation, device, %{"runtime" => "codex"})

    assert {:ok,
            %{
              "place" => %{"kind" => "station", "device_id" => ^device},
              "model" => %{"kind" => "platform"}
            }} =
             SalixClient.task_run(f.workspace, conversation)

    named = task!(f)
    join!(f, named, device, %{"runtime" => "codex", "model" => "named-codex-model"})

    assert {:ok,
            %{
              "model" => %{
                "kind" => "runtime",
                "provider" => "codex",
                "name" => "named-codex-model"
              }
            }} =
             SalixClient.task_run(f.workspace, named)
  end

  test "a physical Station keeps its runtime default", f do
    conversation = task!(f)
    join!(f, conversation, "physical-task-run", %{"runtime" => "codex"})

    assert {:ok, %{"place" => %{"kind" => "station"}, "model" => model}} =
             SalixClient.task_run(f.workspace, conversation)

    assert model == %{
             "kind" => "runtime",
             "provider" => "codex",
             "name" => nil,
             "vendor" => "openai"
           }
  end

  defp task!(f, attrs \\ %{}) do
    {:ok, conversation} =
      ConversationServer.create_group_conversation(
        f.group,
        Map.merge(%{"kind" => "agent_task", "title" => "Model read"}, attrs)
      )

    conversation["conversation_id"]
  end

  defp join!(f, conversation, device, start) do
    :ok =
      StationTaskSessions.join(%{
        tenant_id: f.tenant,
        group_id: f.group,
        conversation_id: conversation,
        device_id: device,
        session: "session-" <> conversation,
        agent_id: Ids.new_agent_id(f.group),
        start: start
      })
  end

  defp vmm_station!(f) do
    id = "host-task-run-" <> f.group

    {:ok, _registration} =
      AgentVMM.create_registration(%{
        id: id,
        tenant_id: f.tenant,
        group_id: f.group,
        device_id: "host-device-" <> f.group,
        enrollment_token: String.duplicate("e", 32)
      })

    {:ok, pool} = Compute.ensure_managed_default_pool(f.tenant, "agent_vmm")

    {:ok, environment} =
      Compute.create_environment(%{
        id: "env-" <> f.group,
        tenant_id: f.tenant,
        owner_type: "project",
        owner_id: "project-" <> f.group,
        pool_id: pool.id
      })

    {:ok, binding} =
      Compute.create_provider_binding(%{
        id: "binding-" <> f.group,
        pool_id: pool.id,
        environment_id: environment.id,
        provider: "agent_vmm",
        provider_ref: id
      })

    Repo.update_all(from(r in AgentVMM.Registration, where: r.id == ^id),
      set: [status: "ready", desired_enabled: true]
    )

    Repo.update_all(from(b in Compute.ProviderBinding, where: b.id == ^binding.id),
      set: [
        status: "available",
        observation: %{"gateway_instance_id" => "test", "connection_epoch" => "1"}
      ]
    )

    {:ok, _workload} = Compute.ensure_group_station(f.tenant, f.group)
    {:ok, record} = Compute.group_station(f.tenant, f.group)
    record["device_id"]
  end
end
