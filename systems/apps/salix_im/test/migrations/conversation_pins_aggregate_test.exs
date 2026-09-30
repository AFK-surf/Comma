defmodule SalixIM.Migrations.ConversationPinsAggregateTest do
  use ExUnit.Case, async: false

  alias SalixIM.Migrations.ConversationPinsAggregate
  alias SalixIM.{Conversations, Release}
  alias SalixStore.{Ids, Keys, S3}

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
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Pin migration"})

    {:ok, %{tenant_id: tenant_id, group_id: group_id}}
  end

  test "hard-cuts legacy pins through the serving owner path and can rerun", %{
    tenant_id: tenant_id,
    group_id: group_id
  } do
    pins =
      for index <- 1..2 do
        assert {:ok, %{"conversation_id" => conversation_id}} =
                 SalixIM.ConversationInput.create_group_conversation(group_id, %{
                   "kind" => "agent_task",
                   "title" => "Legacy pin #{index}"
                 })

        now = System.system_time(:millisecond) + index

        pin = %{
          "agent_group_id" => group_id,
          "conversation_id" => conversation_id,
          "pinned_at" => now,
          "created_at" => now,
          "updated_at" => now
        }

        assert {:ok, _} =
                 S3.put(Keys.ctl_conversation_pin(group_id, conversation_id), Jason.encode!(pin))

        pin
      end

    assert {:ok, %{"data" => []}} =
             Conversations.list_conversation_pins(group_id, tenant_id)

    assert {:ok, stats} = ConversationPinsAggregate.run(limit: 1)
    assert stats.migrated == 2
    assert stats.pages > 1
    assert stats.complete

    assert {:ok, %{body: body}} = S3.get(Keys.ctl_conversation_pins_aggregate(group_id))
    aggregate = Jason.decode!(body)
    assert aggregate["agent_group_id"] == group_id
    assert Enum.sort(aggregate["pins"]) == Enum.sort(pins)

    Enum.each(pins, fn pin ->
      assert {:error, :not_found} =
               S3.get(Keys.ctl_conversation_pin(group_id, pin["conversation_id"]))
    end)

    assert {:ok, %{"data" => listed}} =
             Conversations.list_conversation_pins(group_id, tenant_id)

    assert Enum.sort(Enum.map(listed, & &1["conversation_id"])) ==
             Enum.sort(Enum.map(pins, & &1["conversation_id"]))

    assert {:ok, rerun} = ConversationPinsAggregate.run(limit: 1)
    assert rerun.migrated == 0
    assert rerun.failed == []
  end

  test "release cutover requires the no-writer gate", %{group_id: group_id} do
    conversation_id = Ids.new_conversation_id()
    now = System.system_time(:millisecond)

    pin = %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "pinned_at" => now,
      "created_at" => now,
      "updated_at" => now
    }

    assert {:ok, _} =
             S3.put(Keys.ctl_conversation_pin(group_id, conversation_id), Jason.encode!(pin))

    assert_raise RuntimeError, ~r/confirm_no_writers/, fn ->
      Release.migrate_conversation_pins()
    end

    assert %{migrated: 1, complete: true} =
             Release.migrate_conversation_pins(confirm_no_writers: true)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
