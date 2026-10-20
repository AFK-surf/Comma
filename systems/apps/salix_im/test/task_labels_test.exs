defmodule SalixIM.TaskLabelsTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationInput, ConversationServer, Conversations, TaskLabels}
  alias SalixStore.Ids

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()

    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_placement = SystemsRuntime.get_env(:salix_im, :conversation_placement)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    SystemsRuntime.put_env(
      :salix_im,
      :conversation_placement,
      SalixIM.ConversationPlacement.LocalFleet
    )

    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        restore(:salix_store, :s3_backend, previous_backend)
        restore(:salix_im, :conversation_placement, previous_placement)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Labels"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok, tenant_id: tenant_id, group_id: group_id, router: router}
  end

  test "human create, update, delete round-trip", %{group_id: group_id} do
    assert {:ok, %{"label" => created}} =
             TaskLabels.create(group_id, %{
               "name" => "  Finance ",
               "color" => "SUCCESS",
               "description" => "Invoices"
             })

    assert created["name"] == "Finance"
    assert created["color"] == "success"

    assert {:error, {:conflict, _}} =
             TaskLabels.create(group_id, %{"name" => "finance", "color" => "gray"})

    assert {:error, {:bad_request, _}} =
             TaskLabels.create(group_id, %{"name" => "Bad", "color" => "hotpink"})

    assert {:ok, %{"label" => custom}} =
             TaskLabels.create(group_id, %{"name" => "Custom", "color" => "#E06C75"})

    assert custom["color"] == "#e06c75"

    assert {:ok, %{"label" => updated}} =
             TaskLabels.update(group_id, created["id"], %{"color" => "indigo"})

    assert updated["color"] == "indigo"
    assert updated["name"] == "Finance"
    assert updated["updated_at"] >= created["updated_at"]

    assert {:error, {:bad_request, _}} = TaskLabels.update(group_id, created["id"], %{})

    assert {:ok, %{"labels" => labels}} = TaskLabels.delete(group_id, created["id"])
    refute Enum.any?(labels, &(&1["id"] == created["id"]))
    assert {:error, :not_found} = TaskLabels.delete(group_id, created["id"])
  end

  test "agent proposals stay pending until a human approves them", %{
    group_id: group_id,
    router: router
  } do
    actor = %{"agent_id" => router["agent_id"], "session_id" => "ses1_test"}

    assert {:ok, proposal} =
             TaskLabels.propose(
               group_id,
               %{
                 "op" => "create",
                 "payload" => %{
                   "name" => "Finance",
                   "color" => "success",
                   "description" =>
                     "Add when the Task pays, tracks, or reconciles money; skip when money is only mentioned in passing."
                 },
                 "summary" => "Three invoice tasks share a theme"
               },
               actor
             )

    assert proposal["status"] == "pending"

    assert proposal["proposed_by"] == %{
             "agent_id" => router["agent_id"],
             "session_id" => "ses1_test"
           }

    refute Map.has_key?(proposal, "source_conversation_id")
    assert Ids.valid_task_label_proposal_id?(proposal["id"])

    assert {:ok, %{"labels" => before}} = TaskLabels.list(group_id)
    refute Enum.any?(before, &(&1["name"] == "Finance"))

    assert {:ok, %{"labels" => after_approve, "proposal" => resolved}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert resolved["status"] == "approved"
    assert is_integer(resolved["resolved_at"])
    assert Enum.any?(after_approve, &(&1["name"] == "Finance" and &1["color"] == "success"))

    assert {:error, {:conflict, _}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "reject")
  end

  test "approving an apply proposal writes the Task labels through the Conversation owner",
       %{group_id: group_id, router: router} do
    {:ok, %{"labels" => [work, personal | _]}} = TaskLabels.list(group_id)

    {:ok, %{"conversation_id" => conversation_id}} =
      ConversationInput.create_group_conversation(group_id, %{
        "title" => "Label me",
        "kind" => "agent_task",
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router["agent_id"],
            "role_label" => "delegator",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      })

    assert {:ok, proposal} =
             TaskLabels.propose(
               group_id,
               %{
                 "op" => "apply",
                 "payload" => %{
                   "conversation_id" => conversation_id,
                   "label_ids" => [work["id"], personal["id"], work["id"]]
                 }
               },
               %{"agent_id" => router["agent_id"]}
             )

    assert proposal["payload"]["label_ids"] == [work["id"], personal["id"]]
    assert proposal["payload"]["conversation_title"] == "Label me"

    {:ok, before} = Conversations.get_group_conversation(group_id, conversation_id)
    assert before["labels"] in [nil, []]

    assert {:ok, %{"proposal" => %{"status" => "approved"}}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    {:ok, labeled} = Conversations.get_group_conversation(group_id, conversation_id)
    assert labeled["labels"] == [work["id"], personal["id"]]
  end

  defp restore(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  test "one approval creates a batch and adds every label without replacing existing labels",
       context do
    %{group_id: group_id, router: router} = context
    {:ok, %{"labels" => [work | _]}} = TaskLabels.list(group_id)
    conversation_id = create_task!(context)
    assert {:ok, _} = TaskLabels.assign(group_id, conversation_id, [work["id"]])

    assert {:ok, proposal} = TaskLabels.propose(group_id, batch(conversation_id), actor(router))
    assert proposal["payload"]["expected_label_revision"] == 1
    assert proposal["status"] == "pending"
    assert {:ok, %{"labels" => before}} = TaskLabels.list(group_id)
    assert length(before) == 4

    assert {:ok, %{"proposal" => approved, "labels" => catalog}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert approved["status"] == "approved"
    assert approved["application_status"] == "applied"
    assert length(catalog) == 6
    ids = Enum.map(approved["payload"]["labels"], & &1["id"])
    assert Enum.all?(ids, &Ids.valid_task_label_id?/1)
    assert {:ok, conversation} = Conversations.get_group_conversation(group_id, conversation_id)
    assert conversation["labels"] == [work["id"] | ids]

    assert {:ok, %{"proposal" => ^approved}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert {:ok, same} = Conversations.get_group_conversation(group_id, conversation_id)
    assert same["label_revision"] == conversation["label_revision"]
  end

  test "human auto approval is durable, only affects future proposals, and can be revoked",
       context do
    %{group_id: group_id, router: router, tenant_id: tenant_id} = context
    assert {:ok, %{"approval_policy" => "ask"}} = TaskLabels.list(group_id)
    assert {:ok, older} = TaskLabels.propose(group_id, single("Older"), actor(router))
    assert {:ok, current} = TaskLabels.propose(group_id, single("Current"), actor(router))

    assert {:error, {:bad_request, _}} =
             TaskLabels.resolve_proposal(group_id, current["id"], %{
               "decision" => "reject",
               "auto_approve" => true
             })

    assert {:ok, %{"approval_policy" => "auto"}} =
             TaskLabels.resolve_proposal(
               group_id,
               current["id"],
               %{"decision" => "approve", "auto_approve" => true},
               tenant_id
             )

    assert {:ok, %{"proposals" => proposals}} = TaskLabels.list(group_id)
    assert Enum.find(proposals, &(&1["id"] == older["id"]))["status"] == "pending"

    assert {:ok, %{"status" => "approved"}} =
             TaskLabels.propose(group_id, single("Automatic"), actor(router))

    other_tenant = SalixAgent.TestSupport.new_tenant_id()
    assert {:error, _} = TaskLabels.update_policy(group_id, "ask", other_tenant)
    assert {:ok, %{"approval_policy" => "auto"}} = TaskLabels.list(group_id)

    assert {:ok, %{"approval_policy" => "ask"}} =
             TaskLabels.update_policy(group_id, "ask", tenant_id)

    assert {:ok, %{"status" => "pending"}} =
             TaskLabels.propose(group_id, single("Ask again"), actor(router))
  end

  test "rejecting a create-and-assign batch never writes the Task or enables auto approval",
       context do
    %{group_id: group_id, router: router} = context
    conversation_id = create_task!(context)
    assert {:ok, proposal} = TaskLabels.propose(group_id, batch(conversation_id), actor(router))

    assert {:ok, %{"proposal" => %{"status" => "rejected"}}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "reject")

    assert {:error, {:conflict, _}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert {:ok, %{"labels" => labels, "approval_policy" => "ask"}} = TaskLabels.list(group_id)
    assert length(labels) == 4
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["labels"] in [nil, []]
  end

  test "a lost assignment acknowledgement cannot overwrite a later human edit after owner restart",
       context do
    %{group_id: group_id, router: router} = context
    conversation_id = create_task!(context)
    assert {:ok, proposal} = TaskLabels.propose(group_id, batch(conversation_id), actor(router))

    assert {:ok, %{"proposal" => %{"application_status" => "applied"}}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    # Simulate the response/acknowledgement being lost after the owner committed.
    assert {:ok, _} =
             SalixStore.TaskLabels.update(group_id, fn -> %{} end, fn aggregate ->
               Map.update!(aggregate, "proposals", fn proposals ->
                 Enum.map(proposals, fn item ->
                   if item["id"] == proposal["id"],
                     do: Map.put(item, "application_status", "pending"),
                     else: item
                 end)
               end)
             end)

    assert {:ok, edited} =
             ConversationServer.update_group_conversation(group_id, conversation_id, %{
               "labels" => []
             })

    assert :ok = SalixIM.ConversationFleet.stop(group_id, conversation_id)

    assert {:ok, %{"proposal" => retry, "labels" => catalog}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert retry["status"] == "approved"
    assert retry["application_status"] == "conflict"
    assert length(catalog) == 6
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["labels"] == []
    assert task["label_revision"] == edited["label_revision"]
  end

  defp actor(router), do: %{"agent_id" => router["agent_id"], "session_id" => "ses1_test"}

  defp single(name),
    do: %{
      "op" => "create",
      "payload" => %{
        "labels" => [
          %{
            "name" => name,
            "description" => "Add when the Task concerns this topic; skip unrelated Tasks."
          }
        ]
      }
    }

  defp batch(conversation_id) do
    payload = %{
      "labels" => [
        %{
          "name" => "Invoices",
          "color" => "blue",
          "description" => "Add when processing invoices; skip other documents."
        },
        %{
          "name" => "Budget",
          "color" => "success",
          "description" => "Add when planning a budget; skip unrelated spending."
        }
      ]
    }

    payload =
      if conversation_id, do: Map.put(payload, "conversation_id", conversation_id), else: payload

    %{"op" => "create", "payload" => payload}
  end

  defp create_task!(%{group_id: group_id, router: router}) do
    {:ok, %{"conversation_id" => id}} =
      ConversationInput.create_group_conversation(group_id, %{
        "title" => "Invoice budget",
        "kind" => "agent_task",
        "participants" => [
          %{
            "actor_type" => "agent",
            "agent_id" => router["agent_id"],
            "role_label" => "delegator",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      })

    id
  end
end
