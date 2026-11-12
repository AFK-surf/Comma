defmodule SalixIM.TaskModelSelectionTest do
  use ExUnit.Case, async: true
  alias SalixIM.TaskModelSelection

  defp dynamic(entries),
    do: %{
      "mode" => "routes",
      "schema_version" => 2,
      "revision" => "rev-one",
      "enabled" => true,
      "entries" => entries
    }

  defp entry(key),
    do: %{
      "key" => key,
      "description" => "Use for localized edits",
      "model" => %{"kind" => "catalog", "model" => "model-a", "reasoning_effort" => nil}
    }

  test "automatic routing retains the current placement and explicit model contract" do
    {:ok, manual} = SalixIM.Provider.Manuals.manual("internal")
    api = Enum.find(manual["apis"], &(&1["name"] == "internal.task.create"))
    routed = TaskModelSelection.manual(api, dynamic([entry("edit")]))

    assert "runs_on" in routed["required_params"]
    assert routed["input_schema"] == api["input_schema"]
    assert Map.has_key?(routed["input_schema"]["properties"], "runs_on")
    assert TaskModelSelection.manual(api, dynamic([])) == api
  end

  test "empty and disabled routing have identical tools, worker policy and task configuration" do
    empty = dynamic([])
    off = dynamic([entry("edit")]) |> Map.put("enabled", false)

    api = %{
      "description" => "Create task",
      "input_schema" => %{"properties" => %{"model" => %{}, "runs_on" => %{}}}
    }

    spec = %{
      "conversation" => %{
        "participants" => [
          %{
            "agent_id" => "worker",
            "payload" => %{"session_model" => %{"model" => "worker-default"}}
          }
        ]
      }
    }

    for policy <- [empty, off, nil] do
      assert TaskModelSelection.effective(policy) == nil
      refute SalixAgent.TaskRouting.automatic?(policy)
      assert TaskModelSelection.manual(api, policy) == api

      assert {:ok, ^spec} =
               TaskModelSelection.configure_spec(
                 spec,
                 %{"task_model_selection" => policy},
                 %{"session_model" => %{"model" => "explicit"}},
                 "router",
                 nil
               )
    end
  end

  test "active dynamic routing snapshots the policy, preserves explicit models and rejects unknown choices" do
    policy = dynamic([entry("编辑 / edit")])
    assert :ok = TaskModelSelection.validate(policy)
    assert SalixAgent.TaskRouting.automatic?(policy)

    api = %{
      "description" => "Create task",
      "input_schema" => %{"properties" => %{"model" => %{}, "runs_on" => %{}, "content" => %{}}}
    }

    restricted = TaskModelSelection.manual(api, policy)
    assert restricted["input_schema"] == api["input_schema"]

    assert {:ok, spec} =
             TaskModelSelection.configure_spec(
               %{},
               %{"task_model_selection" => policy},
               %{"origin_session_id" => "session", "content" => "task"},
               "router",
               nil
             )

    assert spec["model_selection"]["policy"] == policy

    assert {:ok, %{}} =
             TaskModelSelection.configure_spec(
               %{},
               %{"task_model_selection" => policy},
               %{"origin_session_id" => "session", "session_model" => %{}},
               "router",
               nil
             )

    assert {:error, :invalid_response} =
             TaskModelSelection.candidate(policy, %{
               "answers" => %{"route" => %{"choice" => "r99"}}
             })

    assert {:ok, %{"model" => "model-a"}, evidence} =
             TaskModelSelection.candidate(policy, %{
               "answers" => %{"route" => %{"choice" => "r0"}}
             })

    assert evidence["tag_key"] == "编辑 / edit"
    refute Map.has_key?(evidence, "route")
    assert evidence["rule_version"] == "rev-one"
  end

  test "explicit policies check the supplied choice and Profile at the common internal entry" do
    policy = %{
      "mode" => "explicit",
      "profile_id" => "pinned",
      "actions" => [
        %{"model" => "model-a", "reasoning_effort" => "high"}
      ]
    }

    group = %{"task_model_selection" => policy}

    choice = %{
      "kind" => "catalog",
      "model" => "model-a",
      "reasoning_effort" => "high",
      "profile_id" => "pinned"
    }

    for model <- [
          nil,
          Map.delete(choice, "profile_id"),
          Map.put(choice, "profile_id", "other"),
          Map.delete(choice, "reasoning_effort"),
          Map.put(choice, "model", "model-b")
        ] do
      assert {:error, {:bad_request, _}} =
               TaskModelSelection.configure_spec(
                 %{},
                 group,
                 %{"session_model" => model},
                 "router",
                 nil
               )
    end

    assert {:ok, %{}} =
             TaskModelSelection.configure_spec(
               %{},
               group,
               %{"session_model" => choice},
               "router",
               choice
             )

    assert {:ok, %{}} =
             TaskModelSelection.configure_spec(
               %{},
               group,
               %{"runs_on" => %{"kind" => "sandbox"}},
               "router",
               nil
             )

    assert {:ok, %{}} =
             TaskModelSelection.configure_spec(
               %{},
               put_in(group, ["task_model_selection", "enabled"], false),
               %{},
               "router",
               nil
             )
  end

  test "dynamic routing rejects duplicate keys, unsupported choices and oversized tables" do
    for policy <- [
          dynamic([entry("same"), entry("same")]),
          dynamic([entry(" ")]),
          dynamic([put_in(entry("edit"), ["model", "kind"], "runtime")]),
          dynamic(Enum.map(1..33, &entry(to_string(&1)))),
          Map.put(dynamic([]), "schema_version", 99)
        ] do
      assert {:error, _} = TaskModelSelection.validate(policy)
    end
  end
end
