defmodule BridgeForTeams.Salix.NodesTest do
  use ExUnit.Case, async: false

  alias BridgeForTeams.Salix.Nodes

  setup do
    on_exit(fn -> Application.delete_env(:bridge_for_teams_core, :salix_nodes_override) end)
    :ok
  end

  test "no salix nodes reachable -> unavailable" do
    # No real salix node is connected in the unit suite; probing finds none.
    Application.delete_env(:bridge_for_teams_core, :salix_nodes_override)
    stop_salix_web_if_started()

    assert Nodes.salix_nodes() == []
    assert {:error, :unavailable} = Nodes.pick()
    assert {:error, :unavailable} = Nodes.pick("proj_123")
  end

  test "started local salix app makes the current node pickable" do
    Application.delete_env(:bridge_for_teams_core, :salix_nodes_override)
    started_before? = app_started?(:salix_web)
    {:ok, started_apps} = Application.ensure_all_started(:salix_web)

    on_exit(fn ->
      unless started_before? do
        started_apps
        |> Enum.reverse()
        |> Enum.each(&Application.stop/1)
      end
    end)

    assert Node.self() in Nodes.salix_nodes()
    assert {:ok, node} = Nodes.pick("proj_123")
    assert node == Node.self()
  end

  test "override lists nodes and pick returns one of them" do
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [:a@h, :b@h, :c@h])
    assert Nodes.salix_nodes() == [:a@h, :b@h, :c@h]

    assert {:ok, node} = Nodes.pick("proj_1")
    assert node in [:a@h, :b@h, :c@h]
  end

  test "pick is sticky by hint (deterministic on a stable list)" do
    nodes = [:a@h, :b@h, :c@h]
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, nodes)

    {:ok, first} = Nodes.pick("proj_abc")
    {:ok, again} = Nodes.pick("proj_abc")
    assert first == again

    # the chosen node matches the documented phash2 placement
    expected = Enum.at(nodes, :erlang.phash2("proj_abc", length(nodes)))
    assert first == expected
  end

  test "single node always picked" do
    Application.put_env(:bridge_for_teams_core, :salix_nodes_override, [:only@h])
    assert {:ok, :only@h} = Nodes.pick()
    assert {:ok, :only@h} = Nodes.pick("anything")
  end

  defp stop_salix_web_if_started do
    if app_started?(:salix_web) do
      :ok = Application.stop(:salix_web)
      on_exit(fn -> Application.ensure_all_started(:salix_web) end)
    end
  end

  defp app_started?(app) do
    Application.started_applications()
    |> Enum.any?(fn {started_app, _description, _version} -> started_app == app end)
  end
end
