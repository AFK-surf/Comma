defmodule BridgeForTeams.WorkspaceImportsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    AssistantChats,
    Agents,
    Conversations,
    Memberships,
    Orgs,
    WorkspaceImports,
    WorkspaceItems
  }

  setup do
    SalixStore.S3.Fake.reset()

    suffix = System.unique_integer([:positive])

    {:ok, org} = Orgs.create_org(%{"name" => "Import #{suffix}", "slug" => "import-#{suffix}"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Board",
        "slug" => "board-#{suffix}"
      })

    [agent | _] = Agents.list_agents(project.id)
    drain_reconcile!()

    {:ok, user} =
      Accounts.create_user(%{"email" => "import-#{suffix}@example.test", "name" => "Import User"})

    {:ok, _} = Memberships.put_org_member(org.id, user.id, "owner")
    {:ok, _} = Memberships.put_project_member(project.id, user.id, "admin")

    %{agent: agent, org: org, project: project, user: user}
  end

  defp drain_reconcile! do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _count} -> drain_reconcile!()
    end
  end

  defp doc(items, extra \\ %{}) do
    Map.merge(
      %{"format" => "bft.myspace.import", "version" => 1, "items" => items},
      extra
    )
  end

  defp item(external_id, overrides \\ %{}) do
    Map.merge(
      %{
        "external_id" => external_id,
        "category" => "email_drafts",
        "title" => "Card #{external_id}"
      },
      overrides
    )
  end

  test "imports create mock_import cards with stamped source refs", %{
    org: org,
    project: project,
    user: user
  } do
    document =
      doc([
        item("mock-1", %{
          "description" => "First",
          "status" => "ready_for_review",
          "platform" => "gmail",
          "labels" => ["demo"],
          "payload" => %{"summary" => "hi"},
          "metadata" => %{"note" => "keep me"}
        })
      ])

    assert {:ok, summary} =
             WorkspaceImports.import_document(user, user, org, project, document)

    assert summary.created == 1
    assert summary.updated == 0
    assert [%{external_id: "mock-1", conversation_id: conv_id}] = summary.items
    assert is_binary(conv_id)

    # Exercise the background projection interleaving deterministically.
    assert {:ok, _} = BridgeForTeams.DashboardProjection.refresh_project(project)

    assert [_ | _] =
             WorkspaceItems.list_tasks(user.id, project_id: project.id, source: "projection")

    [card] = WorkspaceItems.list_tasks(user.id, project_id: project.id, source: "import")
    assert card.category == "email_drafts"
    assert card.status == "ready_for_review"
    assert card.platform == "gmail"
    assert card.labels == ["demo"]
    assert card.source == "import"
    assert card.external_source == "mock_import"
    assert card.external_id == "mock-1"
    assert card.source_refs["source"] == "mock_import"
    assert card.source_refs["import_id"] == "mock-1"
    assert card.payload["summary"] == "hi"
    assert card.metadata["note"] == "keep me"
    assert is_binary(card.salix_conversation_id)
    assert WorkspaceImports.mock_import_item?(card)
  end

  test "re-import is idempotent: matched external_id updates, never duplicates", %{
    org: org,
    project: project,
    user: user
  } do
    assert {:ok, %{created: 1}} =
             WorkspaceImports.import_document(user, user, org, project, doc([item("mock-1")]))

    assert {:ok, summary} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-1", %{"title" => "Renamed", "status" => "done"})])
             )

    assert summary.created == 0
    assert summary.updated == 1

    assert [card] =
             WorkspaceItems.list_tasks(user.id,
               project_id: project.id,
               source: "import",
               include_archived: true
             )

    assert card.title == "Renamed"
    assert card.status == "done"
  end

  test "replace mode archives previously-imported cards absent from the document", %{
    org: org,
    project: project,
    user: user
  } do
    assert {:ok, %{created: 2}} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("keep"), item("drop")])
             )

    assert {:ok, summary} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("keep")], %{"mode" => "replace"})
             )

    assert summary.updated == 1
    assert summary.archived == 1

    live = WorkspaceItems.list_tasks(user.id, project_id: project.id, source: "import")
    assert Enum.map(live, & &1.source_refs["import_id"]) == ["keep"]
  end

  test "messages are appended on create and skipped on update", %{
    org: org,
    project: project,
    user: user
  } do
    messages = [
      %{"role" => "user", "text" => "Draft a reply"},
      %{"role" => "agent", "text" => "Done — draft attached."}
    ]

    assert {:ok, create_summary} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-1", %{"messages" => messages})])
             )

    assert create_summary.messages_appended == 2
    assert create_summary.messages_skipped == 0

    # The card is a local row; the seed creates its transcript conversation
    # behind the generated salix_conversation_id without touching the row.
    [card] = WorkspaceItems.list_tasks(user.id, project_id: project.id, source: "import")
    assert card.category == "email_drafts"
    assert card.title == "Card mock-1"
    assert card.status == "in_progress"

    # The seeded conversation is kind user_chat — the task-chat transcript,
    # not a workspace kind — so the dashboard projection never re-projects it
    # into a duplicate board row.
    assert {:ok, conversation} =
             Conversations.get_project_conversation(project, card.salix_conversation_id)

    assert conversation["kind"] == "user_chat"
    assert conversation["title"] == "Card mock-1"

    assert {:ok, appended} =
             Conversations.list_project_conversation_messages(
               project,
               card.salix_conversation_id
             )

    assert length(appended) == 2
    assert Enum.map(appended, & &1["actor_type"]) == ["provider_user", "agent"]
    assert hd(appended)["provider"] == "bft"
    assert Enum.all?(appended, &(get_in(&1, ["metadata", "source"]) == "mock_import"))

    assert {:ok, update_summary} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-1", %{"messages" => messages})])
             )

    assert update_summary.messages_appended == 0
    assert update_summary.messages_skipped == 2

    assert {:ok, still_two} =
             Conversations.list_project_conversation_messages(
               project,
               card.salix_conversation_id
             )

    assert length(still_two) == 2
  end

  test "assistant_chat is appended once", %{org: org, project: project, user: user} do
    chat = %{
      "messages" => [
        %{"role" => "user", "text" => "What's up?"},
        %{"role" => "agent", "text" => "All good."}
      ]
    }

    assert {:ok, first} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-1")], %{"assistant_chat" => chat})
             )

    assert first.messages_appended == 2

    {:ok, %{binding: binding}} = AssistantChats.ensure_chat(user.id, org.id, project)

    assert {:ok, rail} =
             Conversations.list_project_conversation_messages(project, binding.conversation_id)

    assert Enum.count(rail, &(get_in(&1, ["metadata", "source"]) == "mock_import")) == 2

    assert {:ok, second} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-2")], %{"assistant_chat" => chat})
             )

    assert second.messages_appended == 0
    assert second.messages_skipped == 2

    assert {:ok, unchanged} =
             Conversations.list_project_conversation_messages(project, binding.conversation_id)

    assert Enum.count(unchanged, &(get_in(&1, ["metadata", "source"]) == "mock_import")) == 2
  end

  test "non mock_import cards are never touched", %{
    agent: _agent,
    org: org,
    project: project,
    user: user
  } do
    {:ok, [existing]} =
      WorkspaceItems.create_tasks(user.id, org.id, project.id, [
        %{"title" => "Human card", "category" => "general", "source" => "user"}
      ])

    assert {:ok, _} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-1")], %{"mode" => "replace"})
             )

    assert {:ok, reloaded} = WorkspaceItems.get_task(user.id, existing.id)
    assert reloaded.title == "Human card"
    assert reloaded.status != "archived"
    refute WorkspaceImports.mock_import_item?(reloaded)
  end

  test "imports archive live seed and projection widgets in the imported categories", %{
    org: org,
    project: project,
    user: user
  } do
    assert {:ok, :seeded} =
             WorkspaceItems.ensure_seeded(user.id, org.id, project.id, [
               %{"title" => "Key metrics", "category" => "metrics", "platform" => "comma"},
               %{"title" => "Daily report", "category" => "reports", "platform" => "comma"}
             ])

    assert {:ok, _} = BridgeForTeams.DashboardProjection.refresh_project(project)

    metrics_widgets =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id)
      |> Enum.filter(&(&1.category == "metrics"))

    assert Enum.sort(Enum.map(metrics_widgets, & &1.source)) == ["onboarding", "projection"]

    assert {:ok, summary} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-metrics", %{"category" => "metrics", "title" => "Mock metrics"})])
             )

    assert summary.created == 1
    assert summary.archived == 2

    live = WorkspaceItems.list_tasks(user.id, project_id: project.id)

    assert [metrics_card] = Enum.filter(live, &(&1.category == "metrics"))
    assert metrics_card.source_refs["source"] == "mock_import"

    assert Enum.any?(
             live,
             &(&1.category == "reports" and &1.source_refs["source"] == "workspace_seed")
           )
  end

  test "ensure_seeded skips categories already held by live mock-import cards", %{
    org: org,
    project: project,
    user: user
  } do
    assert {:ok, %{created: 1}} =
             WorkspaceImports.import_document(
               user,
               user,
               org,
               project,
               doc([item("mock-metrics", %{"category" => "metrics", "title" => "Mock metrics"})])
             )

    assert {:ok, :seeded} =
             WorkspaceItems.ensure_seeded(user.id, org.id, project.id, [
               %{"title" => "Key metrics", "category" => "metrics", "platform" => "comma"},
               %{"title" => "Daily report", "category" => "reports", "platform" => "comma"}
             ])

    live = WorkspaceItems.list_tasks(user.id, project_id: project.id)

    metrics_sources =
      live
      |> Enum.filter(&(&1.category == "metrics"))
      |> Enum.map(& &1.source_refs["source"])

    assert metrics_sources == ["mock_import"]

    assert Enum.any?(
             live,
             &(&1.category == "reports" and &1.source_refs["source"] == "workspace_seed")
           )
  end

  describe "transcript seam" do
    defmodule SeedRecordingClient do
      use BridgeForTeams.TestSupport.CanonicalAgentClient

      @moduledoc false
      @store __MODULE__.Store

      alias BridgeForTeams.TestConversationStore
      use TestConversationStore, :group_router

      def create_group_conversation(group_id, attrs),
        do: TestConversationStore.create_group_conversation(@store, group_id, attrs)

      def list_group_conversations(group_id, opts),
        do: TestConversationStore.list_group_conversations(@store, group_id, opts)

      def get_group_conversation(group_id, conversation_id) do
        case TestConversationStore.get_group_conversation(@store, group_id, conversation_id) do
          {:ok, conversation} -> {:ok, Map.delete(conversation, "participants")}
          {:error, _reason} = error -> error
        end
      end

      def list_group_conversation_participants(group_id, conversation_id, opts),
        do:
          TestConversationStore.list_group_conversation_participants(
            @store,
            group_id,
            conversation_id,
            opts
          )

      def update_group_conversation(group_id, conversation_id, attrs),
        do:
          TestConversationStore.update_group_conversation(
            @store,
            group_id,
            conversation_id,
            attrs
          )

      def list_group_conversation_messages(group_id, conversation_id, opts),
        do:
          TestConversationStore.list_group_conversation_messages(
            @store,
            group_id,
            conversation_id,
            opts
          )

      def seed_group_conversation_transcript(group_id, conversation_id, attrs) do
        send(self(), {:seed_transcript, conversation_id, attrs})

        TestConversationStore.seed_group_conversation_transcript(
          @store,
          group_id,
          conversation_id,
          attrs
        )
      end

      def append_group_conversation_message(group_id, conversation_id, attrs) do
        send(self(), {:append_message, conversation_id, attrs})

        TestConversationStore.append_group_conversation_message(
          @store,
          group_id,
          conversation_id,
          attrs
        )
      end

      def get_agent_projection(agent_id, _tenant_id) do
        {:ok,
         %{
           "agent_id" => agent_id,
           "role" => "router",
           "router_session_id" => "ses1_0000000000000000001"
         }}
      end

      def store, do: @store
    end

    setup do
      previous = Application.get_env(:bridge_for_teams_core, :salix_client)
      Application.put_env(:bridge_for_teams_core, :salix_client, SeedRecordingClient)
      BridgeForTeams.TestConversationStore.reset(SeedRecordingClient.store())

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:bridge_for_teams_core, :salix_client)
          value -> Application.put_env(:bridge_for_teams_core, :salix_client, value)
        end
      end)

      :ok
    end

    test "message import uses the seed-transcript call, never the delivery append path", %{
      org: org,
      project: project,
      user: user
    } do
      messages = [
        %{"role" => "user", "text" => "Draft a reply"},
        %{"role" => "agent", "text" => "Done."}
      ]

      assert {:ok, summary} =
               WorkspaceImports.import_document(
                 user,
                 user,
                 org,
                 project,
                 doc(
                   [item("mock-1", %{"messages" => messages})],
                   %{"assistant_chat" => %{"messages" => messages}}
                 )
               )

      assert summary.messages_appended == 4

      # The item transcript and the assistant rail each seed exactly once,
      # delivery-free with cursors advanced, and stamped mock_import.
      assert_received {:seed_transcript, _item_conversation, item_attrs}
      assert_received {:seed_transcript, _rail_conversation, rail_attrs}
      refute_received {:seed_transcript, _other, _extra_attrs}
      refute_received {:append_message, _conversation, _append_attrs}

      # The item transcript conversation is created by the seed as a plain
      # user_chat (a chat transcript, not a workspace kind), so the dashboard
      # projection never re-projects it into a duplicate board row.
      assert item_attrs["conversation"]["kind"] == "user_chat"
      assert item_attrs["conversation"]["title"] == "Card mock-1"

      assert Enum.map(item_attrs["conversation"]["participants"], & &1["actor_type"]) ==
               ["provider", "agent"]

      assert hd(item_attrs["conversation"]["participants"])["provider"] == "bft"
      assert hd(item_attrs["conversation"]["participants"])["target_key"] == "bft"

      for attrs <- [item_attrs, rail_attrs] do
        assert attrs["mark_participants_delivered"] == true
        assert [first, second] = attrs["messages"]
        assert first["actor_type"] == "provider_user"
        assert first["provider"] == "bft"
        assert second["actor_type"] == "agent"
        assert Enum.all?([first, second], &(&1["metadata"]["source"] == "mock_import"))

        assert Enum.all?(
                 [first, second],
                 &(is_binary(&1["client_request_id"]) and &1["client_request_id"] != "")
               )
      end
    end
  end

  describe "validation" do
    test "rejects a disallowed category", %{org: org, project: project, user: user} do
      assert {:error, {:validation, errors}} =
               WorkspaceImports.import_document(
                 user,
                 user,
                 org,
                 project,
                 doc([item("mock-1", %{"category" => "nope"})])
               )

      assert [%{index: 0, external_id: "mock-1", errors: item_errors}] = errors
      assert "category is not allowed" in item_errors
    end

    test "rejects duplicate external_id", %{org: org, project: project, user: user} do
      assert {:error, {:validation, errors}} =
               WorkspaceImports.import_document(
                 user,
                 user,
                 org,
                 project,
                 doc([item("dup"), item("dup")])
               )

      assert Enum.any?(errors, fn %{errors: e} ->
               "external_id must be unique in the document" in e
             end)
    end

    test "rejects more than 100 items and writes nothing", %{
      org: org,
      project: project,
      user: user
    } do
      items = for n <- 1..101, do: item("mock-#{n}")

      assert {:error, {:validation, errors}} =
               WorkspaceImports.import_document(user, user, org, project, doc(items))

      assert Enum.any?(errors, fn %{errors: e} ->
               Enum.any?(e, &String.contains?(&1, "item cap"))
             end)

      assert WorkspaceItems.list_tasks(user.id, project_id: project.id, source: "import") == []
    end

    test "rejects a bad format/version", %{org: org, project: project, user: user} do
      assert {:error, {:validation, errors}} =
               WorkspaceImports.import_document(
                 user,
                 user,
                 org,
                 project,
                 %{"format" => "wrong", "version" => 2, "items" => []}
               )

      flat = Enum.flat_map(errors, & &1.errors)
      assert Enum.any?(flat, &String.contains?(&1, "format"))
      assert Enum.any?(flat, &String.contains?(&1, "version"))
    end
  end
end
