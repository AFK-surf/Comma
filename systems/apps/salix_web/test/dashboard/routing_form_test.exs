defmodule SalixWeb.Dashboard.RoutingFormTest do
  use ExUnit.Case, async: true
  require Phoenix.LiveViewTest
  alias SalixWeb.Dashboard.RoutingModels
  alias SalixWeb.Dashboard.RoutingForm, as: Form
  alias SalixIM.TaskModelSelection, as: Selection

  defp models,
    do: [
      %{"id" => "model-a", "name" => "Model A", "routing_efforts" => ["low", "medium"]},
      %{"id" => "model-b", "name" => "Model B", "routing_efforts" => [nil]}
    ]

  defp rows do
    %{
      "0" => %{
        "key" => "快速修改 / edit",
        "description" => "Small, localized edits",
        "model" => "model-a",
        "effort" => "low"
      },
      "1" => %{
        "key" => "research",
        "description" => "Research across sources",
        "model" => "model-b",
        "effort" => "default"
      }
    }
  end

  defp policy do
    {:ok, policy} = Form.policy(nil, rows(), true, models())
    policy
  end

  test "platform routing preserves effort through editing, export and import" do
    choice = %{"kind" => "platform", "tier" => "worker", "model" => "gpt-6-sol"}
    key = Form.model_key(choice)
    options = [%{"key" => key, "routing_efforts" => [nil, "low", "medium"]}]

    rows = %{
      "0" => %{"key" => "code", "description" => "Write code", "model" => key, "effort" => "low"}
    }

    assert {:ok, policy} = Form.policy(nil, rows, true, options)
    assert hd(policy["entries"])["model"] == Map.put(choice, "reasoning_effort", "low")
    assert {:ok, json} = Form.export_table(Form.rows(policy))
    assert {:ok, ^rows} = Form.import_table(json)

    assert {:error, _} =
             Form.policy(policy, put_in(rows, ["0", "effort"], "unsupported"), true, options)
  end

  test "portable JSON preserves entries without transferring workspace settings" do
    assert {:ok, json} = Form.export_table(rows())
    assert {:ok, imported} = Form.import_table(json)
    assert imported == rows()
    assert Map.keys(Jason.decode!(json)) |> Enum.sort() == ~w(entries mode schema_version)
    assert {:ok, empty} = Form.export_table(%{})
    assert {:ok, %{}} = Form.import_table(empty)

    # Backup and import still work when an account is unavailable. Saving verifies access.
    assert {:error, _} = Form.policy(nil, imported, true, [])

    assert {:ok, saved} =
             Form.policy(
               %{"profile_id" => "destination", "mode" => "routes", "schema_version" => 2},
               imported,
               false,
               models()
             )

    assert saved["profile_id"] == "destination"
    refute saved["enabled"]
  end

  test "invalid files cannot introduce extra policy fields or malformed entries" do
    {:ok, json} = Form.export_table(rows())
    table = Jason.decode!(json)
    first = hd(table["entries"])

    for invalid <- [
          "not JSON",
          "null",
          "[]",
          String.duplicate(" ", Form.max_file_bytes() + 1),
          Jason.encode!(Map.put(table, "profile_id", "foreign")),
          Jason.encode!(Map.put(table, "enabled", true)),
          Jason.encode!(Map.put(table, "schema_version", 3)),
          Jason.encode!(Map.put(table, "entries", [first, first])),
          Jason.encode!(put_in(table, ["entries"], [%{"key" => "missing-fields"}])),
          Jason.encode!(
            Map.put(table, "entries", Enum.map(1..33, &Map.put(first, "key", "k#{&1}")))
          ),
          Jason.encode!(
            Map.put(
              table,
              "entries",
              Enum.map(
                1..10,
                &Map.merge(first, %{
                  "key" => "k#{&1}",
                  "description" => String.duplicate("x", 1024)
                })
              )
            )
          )
        ] do
      assert {:error, _} = Form.import_table(invalid)
    end
  end

  test "arbitrary keys and descriptions round trip with the model and effort" do
    policy = policy()
    assert :ok = Selection.validate(policy)
    assert Form.rows(policy) == rows()
    request = Selection.request(policy, "Fix the label")
    assert request["questions"]["route"]["criteria"]["r0"] == rows()["0"]["description"]

    assert {:ok, %{"model" => "model-a", "reasoning_effort" => "low"}, evidence} =
             Selection.candidate(policy, %{"answers" => %{"route" => %{"choice" => "r0"}}})

    assert evidence["tag_key"] == "快速修改 / edit"
  end

  test "keys must be nonblank and unique after trimming, descriptions must be text" do
    assert {:error, _} = Form.policy(nil, put_in(rows(), ["0", "key"], "  "), true, models())

    assert {:error, message} =
             Form.policy(nil, put_in(rows(), ["0", "key"], " research "), true, models())

    assert message =~ "unique"

    assert {:error, _} =
             Form.policy(nil, put_in(rows(), ["1", "description"], "  "), true, models())

    assert {:ok, _} = Form.policy(nil, put_in(rows(), ["0", "key"], "RESEARCH"), true, models())
  end

  test "deleting the last entry saves an empty table even without model discovery" do
    original = policy()
    assert {:ok, empty} = Form.policy(original, %{}, true, [])
    assert empty["enabled"]
    assert empty["entries"] == []
    assert Selection.effective(empty) == nil
    assert Form.rows(empty) == %{}
  end

  test "turning off keeps an unavailable table and Profile, enabling verifies access" do
    original = Map.put(policy(), "profile_id", "pinned")
    assert {:ok, off} = Form.policy(original, Form.rows(original), false, [])
    assert off == Map.put(original, "enabled", false)
    assert {:error, _} = Form.policy(off, Form.rows(off), true, [])
    assert {:ok, enabled} = Form.policy(off, Form.rows(off), true, models())
    assert enabled["profile_id"] == "pinned"
  end

  test "adding and deleting entries keeps unsaved edits and defaults model effort" do
    added = Form.add(rows())

    changed =
      Form.change(
        added,
        %{
          "0" => %{"description" => "Edited"},
          "2" => %{"key" => "new", "description" => "Other", "model" => "model-b"}
        },
        models()
      )

    assert changed["2"]["effort"] == "default"
    assert {:ok, saved} = Form.policy(policy(), Map.delete(changed, "1"), true, models())
    assert Enum.map(saved["entries"], & &1["key"]) == ["快速修改 / edit", "new"]
    assert hd(saved["entries"])["description"] == "Edited"
    assert saved["revision"] != policy()["revision"]
  end

  test "unavailable models remain visible and unsupported strategies are not converted" do
    assert [{"gone (unavailable)", "gone"} | _] = Form.model_options(models(), "gone")
    paid = Form.model_key(%{"kind" => "catalog", "model" => "gone", "allow_paid" => true})
    assert [{"gone · Pay-per-use (unavailable)", ^paid} | _] = Form.model_options(models(), paid)

    explicit = %{
      "mode" => "explicit",
      "actions" => [%{"model" => "gone", "reasoning_effort" => nil}]
    }

    assert {:ok, off} = Form.policy(explicit, %{}, false, [])
    assert off == Map.put(explicit, "enabled", false)
    refute Form.editable?(off)
  end

  test "the panel renders saved text as escaped content and permits an empty table" do
    html =
      Phoenix.LiveViewTest.render_component(&SalixWeb.Dashboard.RoutingPanel.panel/1,
        enabled: true,
        rows: put_in(rows(), ["0", "description"], "<script>alert(1)</script>"),
        policy: policy(),
        models: models()
      )

    refute html =~ "<script>alert"
    assert html =~ "Add entry"
    assert html =~ "research"

    empty =
      Phoenix.LiveViewTest.render_component(&SalixWeb.Dashboard.RoutingPanel.panel/1,
        enabled: true,
        rows: %{},
        models: []
      )

    assert empty =~ "No routing entries"
    assert empty =~ "just as when routing is off"
  end

  test "a failed lookup clears candidate options without losing saved mappings" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, routing_rows: rows(), routing_models: models()}
    }

    {:noreply, result} =
      SalixWeb.Dashboard.GroupLive.Show.handle_async(
        :routing_models,
        {:ok, {:error, :unavailable}},
        socket
      )

    assert result.assigns.routing_models == []
    assert result.assigns.routing_rows == rows()
    assert result.assigns.routing_models_error =~ "Could not verify"
  end

  test "API key choices are selectable without a Profile pin and survive file transfer" do
    served = [
      %{"id" => "sub", "efforts" => ["low"], "served_by" => "subscription"},
      %{"id" => "paid", "efforts" => [], "served_by" => "api_key"}
    ]

    assert [%{"id" => "sub"}, %{"id" => "paid", "key" => paid_key}] =
             offered = RoutingModels.selectable(served, %{})

    paid_rows = %{
      "0" => %{
        "key" => "paid",
        "description" => "Research",
        "model" => paid_key,
        "effort" => "default"
      }
    }

    assert {:ok, policy} = Form.policy(nil, paid_rows, true, offered)
    assert [entry] = policy["entries"]

    assert entry["model"] == %{
             "kind" => "catalog",
             "model" => "paid",
             "allow_paid" => true,
             "reasoning_effort" => nil
           }

    assert {:ok, json} = Form.export_table(Form.rows(policy))
    assert {:ok, imported} = Form.import_table(json)
    assert imported == paid_rows
    assert {:ok, restored} = Form.policy(nil, imported, true, offered)
    assert restored["entries"] == policy["entries"]

    assert [%{"id" => "paid", "routing_efforts" => [nil]}] =
             RoutingModels.selectable([List.last(served)], %{"profile_id" => "owned-profile"})
  end

  test "organization allowance applies to effort, payment and exact Profile choice" do
    choice = %{
      "kind" => "catalog",
      "model" => "model-a",
      "reasoning_effort" => "medium",
      "allow_paid" => false,
      "profile_id" => "allowed-pin"
    }

    served = [
      %{
        "id" => "model-a",
        "efforts" => ["low", "medium"],
        "served_by" => "subscription",
        "choices" => [choice]
      }
    ]

    assert [%{"routing_efforts" => ["medium"]}] = RoutingModels.selectable(served, %{})

    pinned_rows = %{
      "0" => %{
        "key" => "pinned",
        "description" => "Use the approved Profile",
        "model" => Form.model_key(choice),
        "effort" => "medium"
      }
    }

    assert {:ok, saved} =
             Form.policy(nil, pinned_rows, true, RoutingModels.selectable(served, %{}))

    assert hd(saved["entries"])["model"]["profile_id"] == "allowed-pin"
    assert {:ok, json} = Form.export_table(Form.rows(saved))
    assert {:ok, ^pinned_rows} = Form.import_table(json)
    assert [] == RoutingModels.selectable(served, %{"profile_id" => "other-pin"})

    assert [%{"routing_efforts" => ["medium"]}] =
             RoutingModels.selectable(served, %{"profile_id" => "allowed-pin"})

    paid = put_in(served, [Access.at(0), "choices"], [Map.put(choice, "allow_paid", true)])

    assert [%{"key" => key, "routing_efforts" => ["medium"]}] =
             RoutingModels.selectable(paid, %{"profile_id" => "allowed-pin"})

    assert Jason.decode!(key)["allow_paid"]
  end

  test "subscription and paid choices keep their separate effort permissions" do
    base = %{"kind" => "catalog", "model" => "model-a"}

    served = [
      %{
        "id" => "model-a",
        "efforts" => ["low", "high"],
        "served_by" => "subscription",
        "choices" => [
          Map.put(base, "reasoning_effort", "low"),
          Map.merge(base, %{"reasoning_effort" => "high", "allow_paid" => true})
        ]
      }
    ]

    offered = RoutingModels.selectable(served, %{})

    assert [
             %{"key" => "model-a", "routing_efforts" => ["low"]},
             %{"key" => paid, "routing_efforts" => ["high"]}
           ] = offered

    refute Form.valid_row?(%{"model" => "model-a", "effort" => "high"}, offered)
    assert Form.valid_row?(%{"model" => paid, "effort" => "high"}, offered)
  end
end
