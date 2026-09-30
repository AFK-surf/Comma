defmodule SalixAgent.RemoteShellToolsTest do
  use ExUnit.Case, async: false
  alias SalixAgent.Tools.RemoteShell

  defmodule Backend do
    def call(group, {agent, session}, args) do
      {:ok, %{group: group, agent: agent, session: session, action: args["action"]}}
    end
  end

  setup do
    old_backend = Application.get_env(:salix_agent, :remote_shell_mod)
    old_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> SalixStore.S3.Fake.reset()
    end

    Application.put_env(:salix_agent, :remote_shell_mod, Backend)
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    on_exit(fn ->
      restore(:salix_agent, :remote_shell_mod, old_backend)
      restore(:salix_store, :s3_backend, old_store)
    end)

    {:ok, router: router, group: group}
  end

  test "backend scope comes from the authoritative agent, not caller-supplied group", %{
    router: router,
    group: group
  } do
    ctx = %{agent_id: router["agent_id"], session_id: "current-session", group_id: "forged-group"}
    result = RemoteShell.call(%{"action" => "prepare"}, ctx) |> Jason.decode!()
    assert result["group"] == group
    assert result["agent"] == router["agent_id"]
    assert result["session"] == "current-session"

    assert {:tool_failure, _, _, _, _, _} =
             RemoteShell.call(%{"action" => "prepare"}, Map.delete(ctx, :session_id))
  end

  test "unavailable backend and unknown agents fail without falling back", %{router: router} do
    Application.delete_env(:salix_agent, :remote_shell_mod)

    assert {:tool_failure, _, _, _, _, _} =
             RemoteShell.call(%{"action" => "prepare"}, %{
               agent_id: router["agent_id"],
               session_id: "s"
             })

    assert {:tool_failure, _, _, _, _, _} =
             RemoteShell.call(%{"action" => "prepare"}, %{agent_id: "missing", session_id: "s"})
  end

  test "worker can use the tool with its own authoritative scope", %{
    router: router,
    group: group
  } do
    tenant = router["tenant_id"]

    worker =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(tenant, group, %{
        "role" => "worker",
        "runtime_config" => %{"kind" => "internal"}
      })

    result =
      RemoteShell.call(%{"action" => "prepare"}, %{
        agent_id: worker["agent_id"],
        session_id: "worker-session",
        group_id: "forged-group",
        role: "router"
      })
      |> Jason.decode!()

    assert result["group"] == group
    assert result["agent"] == worker["agent_id"]
    assert result["session"] == "worker-session"

    disclosure = SalixAgent.ToolDisclosure.materialize_static("worker", :internal)
    assert Enum.any?(disclosure["tools"], &(&1["name"] == "env.remote_shell" and &1["callable"]))
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
