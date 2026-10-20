defmodule SalixAgent.RemoteShellToolsTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.Tools.RemoteShell

  defmodule Backend do
    def call(group, {agent, session}, args) do
      {:ok, %{group: group, agent: agent, session: session, action: args["action"]}}
    end
  end

  setup do
    old_backend = SystemsRuntime.get_env(:salix_agent, :remote_shell_mod)
    old_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> SalixStore.S3.Fake.reset()
    end

    SystemsRuntime.put_env(:salix_agent, :remote_shell_mod, Backend)
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

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
