defmodule SalixIM.TaskLabelsTest do
  use ExUnit.Case, async: false

  alias SalixIM.{ConversationInput, ConversationServer, Conversations, TaskLabels}
  alias SalixStore.Ids

  setup do
    SalixIM.TestSupport.Fleet.stop_all!()

    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_placement = Application.get_env(:salix_im, :conversation_placement)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    Application.put_env(
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

  test "first read seeds the default catalog once", %{group_id: group_id} do
    assert {:ok, %{"labels" => labels, "proposals" => [], "colors" => colors}} =
             TaskLabels.list(group_id)

    assert Enum.map(labels, & &1["name"]) == ["Work", "Personal", "Research", "Urgent"]
    assert Enum.all?(labels, &Ids.valid_task_label_id?(&1["id"]))
    assert Enum.all?(labels, &(&1["color"] in colors))

    assert {:ok, %{"labels" => again}} = TaskLabels.list(group_id)
    assert again == labels
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

  test "rejecting a proposal leaves the catalog untouched", %{group_id: group_id, router: router} do
    {:ok, %{"labels" => [first | _]}} = TaskLabels.list(group_id)

    assert {:ok, proposal} =
             TaskLabels.propose(
               group_id,
               %{"op" => "delete", "payload" => %{"label_id" => first["id"]}},
               %{"agent_id" => router["agent_id"]}
             )

    assert {:ok, %{"labels" => labels, "proposal" => %{"status" => "rejected"}}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "reject")

    assert Enum.any?(labels, &(&1["id"] == first["id"]))
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

  test "apply proposals reject unknown Conversations and malformed ids", %{
    group_id: group_id,
    router: router
  } do
    actor = %{"agent_id" => router["agent_id"]}

    assert {:error, {:bad_request, _}} =
             TaskLabels.propose(
               group_id,
               %{"op" => "apply", "payload" => %{"conversation_id" => "nope", "label_ids" => []}},
               actor
             )

    assert {:error, :not_found} =
             TaskLabels.propose(
               group_id,
               %{
                 "op" => "apply",
                 "payload" => %{"conversation_id" => Ids.new_conversation_id(), "label_ids" => []}
               },
               actor
             )

    assert {:error, {:bad_request, _}} =
             TaskLabels.propose(group_id, %{"op" => "rename", "payload" => %{}}, actor)
  end

  test "known_label_ids? answers against the seeded catalog", %{group_id: group_id} do
    {:ok, %{"labels" => [first | _]}} = TaskLabels.list(group_id)

    assert TaskLabels.known_label_ids?(group_id, [first["id"]])
    refute TaskLabels.known_label_ids?(group_id, [first["id"], Ids.new_task_label_id()])
    assert TaskLabels.known_label_ids?(group_id, [])
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  test "agent proposals must state the rule and refuse duplicate names", %{
    group_id: group_id,
    router: router
  } do
    actor = %{"agent_id" => router["agent_id"], "session_id" => "ses1_test"}
    propose = fn attrs -> TaskLabels.propose(group_id, attrs, actor) end

    assert {:error, {:bad_request, message}} =
             propose.(%{"op" => "create", "payload" => %{"name" => "Finance"}})

    assert message =~ "description is required"

    assert {:ok, %{"labels" => [work | _]}} = TaskLabels.list(group_id)

    assert {:error, {:bad_request, blank}} =
             propose.(%{
               "op" => "update",
               "payload" => %{"label_id" => work["id"], "description" => "  "}
             })

    assert blank =~ "cannot be blank"

    assert {:error, {:conflict, exists}} =
             propose.(%{
               "op" => "create",
               "payload" => %{
                 "name" => String.upcase(work["name"]),
                 "description" => "Add when …"
               }
             })

    assert exists =~ "already exists"

    assert {:ok, _pending} =
             propose.(%{
               "op" => "create",
               "payload" => %{
                 "name" => "Finance",
                 "description" => "Add when money moves; skip otherwise."
               }
             })

    assert {:error, {:conflict, proposed}} =
             propose.(%{
               "op" => "create",
               "payload" => %{
                 "name" => "finance",
                 "description" => "Add when money moves; skip otherwise."
               }
             })

    assert proposed =~ "already proposed"
  end

  test "a proposal remembers the conversation it was proposed from", %{
    group_id: group_id,
    router: router
  } do
    conversation_id = Ids.new_conversation_id()

    actor = %{
      "agent_id" => router["agent_id"],
      "session_id" => "ses1_test",
      "source_conversation_id" => conversation_id
    }

    payload = %{
      "name" => "Reviews",
      "color" => "purple",
      "description" => "Add when the Task asks for a review; skip when it only mentions one."
    }

    assert {:ok, proposal} =
             TaskLabels.propose(group_id, %{"op" => "create", "payload" => payload}, actor)

    assert proposal["source_conversation_id"] == conversation_id
    assert proposal["proposed_by"] == Map.take(actor, ~w(agent_id session_id))

    assert {:ok, %{"proposals" => listed}} = TaskLabels.list(group_id)

    assert Enum.find(listed, &(&1["id"] == proposal["id"]))["source_conversation_id"] ==
             conversation_id

    # A malformed id is dropped rather than stored.
    assert {:ok, orphan} =
             TaskLabels.propose(
               group_id,
               %{"op" => "create", "payload" => Map.put(payload, "name", "Orphan")},
               Map.put(actor, "source_conversation_id", "not-a-conversation")
             )

    refute Map.has_key?(orphan, "source_conversation_id")
  end

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

  test "a batch collision rolls back all labels and the auto approval grant", context do
    %{group_id: group_id, router: router} = context
    assert {:ok, proposal} = TaskLabels.propose(group_id, batch(nil), actor(router))
    assert {:ok, _} = TaskLabels.create(group_id, %{"name" => "Budget"})

    assert {:error, {:conflict, _}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], %{
               "decision" => "approve",
               "auto_approve" => true
             })

    assert {:ok, %{"approval_policy" => "ask", "labels" => labels, "proposals" => [pending]}} =
             TaskLabels.list(group_id)

    assert pending["status"] == "pending"
    refute Enum.any?(labels, &(&1["name"] == "Invoices"))
    assert length(labels) == 5
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

  test "concurrent transport retries share one proposal while competing names are rejected",
       context do
    %{group_id: group_id, router: router} = context
    actor = Map.put(actor(router), "tool_call_id", "label-call-1")

    results =
      1..2
      |> Task.async_stream(fn _ -> TaskLabels.propose(group_id, batch(nil), actor) end)
      |> Enum.to_list()

    assert [{:ok, {:ok, first}}, {:ok, {:ok, second}}] = results
    assert first["id"] == second["id"]
    assert {:ok, %{"proposals" => [_only]}} = TaskLabels.list(group_id)
    assert {:error, {:conflict, _}} = TaskLabels.propose(group_id, single("Different"), actor)

    assert {:error, {:conflict, _}} =
             TaskLabels.propose(
               group_id,
               batch(nil),
               Map.put(actor, "tool_call_id", "label-call-2")
             )
  end

  test "failed Task writes retain approved labels and an explicit retry uses the same ids",
       context do
    %{group_id: group_id, router: router} = context
    conversation_id = create_task!(context)
    assert {:ok, proposal} = TaskLabels.propose(group_id, batch(conversation_id), actor(router))
    key = SalixStore.Keys.ctl_group_conversation_meta(group_id, conversation_id)
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

    assert {:ok, %{"proposal" => failed, "labels" => labels}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert failed["status"] == "approved"
    assert failed["application_status"] == "pending"
    assert is_binary(failed["application_error"])
    assert length(labels) == 6
    ids = Enum.map(failed["payload"]["labels"], & &1["id"])

    assert {:ok, %{"proposal" => retried}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert retried["application_status"] == "applied"
    assert Enum.map(retried["payload"]["labels"], & &1["id"]) == ids
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["labels"] == ids
  end

  test "proposal batches, summaries, and unfinished request counts stay bounded", context do
    %{group_id: group_id, router: router} = context

    labels =
      for index <- 1..17, do: %{"name" => "Label #{index}", "description" => "Add when relevant."}

    assert {:error, {:bad_request, _}} =
             TaskLabels.propose(
               group_id,
               %{"op" => "create", "payload" => %{"labels" => labels}},
               actor(router)
             )

    assert {:error, {:bad_request, _}} =
             TaskLabels.propose(
               group_id,
               Map.put(single("Long summary"), "summary", String.duplicate("x", 501)),
               actor(router)
             )

    assert {:error, {:conflict, _}} =
             TaskLabels.propose(
               group_id,
               %{"op" => "create", "payload" => %{"labels" => [hd(labels), hd(labels)]}},
               actor(router)
             )

    for index <- 1..32 do
      assert {:ok, %{"status" => "pending"}} =
               TaskLabels.propose(group_id, single("Pending #{index}"), actor(router))
    end

    assert {:error, {:conflict, _}} =
             TaskLabels.propose(group_id, single("Overflow"), actor(router))

    assert {:ok, %{"proposals" => pending}} = TaskLabels.list(group_id)
    assert length(pending) == 32
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

  test "a successful assignment with a lost acknowledgement stays successful after Task archival",
       context do
    %{group_id: group_id, router: router} = context
    conversation_id = create_task!(context)
    {:ok, proposal} = TaskLabels.propose(group_id, batch(conversation_id), actor(router))

    {:ok, %{"proposal" => applied}} =
      TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert applied["application_status"] == "applied"

    # The owner committed, but its acknowledgement did not reach the catalog.
    {:ok, _} =
      SalixStore.TaskLabels.update(group_id, fn -> %{} end, fn aggregate ->
        Map.update!(aggregate, "proposals", fn proposals ->
          Enum.map(proposals, fn item ->
            if item["id"] == proposal["id"],
              do: Map.put(item, "application_status", "pending"),
              else: item
          end)
        end)
      end)

    {:ok, completed} =
      ConversationServer.update_group_conversation(group_id, conversation_id, %{
        "status" => "completed"
      })

    assert {:ok, archived} =
             ConversationServer.set_task_archived(
               group_id,
               conversation_id,
               :archive,
               completed["updated_at"]
             )

    # Confirming an existing receipt does not mutate the archived Task.
    assert {:ok, %{"proposal" => retried}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert retried["application_status"] == "applied"
    assert retried["payload"] == applied["payload"]
    refute Map.has_key?(retried, "application_error")
    assert {:ok, after_retry} = Conversations.get_group_conversation(group_id, conversation_id)

    assert Map.take(after_retry, ~w(status labels label_revision updated_at)) ==
             Map.take(archived, ~w(status labels label_revision updated_at))
  end

  test "a fresh assignment conflict remains visible after newer approvals fill the history",
       context do
    %{group_id: group_id, router: router} = context
    conversation_id = create_task!(context)
    {:ok, proposal} = TaskLabels.propose(group_id, batch(conversation_id), actor(router))
    key = SalixStore.Keys.ctl_group_conversation_meta(group_id, conversation_id)
    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, key})

    {:ok, %{"proposal" => approved}} =
      TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert approved["application_status"] == "pending"

    for n <- 1..21 do
      {:ok, newer} = TaskLabels.propose(group_id, single("Newer #{n}"), actor(router))
      {:ok, _} = TaskLabels.resolve_proposal(group_id, newer["id"], "approve")
    end

    {:ok, _} =
      ConversationServer.update_group_conversation(group_id, conversation_id, %{"labels" => []})

    assert {:ok, %{"proposal" => result, "proposals" => history}} =
             TaskLabels.resolve_proposal(group_id, proposal["id"], "approve")

    assert result["application_status"] == "conflict"
    assert result["resolved_at"] == approved["resolved_at"]
    assert length(history) == 20
    assert List.last(history)["id"] == proposal["id"]
    assert {:ok, %{"proposals" => ^history}} = TaskLabels.list(group_id)
    assert {:ok, task} = Conversations.get_group_conversation(group_id, conversation_id)
    assert task["labels"] == []
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
