defmodule SalixAgent.DependencyInstallationsToolTest do
  use ExUnit.Case, async: false

  alias SalixAgent.Tools.DependencyInstallations

  defmodule Dispatch do
    def request(agent_id, target, method, params) do
      send(self(), {:dependency_request, agent_id, target, method, params})
      {:ok, %{"entries" => %{}}}
    end
  end

  setup do
    previous = Application.get_env(:salix_agent, :env_dispatch)
    Application.put_env(:salix_agent, :env_dispatch, Dispatch)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :env_dispatch, previous),
        else: Application.delete_env(:salix_agent, :env_dispatch)
    end)
  end

  test "declaration uses the authenticated Agent and exact environment" do
    args = %{
      "device_id" => "device-1",
      "environment" => "environment-1",
      "action" => "declare",
      "path" => "/workspace/project/.venv",
      "kind" => "repository",
      "manager" => "pip",
      "working_directory" => "/workspace/project"
    }

    assert %{"entries" => %{}} =
             args
             |> DependencyInstallations.call(%{agent_id: "agent-1"})
             |> Jason.decode!()

    assert_received {:dependency_request, "agent-1",
                     %{device_id: "device-1", environment_id: "environment-1"},
                     "dependency_installations", params}

    refute Map.has_key?(params, "device_id")
    refute Map.has_key?(params, "environment")
    assert params["path"] == "/workspace/project/.venv"
  end
end
