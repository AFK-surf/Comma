defmodule BridgeForTeams.ConversationIdentityMigrationE2ETest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Orgs, Projects, Repo}

  alias BridgeForTeams.Schema.{UserAssistantChat, WorkspaceItem}

  alias SalixStore.{ConversationIdMigration, Ids}

  setup do
    SalixStore.S3.Fake.reset()
    suffix = System.unique_integer([:positive])

    {:ok, org} =
      Orgs.create_org(%{
        "name" => "Conversation migration #{suffix}",
        "slug" => "conversation-migration-#{suffix}"
      })

    {:ok, project} =
      Projects.create_project(org.id, %{
        "name" => "Conversation migration",
        "slug" => "conversation-migration-#{suffix}"
      })

    {:ok, user} =
      Accounts.create_user(%{"email" => "conversation-migration-#{suffix}@example.test"})

    %{org: org, project: project, user: user}
  end

  test "migrates a BFT-only projection and every typed cursor reference", %{
    org: org,
    project: project,
    user: user
  } do
    legacy_conversation_id = "legacy-bft-only"
    legacy_messages = ~w(message-last message-catchup message-pending message-reconciled)

    chat =
      %UserAssistantChat{}
      |> UserAssistantChat.changeset(%{
        user_id: user.id,
        org_id: org.id,
        project_id: project.id,
        conversation_id: legacy_conversation_id
      })
      |> Repo.insert!()

    item =
      %WorkspaceItem{}
      |> WorkspaceItem.changeset(%{
        user_id: user.id,
        org_id: org.id,
        project_id: project.id,
        title: "Projected task",
        category: "tasks",
        kind: "agent_task",
        platform: "comma",
        status: "in_progress",
        source: "projection",
        salix_conversation_id: legacy_conversation_id,
        source_refs: %{
          "conversation_id" => legacy_conversation_id,
          "message_id" => "provider-message-reference"
        }
      })
      |> Repo.insert!()

    cursor_id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO workspace_item_conversation_cursors (
        id, user_id, org_id, project_id, salix_conversation_id,
        last_seen_message_id, catchup_after_message_id,
        pending_followup_message_ids, reconciled_followup_message_ids,
        created_at, updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(cursor_id),
        Ecto.UUID.dump!(user.id),
        Ecto.UUID.dump!(org.id),
        Ecto.UUID.dump!(project.id),
        legacy_conversation_id,
        "message-last",
        "message-catchup",
        ["message-pending"],
        ["message-reconciled"]
      ]
    )

    assert {:ok, refs} = BridgeForTeams.Migrations.ConversationIdentity.inventory_refs()

    assert [ref] =
             Enum.filter(
               refs,
               &(&1["group_id"] == project.salix_group_id and
                   &1["conversation_id"] == legacy_conversation_id)
             )

    assert MapSet.new(ref["message_ids"]) == MapSet.new(legacy_messages)

    assert {:ok, _stats} =
             SalixStore.Migrations.ConversationIdentity.run(additional_refs: refs)

    assert {:ok, maps} = ConversationIdMigration.read_all()
    map = maps[{project.salix_group_id, legacy_conversation_id}]

    refute map["materialized"]
    target_conversation_id = get_in(map, ["conversation_id", "target"])
    assert Ids.valid_conversation_id?(target_conversation_id)

    target_messages = Map.new(legacy_messages, &{&1, map["message_ids"][&1]})
    assert Enum.all?(Map.values(target_messages), &Ids.valid_message_id?/1)

    assert {:ok, _summary} = BridgeForTeams.Migrations.ConversationIdentity.run(maps)

    migrated_chat = Repo.get!(UserAssistantChat, chat.id)
    migrated_item = Repo.get!(WorkspaceItem, item.id)

    migrated_cursor =
      Repo.query!(
        """
        SELECT salix_conversation_id, last_seen_message_id,
               catchup_after_message_id, pending_followup_message_ids,
               reconciled_followup_message_ids
        FROM workspace_item_conversation_cursors
        WHERE id = $1
        """,
        [Ecto.UUID.dump!(cursor_id)]
      ).rows
      |> List.first()

    assert migrated_chat.conversation_id == target_conversation_id
    assert migrated_item.salix_conversation_id == target_conversation_id
    assert migrated_item.source_refs["conversation_id"] == target_conversation_id
    assert migrated_item.source_refs["message_id"] == "provider-message-reference"

    assert [
             ^target_conversation_id,
             last_seen_message_id,
             catchup_after_message_id,
             pending_followup_message_ids,
             reconciled_followup_message_ids
           ] = migrated_cursor

    assert last_seen_message_id == target_messages["message-last"]
    assert catchup_after_message_id == target_messages["message-catchup"]
    assert pending_followup_message_ids == [target_messages["message-pending"]]

    assert reconciled_followup_message_ids == [
             target_messages["message-reconciled"]
           ]

    assert {:ok, _summary} = BridgeForTeams.Migrations.ConversationIdentity.run(maps)
    assert Repo.get!(WorkspaceItem, item.id).salix_conversation_id == target_conversation_id
  end
end
