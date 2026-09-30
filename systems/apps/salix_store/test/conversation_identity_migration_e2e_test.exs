defmodule SalixStore.ConversationIdentityMigrationE2ETest do
  use ExUnit.Case, async: false

  defmodule RuntimeState do
    defstruct input_dedupe: MapSet.new(), messages: []
  end

  alias SalixStore.{
    Codec,
    ConversationIdMigration,
    Crypto,
    HierarchyIdMigration,
    Ids,
    Keys,
    S3
  }

  alias SalixStore.Migrations.ConversationIdentity

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case Process.whereis(SalixStore.S3.Fake) do
      nil -> start_supervised!(SalixStore.S3.Fake)
      _pid -> SalixStore.S3.Fake.reset()
    end

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous_backend) end)
    :ok
  end

  test "migrates conversation-scoped duplicate identities and converges on rerun" do
    group_id = group_id()
    shared_participant_id = "worker"
    shared_message_id = "legacy-message"
    canonical_agent_id = Ids.new_agent_id(group_id)
    hierarchy_agent_alias = "agent-before-hierarchy-migration"

    assert {:ok, _identity} =
             HierarchyIdMigration.reserve(%{
               tenants: %{},
               groups: %{},
               agents: %{hierarchy_agent_alias => canonical_agent_id}
             })

    put_legacy_conversation(
      group_id,
      "legacy-a",
      shared_participant_id,
      shared_message_id,
      "legacy-group-before-hierarchy-migration",
      "legacy-delivery-participant-alias",
      canonical_agent_id
    )

    put_legacy_conversation(group_id, "legacy-b", shared_participant_id, shared_message_id)
    put_legacy_user_message_without_participant(group_id, "legacy-a")
    put_completed_segmented_source(group_id, "legacy-a")
    put_completed_segmented_source(group_id, "deleted-conversation")

    pin_aggregate_key = Keys.ctl_conversation_pins_aggregate(group_id)

    put_json(pin_aggregate_key, %{
      "agent_group_id" => group_id,
      "pins" => [
        legacy_pin(group_id, "legacy-a", 100),
        legacy_pin(group_id, "legacy-b", 101)
      ],
      "updated_at" => 101
    })

    put_json(Keys.ctl_group(group_id), %{
      "group_id" => group_id,
      "router_conversation_id" => "unmaterialized-router"
    })

    create_request_key =
      Keys.ctl_group_conversation_create_request(
        group_id,
        Crypto.hex("client-create-request")
      )

    put_json(create_request_key, %{
      "version" => 1,
      "group_id" => group_id,
      "request_identity" => "client-create-request",
      "request_fingerprint" => "stable-create-fingerprint",
      "conversation_id" => "legacy-a",
      "created_at" => 100
    })

    {internal_session_key, external_session_key, external_segment_key, inbox_key} =
      put_runtime_session_refs(
        group_id,
        "legacy-a",
        hierarchy_agent_alias,
        shared_message_id
      )

    {archived_internal_key, archived_external_key, archived_external_segment_key,
     archived_inbox_key} =
      put_runtime_session_refs(
        group_id,
        "deleted-conversation",
        "deleted-participant",
        "deleted-message"
      )

    runtime_only_key =
      put_runtime_only_struct_ref(
        group_id,
        "runtime-only-conversation",
        hierarchy_agent_alias,
        "im_provider:slack:runtime-only-message"
      )

    put_terminal_legacy_dispatch(
      group_id,
      "runtime-only-conversation",
      "im_provider:slack:runtime-only-message",
      "runtime-only-participant",
      canonical_agent_id
    )

    assert {:ok, _stats} = ConversationIdentity.run()
    assert {:ok, maps} = ConversationIdMigration.read_all()

    map_a = maps[{group_id, "legacy-a"}]
    map_b = maps[{group_id, "legacy-b"}]
    archived_map = maps[{group_id, "deleted-conversation"}]
    runtime_only_map = maps[{group_id, "runtime-only-conversation"}]
    router_map = maps[{group_id, "unmaterialized-router"}]

    conversation_a = get_in(map_a, ["conversation_id", "target"])
    conversation_b = get_in(map_b, ["conversation_id", "target"])
    participant_a = map_a["participant_ids"][shared_participant_id]
    participant_b = map_b["participant_ids"][shared_participant_id]
    message_a = map_a["message_ids"][shared_message_id]
    message_b = map_b["message_ids"][shared_message_id]
    user_participant_a = map_a["participant_ids"]["legacy-user"]

    assert Ids.valid_conversation_id?(conversation_a)
    assert Ids.valid_conversation_id?(conversation_b)
    assert Ids.valid_participant_id?(participant_a)
    assert Ids.valid_participant_id?(participant_b)
    assert Ids.valid_message_id?(message_a)
    assert Ids.valid_message_id?(message_b)
    assert Ids.valid_participant_id?(user_participant_a)
    refute conversation_a == conversation_b
    refute participant_a == participant_b
    refute message_a == message_b

    assert %{"agent_group_id" => ^group_id, "pins" => migrated_pins} =
             migrated_pin_aggregate = read_json(pin_aggregate_key)

    assert Enum.sort(Enum.map(migrated_pins, & &1["conversation_id"])) ==
             Enum.sort([conversation_a, conversation_b])

    refute Enum.any?(migrated_pins, &(&1["conversation_id"] in ["legacy-a", "legacy-b"]))

    assert {:ok, pin_objects} = S3.list_all(Keys.ctl_conversation_pins_prefix(group_id))
    assert Enum.any?(pin_objects, &(&1.key == pin_aggregate_key))

    assert map_a["participant_ids"]["legacy-delivery-participant-alias"] == participant_a
    assert map_a["participant_ids"][hierarchy_agent_alias] == participant_a

    assert %{
             "actor_type" => "user",
             "participant_id" => ^user_participant_a,
             "user_id" => "legacy-user-id"
           } =
             read_json(
               Keys.ctl_group_conversation_participant_state(
                 group_id,
                 conversation_a,
                 user_participant_a
               )
             )

    assert_migrated_aggregate(group_id, conversation_a, participant_a, message_a, 2, 2)
    assert_migrated_aggregate(group_id, conversation_b, participant_b, message_b)

    assert %{
             "request_identity" => "client-create-request",
             "request_fingerprint" => "stable-create-fingerprint",
             "conversation_id" => ^conversation_a
           } = read_json(create_request_key)

    assert_migrated_runtime_session_refs(
      internal_session_key,
      external_session_key,
      external_segment_key,
      inbox_key,
      conversation_a,
      participant_a,
      message_a
    )

    refute archived_map["materialized"]
    refute runtime_only_map["materialized"]
    refute router_map["materialized"]

    assert {:ok, %{body: runtime_only_body}} = S3.get(runtime_only_key)

    assert %RuntimeState{input_dedupe: runtime_only_dedupe} =
             Codec.decode_snapshot(runtime_only_body)

    assert runtime_only_dedupe ==
             MapSet.new([
               runtime_source_id(
                 get_in(runtime_only_map, ["conversation_id", "target"]),
                 runtime_only_map["message_ids"]["im_provider:slack:runtime-only-message"],
                 runtime_only_map["participant_ids"][hierarchy_agent_alias]
               )
             ])

    assert runtime_only_map["participant_ids"][hierarchy_agent_alias] ==
             runtime_only_map["participant_ids"]["runtime-only-participant"]

    router_conversation_id = get_in(router_map, ["conversation_id", "target"])

    assert %{"router_conversation_id" => ^router_conversation_id} =
             read_json(Keys.ctl_group(group_id))

    assert {:error, :not_found} =
             S3.get(Keys.ctl_group_conversation(group_id, router_conversation_id))

    assert_migrated_runtime_session_refs(
      archived_internal_key,
      archived_external_key,
      archived_external_segment_key,
      archived_inbox_key,
      get_in(archived_map, ["conversation_id", "target"]),
      archived_map["participant_ids"]["deleted-participant"],
      archived_map["message_ids"]["deleted-message"]
    )

    assert {:error, :not_found} =
             S3.get(
               Keys.ctl_group_conversation(
                 group_id,
                 get_in(archived_map, ["conversation_id", "target"])
               )
             )

    assert {:error, :not_found} = S3.get(Keys.ctl_group_conversation(group_id, "legacy-a"))
    assert {:error, :not_found} = S3.get(Keys.ctl_group_conversation(group_id, "legacy-b"))
    assert {:error, :not_found} = S3.get(legacy_conversation_key(group_id, "legacy-a"))

    assert {:error, :not_found} =
             S3.get(legacy_conversation_key(group_id, "deleted-conversation"))

    assert {:ok, []} = S3.list_all("ctl/group_conversation_dispatch/")
    assert {:ok, []} = S3.list_all("ctl/migrations/conversation_storage_segmented/")

    assert {:ok, _stats} = ConversationIdentity.run()
    assert {:ok, ^maps} = ConversationIdMigration.read_all()
    assert ^migrated_pin_aggregate = read_json(pin_aggregate_key)
  end

  test "reuses the reserved map after destination write succeeds and source delete fails" do
    group_id = group_id()
    source_conversation_id = "legacy-interrupted"
    source_participant_id = "worker"
    source_message_id = "legacy-message"

    source_meta_key =
      put_legacy_conversation(
        group_id,
        source_conversation_id,
        source_participant_id,
        source_message_id
      )

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :delete, source_meta_key})

    assert {:error, _reason} = ConversationIdentity.run()
    assert {:ok, first_maps} = ConversationIdMigration.read_all()

    map = first_maps[{group_id, source_conversation_id}]
    target_conversation_id = get_in(map, ["conversation_id", "target"])
    target_meta_key = Keys.ctl_group_conversation(group_id, target_conversation_id)

    assert {:ok, _source} = S3.get(source_meta_key)
    assert {:ok, _target} = S3.get(target_meta_key)

    assert {:ok, _stats} = ConversationIdentity.run()
    assert {:ok, ^first_maps} = ConversationIdMigration.read_all()
    assert {:error, :not_found} = S3.get(source_meta_key)

    assert_migrated_aggregate(
      group_id,
      target_conversation_id,
      map["participant_ids"][source_participant_id],
      map["message_ids"][source_message_id]
    )
  end

  test "allows product references that are not materialized in the Salix aggregate" do
    group_id = group_id()
    conversation_id = "legacy-with-product-only-refs"

    put_legacy_conversation(group_id, conversation_id, "worker", "stored-message")

    additional_ref = %{
      "group_id" => group_id,
      "conversation_id" => conversation_id,
      "message_ids" => ["product-only-message"]
    }

    assert {:ok, _stats} = ConversationIdentity.run(additional_refs: [additional_ref])
    assert {:ok, maps} = ConversationIdMigration.read_all()
    map = maps[{group_id, conversation_id}]

    assert Ids.valid_message_id?(map["message_ids"]["product-only-message"])
    assert {:ok, _stats} = ConversationIdentity.run()
  end

  test "reuses the reserved map after a destination write fails" do
    group_id = group_id()
    source_conversation_id = "legacy-destination-failure"
    source_participant_id = "worker"
    source_message_id = "legacy-message"

    source_meta_key =
      put_legacy_conversation(
        group_id,
        source_conversation_id,
        source_participant_id,
        source_message_id
      )

    assert {:ok, first_maps} = ConversationIdentity.reserve_maps()
    map = first_maps[{group_id, source_conversation_id}]
    target_conversation_id = get_in(map, ["conversation_id", "target"])
    target_meta_key = Keys.ctl_group_conversation(group_id, target_conversation_id)

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, target_meta_key})

    assert {:error, _reason} = ConversationIdentity.run()
    assert {:ok, ^first_maps} = ConversationIdMigration.read_all()
    assert {:ok, _source} = S3.get(source_meta_key)
    assert {:error, :not_found} = S3.get(target_meta_key)

    assert {:ok, _stats} = ConversationIdentity.run()
    assert {:ok, ^first_maps} = ConversationIdMigration.read_all()
    assert {:error, :not_found} = S3.get(source_meta_key)

    assert_migrated_aggregate(
      group_id,
      target_conversation_id,
      map["participant_ids"][source_participant_id],
      map["message_ids"][source_message_id]
    )
  end

  test "materializes the canonical binding for a legacy Slack worker thread" do
    group_id = group_id()
    worker_agent_id = Ids.new_agent_id(group_id)
    connect_id = Ids.new_connect_id()
    channel_id = "C123"
    thread_ts = "1712345678.000100"

    put_legacy_slack_thread(
      group_id,
      worker_agent_id,
      connect_id,
      channel_id,
      thread_ts
    )

    assert {:ok, _stats} = ConversationIdentity.run()
    assert {:ok, maps} = ConversationIdMigration.read_all()

    source_conversation_id = "task-slack-legacy-conversation-long"
    map = maps[{group_id, source_conversation_id}]
    conversation_id = get_in(map, ["conversation_id", "target"])
    participant_id = map["participant_ids"]["slack:#{connect_id}:#{channel_id}:#{thread_ts}"]
    message_id = map["message_ids"]["slack-message"]

    outbound_source_id =
      "conversation-link:#{source_conversation_id}:slack:#{connect_id}:#{channel_id}:#{thread_ts}"

    outbound_message_id = map["message_ids"][outbound_source_id]

    assert %{
             "version" => 1,
             "provider" => "slack",
             "group_id" => ^group_id,
             "connect_id" => ^connect_id,
             "channel_id" => ^channel_id,
             "thread_ts" => ^thread_ts,
             "worker_agent_id" => ^worker_agent_id,
             "conversation_id" => ^conversation_id,
             "participant_id" => ^participant_id
           } =
             read_json(
               Keys.ctl_im_slack_thread_binding(
                 group_id,
                 connect_id,
                 channel_id,
                 thread_ts
               )
             )

    outbound_delivery_id =
      Enum.join(
        [group_id, conversation_id, "idempotency:" <> outbound_source_id, participant_id],
        ":"
      )

    assert %{
             "delivery_id" => ^outbound_delivery_id,
             "message_id" => ^outbound_message_id,
             "request_identity" => "idempotency:" <> ^outbound_source_id,
             "request_fingerprint" => outbound_fingerprint
           } =
             read_json(
               Keys.ctl_group_conversation_participant_delivery_state(
                 group_id,
                 conversation_id,
                 participant_id,
                 outbound_delivery_id
               )
             )

    assert is_binary(outbound_fingerprint) and outbound_fingerprint != ""

    assert [
             %{
               "message_id" => ^message_id,
               "request_identity" => "provider_message:slack-message"
             }
           ] =
             read_jsonl(
               Keys.ctl_group_conversation_message_segment(
                 group_id,
                 conversation_id,
                 "000000000000000001"
               )
             )
  end

  defp group_id do
    tenant_id = Ids.new_tenant_id()
    Ids.new_group_id(tenant_id)
  end

  defp put_legacy_conversation(
         group_id,
         conversation_id,
         participant_id,
         message_id,
         delivery_group_id \\ nil,
         delivery_participant_id \\ nil,
         agent_id \\ nil
       ) do
    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)

    put_json(meta_key, %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "participant_count" => 1,
      "message_count" => 1,
      "created_at" => 100,
      "updated_at" => 100
    })

    put_json(
      Keys.ctl_group_conversation_participant_state(group_id, conversation_id, participant_id),
      %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "participant_id" => participant_id,
        "actor_type" => "agent",
        "agent_id" => agent_id,
        "role_label" => "worker",
        "status" => "active"
      }
    )

    message = %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "message_id" => message_id,
      "participant_id" => participant_id,
      "seq" => 1,
      "kind" => "message",
      "actor_type" => "agent",
      "content" => [%{"type" => "text", "text" => "legacy task"}],
      "metadata" => %{
        "message_id" => message_id,
        "provider" => "opaque-test",
        "reply_to_message_id" => message_id,
        "reply_to_message_ids" => [message_id]
      },
      "created_at" => 100
    }

    put_body(
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      ),
      Jason.encode!(message) <> "\n"
    )

    put_json(Keys.ctl_conversation_pin(group_id, conversation_id), %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "created_at" => 100,
      "updated_at" => 100
    })

    delivery_id =
      Enum.join(
        [
          delivery_group_id || group_id,
          conversation_id,
          message_id,
          delivery_participant_id || participant_id
        ],
        ":"
      )

    delivery_state_key =
      Keys.ctl_group_conversation_participant_delivery_state(
        group_id,
        conversation_id,
        participant_id,
        delivery_id
      )

    put_json(
      delivery_state_key,
      %{
        "delivery_id" => delivery_id,
        "delivery_kind" => "group_conversation",
        "status" => "pending",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "participant_id" => participant_id,
        "participant_actor_type" => "agent",
        "delivery_billing_context" => %{
          "conversation_id" => "comma-product-conversation",
          "surface" => "comma"
        },
        "message_content" => message["content"],
        "message_metadata" => %{
          "provider_message_id" => message_id,
          "reply_to_message_id" => message_id,
          "reply_to_message_ids" => [message_id]
        },
        "created_at" => 100,
        "updated_at" => 100
      }
    )

    put_json(
      Keys.ctl_group_conversation_participant_delivery_status(
        group_id,
        conversation_id,
        participant_id,
        "pending",
        delivery_id
      ),
      %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "participant_id" => participant_id,
        "delivery_id" => delivery_id,
        "status" => "pending",
        "state_key" => delivery_state_key,
        "updated_at" => 100
      }
    )

    put_body(
      Keys.ctl_group_conversation_participant_delivery_attempts_segments_prefix(
        group_id,
        conversation_id,
        participant_id,
        delivery_id
      ) <> "000000000000000001.jsonl",
      Jason.encode!(%{
        "attempt_seq" => 1,
        "delivery_id" => delivery_id,
        "delivery_status" => "created",
        "recorded_at" => 100,
        "status" => "delivered"
      }) <> "\n"
    )

    meta_key
  end

  defp put_completed_segmented_source(group_id, conversation_id) do
    source_key = legacy_conversation_key(group_id, conversation_id)

    put_json(source_key, %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "messages" => []
    })

    put_json(
      "ctl/group_conversation_dispatch/#{group_id}/#{conversation_id}/legacy.json",
      %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "status" => "delivered"
      }
    )

    put_json(
      "ctl/migrations/conversation_storage_segmented/#{Crypto.hex(source_key)}.json",
      %{
        "name" => "conversation_storage_segmented",
        "source_key" => source_key,
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "completed_at" => 100
      }
    )
  end

  defp put_legacy_user_message_without_participant(group_id, conversation_id) do
    segment_key =
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      )

    {:ok, %{body: body}} = S3.get(segment_key)

    user_message = %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "message_id" => "legacy-user-message",
      "participant_id" => "legacy-user",
      "seq" => 2,
      "kind" => "message",
      "actor_type" => "user",
      "user_id" => "legacy-user-id",
      "content" => [%{"type" => "text", "text" => "legacy user message"}],
      "created_at" => 101
    }

    put_body(segment_key, body <> Jason.encode!(user_message) <> "\n")

    meta_key = Keys.ctl_group_conversation(group_id, conversation_id)
    meta = read_json(meta_key)
    put_json(meta_key, Map.put(meta, "message_count", 2))
  end

  defp legacy_conversation_key(group_id, conversation_id),
    do: "ctl/group_conversations/#{group_id}/#{conversation_id}.json"

  defp put_legacy_slack_thread(group_id, worker_agent_id, connect_id, channel_id, thread_ts) do
    conversation_id = "task-slack-legacy-conversation-long"
    provider_participant_id = "slack:#{connect_id}:#{channel_id}:#{thread_ts}"

    outbound_source_id =
      "conversation-link:#{conversation_id}:#{provider_participant_id}"

    put_json(Keys.ctl_group_conversation(group_id, conversation_id), %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "participant_count" => 2,
      "message_count" => 1,
      "created_at" => 100,
      "updated_at" => 100
    })

    put_json(
      Keys.ctl_group_conversation_participant_state(group_id, conversation_id, "worker"),
      %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "participant_id" => "worker",
        "actor_type" => "agent",
        "agent_id" => worker_agent_id,
        "role_label" => "worker",
        "state" => "active",
        "created_at" => 100,
        "updated_at" => 100
      }
    )

    put_json(
      Keys.ctl_group_conversation_participant_state(
        group_id,
        conversation_id,
        provider_participant_id
      ),
      %{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "participant_id" => provider_participant_id,
        "actor_type" => "provider",
        "provider" => "slack",
        "role_label" => "slack_thread",
        "state" => "active",
        "payload" => %{
          "connect_id" => connect_id,
          "channel_id" => channel_id,
          "thread_ts" => thread_ts
        },
        "created_at" => 100,
        "updated_at" => 100
      }
    )

    put_body(
      Keys.ctl_group_conversation_message_segment(
        group_id,
        conversation_id,
        "000000000000000001"
      ),
      Jason.encode!(%{
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => "slack-message",
        "participant_id" => provider_participant_id,
        "seq" => 1,
        "kind" => "message",
        "actor_type" => "provider_user",
        "content" => [%{"type" => "text", "text" => "legacy Slack task"}],
        "created_at" => 100
      }) <> "\n"
    )

    outbound_delivery_id =
      Enum.join([group_id, conversation_id, outbound_source_id, provider_participant_id], ":")

    put_json(
      Keys.ctl_group_conversation_participant_delivery_state(
        group_id,
        conversation_id,
        provider_participant_id,
        outbound_delivery_id
      ),
      %{
        "delivery_id" => outbound_delivery_id,
        "delivery_kind" => "provider_participant_message",
        "status" => "delivered",
        "agent_group_id" => group_id,
        "conversation_id" => conversation_id,
        "message_id" => outbound_source_id,
        "participant_id" => provider_participant_id,
        "source_actor_type" => "product",
        "message_content" => [%{"type" => "text", "text" => "outbound"}],
        "message_metadata" => %{},
        "created_at" => 100,
        "updated_at" => 100
      }
    )
  end

  defp put_runtime_session_refs(group_id, conversation_id, participant_id, message_id) do
    agent_id = Ids.new_agent_id(group_id)
    source_id = runtime_source_id(conversation_id, message_id, participant_id)
    context_source_id = source_id <> ":source-context"

    context = """
    Inbound message source:
    - provider: internal
    - conversation_id: #{conversation_id}
    - message_id: #{message_id}
    - parent_message_id: 1783659887.094329
    - participant_id: #{participant_id}
    """

    internal_key = Keys.agent_internal_runtime_session(agent_id, Ids.new_session_id())

    put_body(
      internal_key,
      Codec.encode_snapshot(%{
        input_dedupe: MapSet.new([source_id, context_source_id]),
        messages: [
          %{
            role: "summary",
            source_message_id: context_source_id,
            runtime_message_id: context_source_id,
            content: context
          },
          %{
            role: "user",
            source_message_id: source_id,
            runtime_message_id: source_id,
            content: "task"
          }
        ]
      })
    )

    external_key = Keys.agent_external_runtime_session(agent_id, Ids.new_session_id())

    put_json(external_key, %{
      "input_dedupe" => [source_id, context_source_id],
      "input_message_queue" => [
        %{
          "role" => "summary",
          "source_message_id" => context_source_id,
          "runtime_message_id" => context_source_id,
          "content" => context
        },
        %{
          "role" => "user",
          "source_message_id" => source_id,
          "runtime_message_id" => source_id,
          "content" => "task"
        }
      ]
    })

    ["agents", _agent_id, "external_runtime", "sessions", session_file] =
      String.split(external_key, "/")

    session_id = String.trim_trailing(session_file, ".json")

    external_segment_key =
      Keys.agent_external_runtime_session_segment(
        agent_id,
        session_id,
        "01CONVERSATIONMIGRATIONTEST"
      )

    put_body(
      external_segment_key,
      Enum.map_join(
        [
          %{
            "role" => "summary",
            "source_message_id" => context_source_id,
            "runtime_message_id" => context_source_id,
            "content" => context
          },
          %{
            "role" => "user",
            "source_message_id" => source_id,
            "runtime_message_id" => source_id,
            "content" => "task"
          }
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    # Historical staged-protocol layout (retired from Keys, A2 §3.4): this
    # fixture fabricates a pre-cutover bucket for the migration to transform,
    # so it keeps the literal, mirroring the migration's own inline.
    inbox_key =
      "agents/#{agent_id}/inbox/#{SalixStore.Crypto.hex(context_source_id)}.json"

    put_json(inbox_key, %{
      "source_message_id" => context_source_id,
      "payload" => %{
        "role" => "summary",
        "source_message_id" => context_source_id,
        "content" => context
      }
    })

    {internal_key, external_key, external_segment_key, inbox_key}
  end

  defp put_runtime_only_struct_ref(group_id, conversation_id, participant_id, message_id) do
    agent_id = Ids.new_agent_id(group_id)
    key = Keys.agent_internal_runtime_session(agent_id, Ids.new_session_id())

    put_body(
      key,
      Codec.encode_snapshot(%RuntimeState{
        input_dedupe: MapSet.new([runtime_source_id(conversation_id, message_id, participant_id)])
      })
    )

    key
  end

  defp put_terminal_legacy_dispatch(
         group_id,
         conversation_id,
         message_id,
         target_participant_id,
         target_agent_id
       ) do
    key =
      Enum.join(
        [
          "ctl/group_conversation_dispatch/legacy-group-before-hierarchy",
          conversation_id,
          message_id,
          "agent-before-hierarchy-migration.json"
        ],
        "/"
      )

    put_json(key, %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "message_id" => message_id,
      "status" => "delivered",
      "target_agent_id" => target_agent_id,
      "target_participant_id" => target_participant_id
    })

    key
  end

  defp assert_migrated_runtime_session_refs(
         internal_key,
         external_key,
         external_segment_key,
         inbox_key,
         conversation_id,
         participant_id,
         message_id
       ) do
    source_id = runtime_source_id(conversation_id, message_id, participant_id)
    context_source_id = source_id <> ":source-context"

    assert {:ok, %{body: internal_body}} = S3.get(internal_key)
    internal = Codec.decode_snapshot(internal_body)
    assert internal.input_dedupe == MapSet.new([source_id, context_source_id])

    assert [
             %{
               source_message_id: ^context_source_id,
               runtime_message_id: ^context_source_id
             } = message,
             %{source_message_id: ^source_id, runtime_message_id: ^source_id}
           ] = internal.messages

    assert message.content =~ "- conversation_id: #{conversation_id}"
    assert message.content =~ "- message_id: #{message_id}"
    assert message.content =~ "- parent_message_id: 1783659887.094329"
    assert message.content =~ "- participant_id: #{participant_id}"

    external = read_json(external_key)
    assert external["input_dedupe"] == [source_id, context_source_id]

    assert [
             %{
               "source_message_id" => ^context_source_id,
               "runtime_message_id" => ^context_source_id
             } = message,
             %{"source_message_id" => ^source_id, "runtime_message_id" => ^source_id}
           ] = external["input_message_queue"]

    assert message["content"] =~ "- conversation_id: #{conversation_id}"
    assert message["content"] =~ "- message_id: #{message_id}"
    assert message["content"] =~ "- parent_message_id: 1783659887.094329"
    assert message["content"] =~ "- participant_id: #{participant_id}"

    assert {:ok, %{body: external_segment_body}} = S3.get(external_segment_key)

    assert [
             %{
               "source_message_id" => ^context_source_id,
               "runtime_message_id" => ^context_source_id
             } = segment_context,
             %{"source_message_id" => ^source_id, "runtime_message_id" => ^source_id}
           ] =
             external_segment_body
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)

    assert segment_context["content"] =~ "- conversation_id: #{conversation_id}"
    assert segment_context["content"] =~ "- message_id: #{message_id}"
    assert segment_context["content"] =~ "- parent_message_id: 1783659887.094329"
    assert segment_context["content"] =~ "- participant_id: #{participant_id}"

    ["agents", agent_id, "inbox", _file] = String.split(inbox_key, "/")

    migrated_inbox_key =
      "agents/#{agent_id}/inbox/#{SalixStore.Crypto.hex(context_source_id)}.json"

    assert {:error, :not_found} = S3.get(inbox_key)
    assert %{"source_message_id" => ^context_source_id} = read_json(migrated_inbox_key)
  end

  defp runtime_source_id(conversation_id, message_id, participant_id),
    do: "groupconv:#{conversation_id}:#{message_id}:#{participant_id}"

  defp assert_migrated_aggregate(
         group_id,
         conversation_id,
         participant_id,
         message_id,
         participant_count \\ 1,
         message_count \\ 1
       ) do
    meta = read_json(Keys.ctl_group_conversation(group_id, conversation_id))
    assert %{"conversation_id" => ^conversation_id, "message_count" => ^message_count} = meta
    refute Map.has_key?(meta, "participant_count")

    participant_prefix =
      Keys.ctl_group_conversation_participant_states_prefix(group_id, conversation_id)

    assert {:ok, participant_objects} = S3.list_all(participant_prefix)

    assert Enum.count(participant_objects, fn object ->
             object.key
             |> String.replace_prefix(participant_prefix, "")
             |> String.ends_with?(".json")
           end) == participant_count

    assert %{
             "conversation_id" => ^conversation_id,
             "participant_id" => ^participant_id
           } =
             read_json(
               Keys.ctl_group_conversation_participant_state(
                 group_id,
                 conversation_id,
                 participant_id
               )
             )

    messages =
      read_jsonl(
        Keys.ctl_group_conversation_message_segment(
          group_id,
          conversation_id,
          "000000000000000001"
        )
      )

    assert length(messages) == message_count
    message = Enum.find(messages, &(&1["message_id"] == message_id))

    assert message["conversation_id"] == conversation_id
    assert message["participant_id"] == participant_id
    assert message["message_id"] == message_id
    assert message["request_identity"] == "client_request:legacy-message"

    assert message["metadata"] == %{
             "message_id" => "legacy-message",
             "provider" => "opaque-test",
             "reply_to_message_id" => message_id,
             "reply_to_message_ids" => [message_id]
           }

    assert %{"message_id" => ^message_id} =
             read_json(
               Keys.ctl_group_conversation_message_identity(
                 group_id,
                 conversation_id,
                 Crypto.hex(message_id)
               )
             )

    delivery_id =
      Enum.join(
        [group_id, conversation_id, message_id, participant_id],
        ":"
      )

    assert %{
             "delivery_id" => ^delivery_id,
             "conversation_id" => ^conversation_id,
             "message_id" => ^message_id,
             "participant_id" => ^participant_id,
             "delivery_billing_context" => %{
               "conversation_id" => "comma-product-conversation",
               "surface" => "comma"
             },
             "message_metadata" => %{
               "provider_message_id" => "legacy-message",
               "reply_to_message_id" => ^message_id,
               "reply_to_message_ids" => [^message_id]
             },
             "request_identity" => "client_request:legacy-message",
             "request_fingerprint" => request_fingerprint
           } =
             read_json(
               Keys.ctl_group_conversation_participant_delivery_state(
                 group_id,
                 conversation_id,
                 participant_id,
                 delivery_id
               )
             )

    assert is_binary(request_fingerprint) and request_fingerprint != ""

    delivery_state_key =
      Keys.ctl_group_conversation_participant_delivery_state(
        group_id,
        conversation_id,
        participant_id,
        delivery_id
      )

    assert %{
             "delivery_id" => ^delivery_id,
             "conversation_id" => ^conversation_id,
             "participant_id" => ^participant_id,
             "state_key" => ^delivery_state_key,
             "status" => "pending"
           } =
             read_json(
               Keys.ctl_group_conversation_participant_delivery_status(
                 group_id,
                 conversation_id,
                 participant_id,
                 "pending",
                 delivery_id
               )
             )
  end

  defp legacy_pin(group_id, conversation_id, timestamp) do
    %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "pinned_at" => timestamp,
      "created_at" => timestamp,
      "updated_at" => timestamp
    }
  end

  defp put_json(key, value), do: put_body(key, Jason.encode!(value))

  defp put_body(key, body) do
    assert {:ok, _} = S3.put(key, body)
  end

  defp read_json(key) do
    assert {:ok, %{body: body}} = S3.get(key)
    Jason.decode!(body)
  end

  defp read_jsonl(key) do
    assert {:ok, %{body: body}} = S3.get(key)
    body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end
end
