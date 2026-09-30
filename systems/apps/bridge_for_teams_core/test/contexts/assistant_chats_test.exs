defmodule BridgeForTeams.AssistantChatsTest do
  @moduledoc """
  The New Home chat rail binds one durable Salix conversation per (user,
  project): `ensure_chat/4` creates the conversation against the given swarm's
  current group router on first use and reuses it after, different swarms (and
  the same user in another org) keep isolated threads, and a caller that
  resolved no board project gets `{:error, :no_project}` — never an arbitrary
  org project.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{
    Accounts,
    Agents,
    AssistantChats,
    Memberships,
    Observability,
    Orgs,
    Repo
  }

  alias BridgeForTeams.Schema.UserAssistantChat

  # Scripted Salix client: `:test_ac_conversations` collects the
  # create-conversation calls so tests can count and inspect them.
  defmodule ScriptedClient do
    use BridgeForTeams.TestSupport.CanonicalAgentClient

    @moduledoc false
    @table __MODULE__

    def reset! do
      ensure_table!()
      :ets.delete_all_objects(@table)
      :ok
    end

    def ensure_group_conversation_provider_participant(group_id, conversation_id, attrs) do
      participant =
        attrs
        |> Map.take(
          ~w(actor_type provider target_key role_label state notification_filter payload)
        )
        |> Map.put("participant_id", SalixStore.Ids.new_participant_id())
        |> Map.put("conversation_id", conversation_id)

      key = participant_key(group_id, conversation_id, participant)

      if :ets.insert_new(@table, {key, participant}) do
        {:ok, participant}
      else
        [{^key, existing}] = :ets.lookup(@table, key)
        {:ok, existing}
      end
    end

    def create_group_conversation(group_id, attrs) do
      ensure_table!()
      request_id = attrs["client_request_id"]

      conversation_id =
        if Application.get_env(:bridge_for_teams_core, :test_ac_disable_create_idempotency) do
          SalixStore.Ids.new_conversation_id()
        else
          request_key = {:create_request, group_id, request_id}
          candidate = SalixStore.Ids.new_conversation_id()
          _ = :ets.insert_new(@table, {request_key, candidate})
          [{^request_key, persisted}] = :ets.lookup(@table, request_key)
          persisted
        end

      conversation = %{
        "conversation_id" => conversation_id,
        "agent_group_id" => group_id,
        "kind" =>
          Application.get_env(
            :bridge_for_teams_core,
            :test_ac_created_conversation_kind,
            attrs["kind"]
          ),
        "status" => "active"
      }

      _ = :ets.insert_new(@table, {{:conversation, group_id, conversation_id}, conversation})

      Enum.each(List.wrap(attrs["participants"]), fn participant ->
        :ets.insert_new(
          @table,
          {participant_key(group_id, conversation_id, participant), participant}
        )
      end)

      sequence =
        :ets.update_counter(@table, :create_call_sequence, {2, 1}, {:create_call_sequence, 0})

      true = :ets.insert(@table, {{:create_call, sequence}, {group_id, attrs, conversation_id}})

      {:ok, conversation}
    end

    def get_group_conversation(group_id, conversation_id) do
      case Application.get_env(:bridge_for_teams_core, :test_ac_get_conversation_response) do
        nil ->
          case :ets.lookup(@table, {:conversation, group_id, conversation_id}) do
            [{{:conversation, ^group_id, ^conversation_id}, conversation}] -> {:ok, conversation}
            [] -> {:error, :not_found}
          end

        response ->
          response
      end
    end

    def list_group_conversation_participants(group_id, conversation_id, opts) do
      case Application.get_env(:bridge_for_teams_core, :test_ac_participant_response) do
        nil ->
          with {:ok, _conversation} <- get_group_conversation(group_id, conversation_id) do
            participants = participants(group_id, conversation_id)
            limit = Keyword.get(opts, :limit, 50)
            offset = decode_cursor(Keyword.get(opts, :cursor))
            page = Enum.slice(participants, offset, limit)
            next_offset = offset + length(page)
            has_more = next_offset < length(participants)

            result = %{"participants" => page, "has_more" => has_more}

            result =
              if has_more,
                do: Map.put(result, "next_cursor", encode_cursor(next_offset)),
                else: result

            {:ok, result}
          end

        response ->
          response
      end
    end

    def append_group_conversation_message(_group_id, conversation_id, attrs) do
      if Application.get_env(:bridge_for_teams_core, :test_ac_fail_append) do
        {:error, :unavailable}
      else
        sent = Application.get_env(:bridge_for_teams_core, :test_ac_messages, [])

        Application.put_env(:bridge_for_teams_core, :test_ac_messages, [
          {conversation_id, attrs} | sent
        ])

        {:ok,
         %{
           "conversation_id" => conversation_id,
           "message_id" => SalixStore.Ids.new_message_id(),
           "delivery_status" => "queued",
           "inserted" => true
         }}
      end
    end

    def get_group(group_id) do
      case Application.get_env(:bridge_for_teams_core, :test_ac_group_response) do
        nil -> BridgeForTeams.TestConversationStore.get_group_with_router(group_id)
        response -> response
      end
    end

    # The runtime session list behind `Conversations.conversation_compaction_marker/3`.
    def list_sessions(_agent_id, _opts),
      do: {:ok, Application.get_env(:bridge_for_teams_core, :test_ac_sessions, [])}

    def get_agent_projection(agent_id, _tenant_id) do
      {:ok,
       %{
         "agent_id" => agent_id,
         "role" => "router",
         "router_session_id" => "ses1_0000000000000000001"
       }}
    end

    def conversation_calls do
      ensure_table!()

      @table
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:create_call, sequence}, {group_id, attrs, conversation_id}} ->
          [{sequence, group_id, attrs, conversation_id}]

        _other ->
          []
      end)
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.map(fn {_sequence, group_id, attrs, conversation_id} ->
        {group_id, attrs, conversation_id}
      end)
    end

    def participants(group_id, conversation_id) do
      ensure_table!()

      @table
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{:participant, ^group_id, ^conversation_id, _identity}, participant} -> [participant]
        _other -> []
      end)
      |> Enum.sort_by(& &1["participant_id"])
    end

    def replace_participants(group_id, conversation_id, participants) do
      ensure_table!()

      @table
      |> :ets.tab2list()
      |> Enum.each(fn
        {{:participant, ^group_id, ^conversation_id, _identity} = key, _participant} ->
          :ets.delete(@table, key)

        _other ->
          :ok
      end)

      Enum.each(participants, fn participant ->
        participant =
          participant
          |> Map.put_new("participant_id", SalixStore.Ids.new_participant_id())
          |> Map.put_new("conversation_id", conversation_id)

        true =
          :ets.insert(
            @table,
            {participant_key(group_id, conversation_id, participant), participant}
          )
      end)

      :ok
    end

    def update_conversation(group_id, conversation_id, attrs) do
      key = {:conversation, group_id, conversation_id}
      [{^key, conversation}] = :ets.lookup(@table, key)
      updated = Map.merge(conversation, attrs)
      true = :ets.insert(@table, {key, updated})
      updated
    end

    defp participant_key(group_id, conversation_id, participant) do
      identity =
        case participant["actor_type"] do
          "agent" -> {:agent, participant["agent_id"]}
          "provider" -> {:provider, participant["provider"], participant["target_key"]}
          "user" -> {:user, participant["user_id"]}
          other -> {other, participant["participant_id"]}
        end

      {:participant, group_id, conversation_id, identity}
    end

    defp encode_cursor(offset),
      do: offset |> Integer.to_string() |> Base.url_encode64(padding: false)

    defp decode_cursor(nil), do: 0
    defp decode_cursor(""), do: 0

    defp decode_cursor(cursor) do
      with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
           {offset, ""} <- Integer.parse(encoded) do
        offset
      else
        _ -> 0
      end
    end

    defp ensure_table! do
      case :ets.whereis(@table) do
        :undefined ->
          try do
            :ets.new(@table, [
              :named_table,
              :public,
              read_concurrency: true,
              write_concurrency: true
            ])
          rescue
            ArgumentError -> @table
          end

        table ->
          table
      end
    end
  end

  setup do
    prev = Application.get_env(:bridge_for_teams_core, :salix_client)
    Application.put_env(:bridge_for_teams_core, :salix_client, ScriptedClient)
    ScriptedClient.reset!()

    on_exit(fn ->
      if prev do
        Application.put_env(:bridge_for_teams_core, :salix_client, prev)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end

      Application.delete_env(:bridge_for_teams_core, :test_ac_conversations)
      Application.delete_env(:bridge_for_teams_core, :test_ac_messages)
      Application.delete_env(:bridge_for_teams_core, :test_ac_participants)
      Application.delete_env(:bridge_for_teams_core, :test_ac_sessions)
      Application.delete_env(:bridge_for_teams_core, :test_ac_fail_append)
      Application.delete_env(:bridge_for_teams_core, :test_ac_group_response)
      Application.delete_env(:bridge_for_teams_core, :test_ac_disable_create_idempotency)
      Application.delete_env(:bridge_for_teams_core, :test_ac_created_conversation_kind)
      Application.delete_env(:bridge_for_teams_core, :test_ac_get_conversation_response)
      Application.delete_env(:bridge_for_teams_core, :test_ac_participant_response)
    end)

    {:ok, user} = Accounts.create_user(%{"email" => "chatter@example.com", "name" => "Chatter"})
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-chats"})
    {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        org.id,
        %{"name" => "Alpha", "slug" => "alpha"},
        creator_user_id: user.id
      )

    %{user: user, org: org, project: project}
  end

  defp conversation_calls, do: ScriptedClient.conversation_calls()

  test "creates one binding per (user, project) and reuses the same thread", %{
    user: user,
    org: org,
    project: project
  } do
    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    assert {:ok, worker} =
             BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
               project.id,
               %{
                 "name" => "A Worker",
                 "role" => "worker",
                 "slot" => "worker"
               }
             )

    assert List.first(Agents.list_agents(project.id)).id == worker.id

    assert {:ok, %{binding: binding, project: ^project, agent: agent}} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    assert binding.user_id == user.id
    assert binding.org_id == org.id
    assert binding.project_id == project.id
    assert agent.id == router.id
    assert is_binary(binding.conversation_id)
    assert [{group_id, attrs, _conversation_id}] = conversation_calls()
    assert group_id == project.salix_group_id
    assert attrs["kind"] == "user_chat"
    assert attrs["owner_user_id"] == user.id
    assert attrs["created_by_user_id"] == user.id

    assert %{"agent_id" => router_agent_id} =
             Enum.find(attrs["participants"], &(&1["actor_type"] == "agent"))

    assert router_agent_id == router.salix_agent_id
    refute router_agent_id == worker.salix_agent_id

    # Second visit: same binding, no second Salix conversation.
    assert {:ok, %{binding: again}} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert again.id == binding.id
    assert again.conversation_id == binding.conversation_id
    assert length(conversation_calls()) == 1

    assert {:ok, found} = AssistantChats.get_binding(user.id, project.id)
    assert found.id == binding.id
  end

  test "revalidates canonical kind, current Router, and BFT provider before reuse", %{
    user: user,
    org: org,
    project: project
  } do
    router_r1 = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))

    assert {:ok, %{binding: first}} = AssistantChats.ensure_chat(user.id, org.id, project)

    assert required_participants?(
             ScriptedClient.participants(project.salix_group_id, first.conversation_id),
             router_r1.salix_agent_id
           )

    ScriptedClient.update_conversation(project.salix_group_id, first.conversation_id, %{
      "kind" => "agent_task"
    })

    assert {:ok, %{binding: after_kind_replacement}} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    refute after_kind_replacement.conversation_id == first.conversation_id

    ScriptedClient.replace_participants(
      project.salix_group_id,
      after_kind_replacement.conversation_id,
      [
        %{
          "actor_type" => "agent",
          "agent_id" => router_r1.salix_agent_id,
          "state" => "active"
        }
      ]
    )

    assert {:ok, %{binding: after_provider_replacement}} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    refute after_provider_replacement.conversation_id == after_kind_replacement.conversation_id

    assert {:ok, router_r2} =
             BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_agent(
               project.id,
               %{
                 "name" => "Replacement Router",
                 "role" => "router",
                 "slot" => "router-r2"
               }
             )

    Application.put_env(
      :bridge_for_teams_core,
      :test_ac_group_response,
      {:ok, %{"router_agent_id" => router_r2.salix_agent_id}}
    )

    assert {:ok, %{binding: rotated, agent: ^router_r2}} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    refute rotated.conversation_id == after_provider_replacement.conversation_id

    assert required_participants?(
             ScriptedClient.participants(project.salix_group_id, rotated.conversation_id),
             router_r2.salix_agent_id
           )

    replacement_request_ids =
      conversation_calls()
      |> Enum.map(fn {_group_id, attrs, _conversation_id} -> attrs["client_request_id"] end)

    assert Enum.any?(
             replacement_request_ids,
             &String.ends_with?(&1, ":replace:#{after_provider_replacement.conversation_id}")
           )
  end

  test "transient canonical reads never replace a valid binding", %{
    user: user,
    org: org,
    project: project
  } do
    assert {:ok, %{binding: binding}} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert length(conversation_calls()) == 1

    Application.put_env(
      :bridge_for_teams_core,
      :test_ac_get_conversation_response,
      {:error, :timeout}
    )

    assert {:error, :timeout} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert length(conversation_calls()) == 1
    assert {:ok, persisted} = AssistantChats.get_binding(user.id, project.id)
    assert persisted.conversation_id == binding.conversation_id

    Application.delete_env(:bridge_for_teams_core, :test_ac_get_conversation_response)

    Application.put_env(
      :bridge_for_teams_core,
      :test_ac_participant_response,
      {:error, :unavailable}
    )

    assert {:error, :unavailable} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert length(conversation_calls()) == 1
    assert {:ok, persisted} = AssistantChats.get_binding(user.id, project.id)
    assert persisted.conversation_id == binding.conversation_id
  end

  test "participant validation follows pagination before deciding a binding is stale", %{
    user: user,
    org: org,
    project: project
  } do
    router = Enum.find(Agents.list_agents(project.id), &(&1.role == "router"))
    assert {:ok, %{binding: binding}} = AssistantChats.ensure_chat(user.id, org.id, project)

    decoys =
      for index <- 1..55 do
        %{
          "participant_id" => "aaa-decoy-#{String.pad_leading(Integer.to_string(index), 3, "0")}",
          "actor_type" => "user",
          "user_id" => "decoy-#{index}",
          "state" => "active"
        }
      end

    required = [
      %{
        "participant_id" => "zzz-router",
        "actor_type" => "agent",
        "agent_id" => router.salix_agent_id,
        "state" => "active"
      },
      %{
        "participant_id" => "zzz-provider",
        "actor_type" => "provider",
        "provider" => "bft",
        "target_key" => "bft",
        "state" => "active"
      }
    ]

    :ok =
      ScriptedClient.replace_participants(
        project.salix_group_id,
        binding.conversation_id,
        decoys ++ required
      )

    assert {:ok, %{binding: reused}} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert reused.conversation_id == binding.conversation_id
    assert length(conversation_calls()) == 1
  end

  test "malformed first and replacement candidates advance the durable replacement seed", %{
    user: user,
    org: org,
    project: project
  } do
    Application.put_env(
      :bridge_for_teams_core,
      :test_ac_created_conversation_kind,
      "agent_task"
    )

    assert {:error, :invalid_salix_chat_candidate} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    assert {:ok, first_marker} = AssistantChats.get_binding(user.id, project.id)
    assert first_marker.disposition == "replace_invalid_salix_candidate"
    assert first_marker.replacement_seed_conversation_id == first_marker.conversation_id

    assert {:error, :invalid_salix_chat_candidate} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    assert {:ok, second_marker} = AssistantChats.get_binding(user.id, project.id)

    refute second_marker.replacement_seed_conversation_id ==
             first_marker.replacement_seed_conversation_id

    assert {:error, :invalid_salix_chat_candidate} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    assert {:ok, third_marker} = AssistantChats.get_binding(user.id, project.id)

    refute third_marker.replacement_seed_conversation_id ==
             second_marker.replacement_seed_conversation_id

    calls = Enum.reverse(conversation_calls())

    assert [{_group, first, first_id}, {_group, second, second_id}, {_group, third, _third_id}] =
             calls

    assert first["client_request_id"] == "bft-assistant-chat:#{project.id}:#{user.id}"
    assert String.ends_with?(second["client_request_id"], ":replace:#{first_id}")
    assert String.ends_with?(third["client_request_id"], ":replace:#{second_id}")
  end

  test "concurrent first ensure uses one stable Salix request identity", %{
    user: user,
    org: org,
    project: project
  } do
    conversation_ids =
      1..12
      |> Task.async_stream(
        fn _ ->
          {:ok, %{binding: binding}} = AssistantChats.ensure_chat(user.id, org.id, project)
          binding.conversation_id
        end,
        max_concurrency: 12,
        ordered: false
      )
      |> Enum.map(fn {:ok, conversation_id} -> conversation_id end)

    assert [_one] = Enum.uniq(conversation_ids)
    assert Repo.aggregate(UserAssistantChat, :count) == 1

    request_ids =
      conversation_calls()
      |> Enum.map(fn {_group_id, attrs, _conversation_id} -> attrs["client_request_id"] end)

    assert [_stable_request_id] = Enum.uniq(request_ids)
  end

  test "a losing concurrent candidate receives a durable orphan disposition", %{
    user: user,
    org: org,
    project: project
  } do
    Application.put_env(:bridge_for_teams_core, :test_ac_disable_create_idempotency, true)

    results =
      1..2
      |> Task.async_stream(
        fn _ -> AssistantChats.ensure_chat(user.id, org.id, project) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{binding: %UserAssistantChat{}}}, &1))
    assert Repo.aggregate(UserAssistantChat, :count) == 1

    [event] =
      Observability.list_events(org.id,
        event_type: "assistant_chat.candidate_orphaned",
        project_id: project.id
      )

    assert event.status == "retained_non_serving"

    assert event.evidence["candidate_conversation_id"] !=
             event.evidence["serving_conversation_id"]
  end

  test "two swarms in one org keep separate threads", %{user: user, org: org, project: project} do
    # The member quota allows one created swarm; the second is provisioned
    # server-side with an explicit membership grant.
    {:ok, other} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Beta",
        "slug" => "beta"
      })

    {:ok, _} = BridgeForTeams.Memberships.put_project_member(other.id, user.id, "admin")
    assert {:ok, %{binding: b1}} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert {:ok, %{binding: b2}} = AssistantChats.ensure_chat(user.id, org.id, other)

    assert b1.id != b2.id
    assert b1.conversation_id != b2.conversation_id
    assert length(conversation_calls()) == 2

    # Re-resolving either swarm sticks to its own thread.
    assert {:ok, %{binding: again}} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert again.conversation_id == b1.conversation_id
  end

  test "cross-org isolation: a user in two orgs gets two bindings, no leakage", %{
    user: user,
    org: org,
    project: project
  } do
    {:ok, other_org} = Orgs.create_org(%{name: "Umbra", slug: "umbra-chats"})
    {:ok, _} = Memberships.put_org_member(other_org.id, user.id, "member")

    {:ok, other_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(
        other_org.id,
        %{"name" => "Gamma", "slug" => "gamma"},
        creator_user_id: user.id
      )

    assert {:ok, %{binding: b1}} = AssistantChats.ensure_chat(user.id, org.id, project)

    assert {:ok, %{binding: b2}} =
             AssistantChats.ensure_chat(user.id, other_org.id, other_project)

    assert b1.org_id == org.id
    assert b2.org_id == other_org.id
    assert b1.conversation_id != b2.conversation_id

    # Each conversation was created inside its own org's Salix group.
    groups = conversation_calls() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    assert groups == Enum.sort([project.salix_group_id, other_project.salix_group_id])

    # Coming back to the first org never reuses the other org's thread.
    assert {:ok, %{binding: again}} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert again.conversation_id == b1.conversation_id
    assert Repo.aggregate(UserAssistantChat, :count) == 2
  end

  test "no resolved board project means no chat — not someone else's swarm", %{
    user: user,
    org: org
  } do
    assert {:error, :no_project} = AssistantChats.ensure_chat(user.id, org.id, nil)
    assert conversation_calls() == []
    assert Repo.aggregate(UserAssistantChat, :count) == 0
  end

  test "a configured router with no active BFT agent is an error", %{
    user: user,
    org: org,
    project: project
  } do
    Enum.each(Agents.list_agents(project.id), &archive_agent_fixture!/1)

    assert {:error, :router_agent_not_found} =
             AssistantChats.ensure_chat(user.id, org.id, project)

    assert conversation_calls() == []
    assert Repo.aggregate(UserAssistantChat, :count) == 0
  end

  test "invalid router config creates no chat", %{
    user: user,
    org: org,
    project: project
  } do
    for {router_id, expected_error} <- [
          {nil, :router_not_configured},
          {"  ", :router_not_configured},
          {"agent_missing", :router_agent_not_found}
        ] do
      Application.put_env(
        :bridge_for_teams_core,
        :test_ac_group_response,
        {:ok, %{"router_agent_id" => router_id}}
      )

      assert {:error, ^expected_error} =
               AssistantChats.ensure_chat(user.id, org.id, project)

      assert conversation_calls() == []
      assert Repo.aggregate(UserAssistantChat, :count) == 0
    end
  end

  # ---- durable context: digest + compaction refresh -------------------------------

  defp sent_messages, do: Application.get_env(:bridge_for_teams_core, :test_ac_messages, [])

  defp required_participants?(participants, router_agent_id) do
    Enum.any?(participants, fn participant ->
      participant["actor_type"] == "agent" and participant["agent_id"] == router_agent_id and
        participant["state"] == "active"
    end) and
      Enum.any?(participants, fn participant ->
        participant["actor_type"] == "provider" and participant["provider"] == "bft" and
          participant["target_key"] == "bft" and participant["state"] == "active"
      end)
  end

  defp ensure_with_context(user, org, project, message, digest) do
    AssistantChats.ensure_chat(user.id, org.id, project,
      initial_message: message,
      context_digest: digest
    )
  end

  test "an unchanged context digest sends nothing on revisit", %{
    user: user,
    org: org,
    project: project
  } do
    assert {:ok, %{binding: binding}} = ensure_with_context(user, org, project, "ctx v1", "d1")
    assert binding.context_digest == "d1"
    assert binding.context_summary_seq == 0
    assert length(sent_messages()) == 1

    assert {:ok, %{binding: again}} = ensure_with_context(user, org, project, "ctx v1", "d1")
    assert again.context_digest == "d1"
    # Still only the creation-time context message.
    assert length(sent_messages()) == 1
  end

  test "a digest drift re-sends the context into the existing conversation", %{
    user: user,
    org: org,
    project: project
  } do
    assert {:ok, %{binding: binding}} = ensure_with_context(user, org, project, "ctx v1", "d1")

    assert {:ok, %{binding: updated}} = ensure_with_context(user, org, project, "ctx v2", "d2")

    assert updated.id == binding.id
    assert updated.context_digest == "d2"
    # One create-time send plus one refresh, both into the SAME conversation.
    assert [{conv_b, refresh}, {conv_a, _initial}] = sent_messages()
    assert conv_a == binding.conversation_id
    assert conv_b == binding.conversation_id
    assert [%{"text" => "ctx v2"}] = refresh["content"]
    assert length(conversation_calls()) == 1
  end

  test "a compaction of the chat session does NOT re-send the context", %{
    user: user,
    org: org,
    project: project
  } do
    # The router session is shared across the swarm's conversations and
    # compacts routinely while workers churn — a compaction-triggered
    # re-send degenerated into one context message per page refresh.
    assert {:ok, %{binding: binding}} = ensure_with_context(user, org, project, "ctx v1", "d1")

    Application.put_env(:bridge_for_teams_core, :test_ac_sessions, [
      %{"session_id" => "ses1_0000000000000000001", "summary_sequence" => 1}
    ])

    assert {:ok, %{binding: same}} = ensure_with_context(user, org, project, "ctx v1", "d1")
    assert same.id == binding.id
    # Still only the creation-time context message.
    assert length(sent_messages()) == 1
  end

  test "a pre-tracking binding (NULL digest) refreshes once on the next visit", %{
    user: user,
    org: org,
    project: project
  } do
    assert {:ok, %{binding: binding}} = AssistantChats.ensure_chat(user.id, org.id, project)
    assert binding.context_digest == nil

    assert {:ok, %{binding: updated}} = ensure_with_context(user, org, project, "ctx v1", "d1")
    assert updated.context_digest == "d1"
    assert [{conv, _refresh}] = sent_messages()
    assert conv == binding.conversation_id

    assert {:ok, _} = ensure_with_context(user, org, project, "ctx v1", "d1")
    assert length(sent_messages()) == 1
  end

  test "a failed refresh send leaves the binding untouched so the next visit retries", %{
    user: user,
    org: org,
    project: project
  } do
    assert {:ok, %{binding: binding}} = ensure_with_context(user, org, project, "ctx v1", "d1")

    Application.put_env(:bridge_for_teams_core, :test_ac_fail_append, true)
    assert {:ok, %{binding: unchanged}} = ensure_with_context(user, org, project, "ctx v2", "d2")
    assert unchanged.context_digest == "d1"

    Application.delete_env(:bridge_for_teams_core, :test_ac_fail_append)
    assert {:ok, %{binding: updated}} = ensure_with_context(user, org, project, "ctx v2", "d2")
    assert updated.context_digest == "d2"
    assert updated.id == binding.id
  end
end
