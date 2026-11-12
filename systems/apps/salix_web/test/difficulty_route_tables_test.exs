defmodule SalixWeb.DifficultyRouteTablesTest do
  @moduledoc """
  The pass that converts retired difficulty tables
  (`SalixWeb.Migrations.DifficultyRouteTables`) over Group records: a
  difficulty table becomes a route table with the same keys, descriptions and
  model choices, keeps its switch and Profile, and keeps its learned evidence;
  other tables are left as they are; a pass run again changes nothing; a table
  too large for a route table stops the pass with its Group.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.TaskRouting.Learner
  alias SalixStore.{CasRecord, Keys}
  alias SalixWeb.Migrations.DifficultyRouteTables

  setup do
    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Difficulty tables"})
    %{tenant: tenant["tenant_id"]}
  end

  test "a difficulty table becomes the same route table and keeps its evidence", %{
    tenant: tenant
  } do
    table =
      difficulty_table("Level")
      |> Map.merge(%{"enabled" => true, "profile_id" => "pinned", "learning" => %{}})

    learned = group!(tenant, table)
    routes = group!(tenant, route_table())
    none = group!(tenant, nil)

    action = %{"model" => "model-b", "reasoning_effort" => nil}
    evidence = Learner.generation("d7", "Level 7")

    assert {:ok, %{converted: 1}} = DifficultyRouteTables.run()

    converted = selection(learned)
    assert :ok = SalixIM.TaskModelSelection.validate(converted)

    assert Map.take(converted, ~w(mode schema_version revision enabled profile_id learning)) ==
             %{
               "mode" => "routes",
               "schema_version" => 2,
               "revision" => "R0",
               "enabled" => true,
               "profile_id" => "pinned",
               "learning" => true
             }

    assert Enum.map(converted["entries"], &{&1["key"], &1["description"], &1["model"]}) ==
             for(
               level <- 1..10,
               do:
                 {"d#{level}", "Level #{level}",
                  if(level <= 4,
                    do: %{"kind" => "catalog", "model" => "model-a", "reasoning_effort" => "low"},
                    else: %{"kind" => "catalog", "model" => "model-b"}
                  )}
             )

    # A route's evidence is named by its key and description, an arm by its Model Choice.
    d7 = Enum.find(converted["entries"], &(&1["key"] == "d7"))
    assert Learner.generation(d7["key"], d7["description"]) == evidence
    assert Learner.arm_key(d7["model"]) == Learner.arm_key(action)

    assert selection(routes) == route_table()
    assert selection(none) == nil

    assert {:ok, %{converted: 0}} = DifficultyRouteTables.run()
    assert selection(learned) == converted
  end

  test "a table a route table cannot hold stops the pass with its Group", %{tenant: tenant} do
    large = group!(tenant, difficulty_table(String.duplicate("x", 1000)))

    assert {:error, {:route_table_too_large, ^large}} = DifficultyRouteTables.convert(large)
    assert selection(large)["mode"] == "tag_rules"
    # Other tests run the whole pass.
    put_selection!(large, nil)
  end

  defp difficulty_table(description) do
    %{
      "mode" => "tag_rules",
      "rule_version" => "R0",
      "rubric_version" => "v1",
      "questions" => %{
        "difficulty" => %{
          "type" => "choice",
          "instructions" => "Classify difficulty",
          "criteria" => Map.new(1..10, &{"d#{&1}", "#{description} #{&1}"})
        }
      },
      "actions" => [
        %{"model" => "model-a", "reasoning_effort" => "low"},
        %{"model" => "model-b", "reasoning_effort" => nil}
      ],
      "routes" => Map.new(1..10, &{"d#{&1}", %{"action" => if(&1 <= 4, do: 0, else: 1)}})
    }
  end

  defp route_table do
    %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => "kept",
      "entries" => [
        %{
          "key" => "docs",
          "description" => "Documentation",
          "model" => %{"kind" => "catalog", "model" => "model-a"}
        }
      ]
    }
  end

  defp group!(tenant, selection) do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Routing"}, tenant)
    put_selection!(group["group_id"], selection)
  end

  defp put_selection!(group, selection) do
    {:ok, _} =
      CasRecord.update(
        Keys.ctl_group(group),
        fn record ->
          if selection,
            do: Map.put(record, "task_model_selection", selection),
            else: Map.delete(record, "task_model_selection")
        end,
        create: false
      )

    group
  end

  defp selection(group) do
    {:ok, record} = CasRecord.get(Keys.ctl_group(group))
    record["task_model_selection"]
  end
end
