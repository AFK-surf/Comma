defmodule SalixStore.LarkSuiteTriageTest do
  use SystemsClock.Case, async: false

  alias SalixStore.{LarkSuiteTriage, Repo}

  @tenant "tnt_lark_triage"
  @at ~U[2026-11-19 08:00:00.000000Z]

  setup do
    Repo.query!(
      "TRUNCATE lark_suite_triage_sources, lark_suite_triage_chats, lark_suite_triage_batches"
    )

    :ok
  end

  defp source(group, connect, attrs \\ %{}) do
    {:ok, source} =
      LarkSuiteTriage.upsert_source(
        Map.merge(
          %{
            tenant_id: @tenant,
            provider: "feishu",
            connect_id: connect,
            group_id: group,
            router_agent_id: "agt_" <> group,
            enabled: true,
            updated_by: "usr_admin"
          },
          attrs
        ),
        now: @at
      )

    source
  end

  defp add(group, connect, chat_id, provider \\ "feishu") do
    LarkSuiteTriage.add_or_enable_chat(
      %{
        tenant_id: @tenant,
        provider: provider,
        connect_id: connect,
        group_id: group,
        chat_id: chat_id,
        chat_name: "研发群"
      },
      now: @at
    )
  end

  test "two Swarms cannot watch one shared group; a paused chat lets the other take it" do
    source("grp_rd", "con_rd")
    source("grp_fin", "con_fin")

    assert {:ok, %{enabled: true}} = add("grp_rd", "con_rd", "oc_shared")

    assert {:error, {:chat_already_claimed, %{group_id: "grp_rd", connect_id: "con_rd"}}} =
             add("grp_fin", "con_fin", "oc_shared")

    # The same chat on the other provider is another chat.
    source("grp_fin", "con_fin_lark", %{provider: "lark"})
    assert {:ok, _chat} = add("grp_fin", "con_fin_lark", "oc_shared", "lark")

    assert {:ok, %{enabled: false}} =
             LarkSuiteTriage.set_chat_enabled(@tenant, "feishu", "con_rd", "oc_shared", false)

    assert {:ok, %{enabled: true}} = add("grp_fin", "con_fin", "oc_shared")

    # Resuming the first one is now refused, naming the new holder.
    assert {:error, {:chat_already_claimed, %{group_id: "grp_fin"}}} =
             LarkSuiteTriage.set_chat_enabled(@tenant, "feishu", "con_rd", "oc_shared", true)

    assert :none =
             LarkSuiteTriage.active_source_for_chat(@tenant, "feishu", "con_rd", "oc_shared")

    assert {:ok, %{source: %{group_id: "grp_fin", router_agent_id: "agt_grp_fin"}}} =
             LarkSuiteTriage.active_source_for_chat(@tenant, "feishu", "con_fin", "oc_shared")

    assert {:ok, [rd]} = LarkSuiteTriage.list_group_sources(@tenant, "grp_rd")
    assert [%{chat_id: "oc_shared", enabled: false}] = rd.chats
  end

  test "a source switched off watches nothing" do
    source("grp_rd", "con_rd")
    {:ok, _chat} = add("grp_rd", "con_rd", "oc_rd")
    source("grp_rd", "con_rd", %{enabled: false})
    assert :none = LarkSuiteTriage.active_source_for_chat(@tenant, "feishu", "con_rd", "oc_rd")
  end

  for provider <- ~w(feishu lark) do
    @provider provider

    test "#{provider}: disabling a source releases its chats so another Swarm can claim them" do
      source("grp_rd", "con_rd", %{provider: @provider})
      source("grp_fin", "con_fin", %{provider: @provider})

      assert {:ok, %{enabled: true}} = add("grp_rd", "con_rd", "oc_shared", @provider)

      assert {:error, {:chat_already_claimed, %{group_id: "grp_rd", connect_id: "con_rd"}}} =
               add("grp_fin", "con_fin", "oc_shared", @provider)

      # Turning off Swarm A's source without disabling individual chats frees the group.
      source("grp_rd", "con_rd", %{provider: @provider, enabled: false})

      assert {:ok, %{enabled: true}} = add("grp_fin", "con_fin", "oc_shared", @provider)

      # Re-enabling Swarm A's source does not reclaim the group from Swarm B.
      source("grp_rd", "con_rd", %{provider: @provider, enabled: true})

      assert :none =
               LarkSuiteTriage.active_source_for_chat(@tenant, @provider, "con_rd", "oc_shared")

      assert {:ok, %{source: %{group_id: "grp_fin", router_agent_id: "agt_grp_fin"}}} =
               LarkSuiteTriage.active_source_for_chat(@tenant, @provider, "con_fin", "oc_shared")

      # Swarm A trying to re-enable the chat is rejected with Swarm B as owner.
      assert {:error, {:chat_already_claimed, %{group_id: "grp_fin", connect_id: "con_fin"}}} =
               LarkSuiteTriage.set_chat_enabled(@tenant, @provider, "con_rd", "oc_shared", true)

      # When Swarm B turns off its source, Swarm A can resume the chat via set_chat_enabled.
      source("grp_fin", "con_fin", %{provider: @provider, enabled: false})

      assert {:ok, %{enabled: true}} =
               LarkSuiteTriage.set_chat_enabled(@tenant, @provider, "con_rd", "oc_shared", true)

      assert {:ok, %{source: %{group_id: "grp_rd"}}} =
               LarkSuiteTriage.active_source_for_chat(@tenant, @provider, "con_rd", "oc_shared")
    end
  end

  defp context(thread \\ "") do
    %{
      tenant_id: @tenant,
      provider: "lark",
      group_id: "grp_rd",
      connect_id: "con_rd",
      router_agent_id: "agt_grp_rd",
      chat_id: "oc_rd",
      chat_name: "研发群",
      thread_key: thread
    }
  end

  defp message(id, at_ms, text \\ "hello"),
    do: %{message_id: id, sender_id: "ou_" <> id, sender_name: "", text: text, sent_at_ms: at_ms}

  defp at(ms), do: [now: DateTime.add(@at, ms, :millisecond)]

  test "messages of one thread in the window merge; duplicates and credentials are dropped" do
    assert {:ok, :appended, id} =
             LarkSuiteTriage.append_ambient_message(
               context(),
               message("om_1", 1, "token Bearer sk-live-123 please"),
               at(0)
             )

    assert {:ok, :appended, ^id} =
             LarkSuiteTriage.append_ambient_message(context(), message("om_2", 2), at(1_000))

    assert {:ok, :duplicate, nil} =
             LarkSuiteTriage.append_ambient_message(context(), message("om_1", 1), at(1_500))

    # Another thread of the chat is its own batch.
    assert {:ok, :appended, other} =
             LarkSuiteTriage.append_ambient_message(
               context("omt_1"),
               message("om_3", 3),
               at(1_500)
             )

    assert other != id

    # The window closes 3 s after the last message.
    assert {:ok, []} = LarkSuiteTriage.claim_due_batches("w1", 8, at(3_500))
    assert {:ok, [batch, _other]} = LarkSuiteTriage.claim_due_batches("w1", 8, at(4_600))
    assert batch.id == id
    assert batch.target_message_id == "om_2"
    assert batch.message_ids == ["om_1", "om_2"]
    assert [%{"text" => "token [Bearer-credential withheld] please"}, _] = batch.messages_json

    # A claimed batch is not claimed again while its lease holds.
    assert {:ok, []} = LarkSuiteTriage.claim_due_batches("w2", 8, at(5_000))

    # A message after the claim starts a new batch, which makes the claimed one stale.
    assert {:ok, :appended, newer} =
             LarkSuiteTriage.append_ambient_message(context(), message("om_4", 4), at(5_000))

    assert newer != id
    assert LarkSuiteTriage.newer_pending?(batch)

    assert :ok =
             LarkSuiteTriage.complete_batch(
               id,
               "w1",
               %{state: "stale", decision_kind: "reply", reason_code: "superseded"},
               at(5_100)
             )

    assert {:error, :lease_lost} =
             LarkSuiteTriage.complete_batch(id, "w1", %{state: "applied"}, at(5_200))
  end

  test "a batch keeps the newest ten messages" do
    for n <- 1..12 do
      {:ok, :appended, _id} =
        LarkSuiteTriage.append_ambient_message(context(), message("om_#{n}", n), at(n))
    end

    assert {:ok, [batch]} = LarkSuiteTriage.claim_due_batches("w1", 8, at(10_000))
    assert length(batch.messages_json) == 10
    assert hd(batch.messages_json)["message_id"] == "om_3"
    assert batch.target_message_id == "om_12"
  end

  test "the timeline lists settled batches without text; the reveal read has it" do
    {:ok, :appended, id} =
      LarkSuiteTriage.append_ambient_message(context(), message("om_1", 1, "secret plan"), at(0))

    {:ok, [_batch]} = LarkSuiteTriage.claim_due_batches("w1", 8, at(4_000))

    :ok =
      LarkSuiteTriage.complete_batch(
        id,
        "w1",
        %{
          state: "applied",
          decision_kind: "reply",
          reply_text: "Here is the plan.",
          messages_json: [
            %{
              "message_id" => "om_1",
              "sender_id" => "ou_om_1",
              "sender_name" => "王小明",
              "text" => "secret plan",
              "sent_at_ms" => 1
            }
          ]
        },
        at(4_100)
      )

    assert {:ok, %{items: [item], next_cursor: nil}} =
             LarkSuiteTriage.list_activity(@tenant, "agt_grp_rd", kind: "reply")

    refute Map.has_key?(item, :reply_text)
    assert [%{"sender_name" => "王小明"} = listed] = item.messages_json
    refute Map.has_key?(listed, "text")

    assert {:ok, %{items: []}} =
             LarkSuiteTriage.list_activity(@tenant, "agt_grp_rd", kind: "silence")

    assert {:ok, %{items: []}} = LarkSuiteTriage.list_activity(@tenant, "agt_other")

    assert {:ok, %{messages_json: [%{"text" => "secret plan"}], reply_text: "Here is the plan."}} =
             LarkSuiteTriage.get_batch_for_reveal(@tenant, "agt_grp_rd", id)

    assert {:error, :not_found} = LarkSuiteTriage.get_batch_for_reveal(@tenant, "agt_other", id)
  end
end
