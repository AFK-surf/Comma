defmodule SalixIM.IFCTest do
  @moduledoc """
  Ingress labelling and the facts resolver
  (`docs/verification.md` §3.2, §3.6, §5.5).

  These are the two impure halves the pure kernel depends on: what audience a
  message entered with, and what is known about the atoms a decision touches.
  Both are exercised against the real Postgres projection with no provider
  reachable, which is also the shape a fresh workspace has before anything has
  been observed.
  """

  use ExUnit.Case, async: false

  alias SalixIM.IFC.{Ingress, Projection}
  alias SalixStore.{Ids, Keys, S3}
  alias SalixStore.IFC, as: Store

  @tenant "tnt_im_ifc"
  @group "grp_im_ifc"
  @connect "cnx_im_ifc"
  @scope %{tenant_id: @tenant, group_id: @group, connect_id: @connect}

  setup do
    for table <-
          ~w(ifc_scope_labels ifc_tag_clearances ifc_principal_facts ifc_scope_facts ifc_scope_members ifc_receipts) do
      SalixStore.Repo.query!("DELETE FROM #{table}")
    end

    :ok
  end

  # A Group that has opted in. One that has not is covered on its own below:
  # ingress labels nothing for it, which is what keeps this off the hot path
  # of every workspace that is not using it.
  defp group, do: %{"group_id" => @group, "tenant_id" => @tenant, "ifc" => %{"mode" => "audit"}}

  defp slack_metadata(overrides) do
    Map.merge(
      %{
        "provider" => "slack",
        "connect_id" => @connect,
        "channel_id" => "C1",
        "user_id" => "U_A",
        "source_actor_type" => "provider_user"
      },
      overrides
    )
  end

  defp principal_ref, do: %{"connect_id" => @connect, "subject_id" => "U_A"}

  describe "ingress labelling" do
    test "a DM is named by its counterpart, in both directions" do
      block =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "im", "channel_id" => "D1"}),
          principal_ref()
        )

      assert block["label"] == ["scope|#{@connect}|@U_A"]
      assert block["integrity"] == "command"
      assert block["principal"] == "provider_user|#{@connect}|U_A"
    end

    test "a private channel is its own audience" do
      Store.observe_scope(@tenant, @group, @connect, "C1", %{
        kind: "room",
        within: "space|#{@connect}"
      })

      block =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "group"}),
          principal_ref()
        )

      assert block["label"] == ["scope|#{@connect}|C1"]
    end

    test "a public channel is the whole workspace" do
      Store.observe_scope(@tenant, @group, @connect, "C1", %{kind: "public"})

      block =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "channel"}),
          principal_ref()
        )

      assert block["label"] == ["space|#{@connect}"]
    end

    test "unless an operator asked for its exact members" do
      Store.observe_scope(@tenant, @group, @connect, "C1", %{kind: "public"})
      Store.put_scope_label(@tenant, @group, @connect, "C1", %{audience_mode: "members"})

      block =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "channel"}),
          principal_ref()
        )

      assert block["label"] == ["scope|#{@connect}|C1"]
    end

    test "an operator's classification tags travel with the content" do
      Store.observe_scope(@tenant, @group, @connect, "C1", %{kind: "room"})
      Store.put_scope_label(@tenant, @group, @connect, "C1", %{tags: ["finance"]})

      block =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "group"}),
          principal_ref()
        )

      assert block["label"] == ["scope|#{@connect}|C1", "tag|finance"]
    end

    test "IFC treats sealed member identities equally regardless of transport actor or bot flags" do
      for metadata <- [
            %{},
            %{"app_authored" => true},
            %{"from_is_bot" => true},
            %{"sender_type" => "bot"},
            %{"source_actor_type" => "provider_system"}
          ] do
        metadata = slack_metadata(Map.merge(%{"channel_type" => "channel"}, metadata))
        identified = Ingress.provider_block(group(), metadata, principal_ref())
        assert identified["integrity"] == "command"
        assert identified["principal"] == "provider_user|#{@connect}|U_A"
        anonymous = Ingress.provider_block(group(), metadata, nil)
        assert anonymous["integrity"] == "data"
        refute anonymous["principal"]
      end
    end

    test "the sender's placement rides along, when the provider said" do
      block =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "im", "user_placement" => "external"}),
          principal_ref()
        )

      assert block["placement"] == "external"

      block =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "im"}),
          principal_ref()
        )

      refute Map.has_key?(block, "placement")
    end

    test "a Group that has not opted in is not labelled at all" do
      for ifc <- [nil, %{}, %{"mode" => "off"}, %{"mode" => ""}] do
        record = %{"group_id" => @group, "tenant_id" => @tenant}
        record = if ifc, do: Map.put(record, "ifc", ifc), else: record

        assert Ingress.provider_block(
                 record,
                 slack_metadata(%{"channel_type" => "im"}),
                 principal_ref()
               ) == nil
      end

      assert Ingress.enabled?(%{"ifc" => %{"mode" => "enforce"}})
      assert Ingress.enabled?(%{"ifc" => %{"mode" => "audit"}})
      refute Ingress.enabled?(%{"ifc" => %{"mode" => "off"}})
      refute Ingress.enabled?(%{})
    end

    test "an inbound API message belongs to the whole group and acts as the key's creator" do
      metadata = %{
        "provider" => "api",
        "connect_id" => "gak_1",
        "api_key_id" => "gak_1",
        "api_key_principal" => "api_key|gak_1|comma_user|u1",
        "source_actor_type" => "provider_system"
      }

      block = Ingress.provider_block(group(), metadata, %{"connect_id" => "gak_1"})

      assert block["label"] == ["group|" <> @group]
      assert block["integrity"] == "command"
      assert block["principal"] == "api_key|gak_1|comma_user|u1"
      refute Map.has_key?(block, "placement")
    end

    test "an inbound API message from a key with no principal is data" do
      metadata = %{
        "provider" => "api",
        "connect_id" => "gak_2",
        "source_actor_type" => "provider_system"
      }

      block = Ingress.provider_block(group(), metadata, %{"connect_id" => "gak_2"})

      assert block["label"] == ["group|" <> @group]
      assert block["integrity"] == "data"
      refute Map.has_key?(block, "principal")

      # A principal that is not an api_key wrapper cannot smuggle authority in.
      forged = Map.put(metadata, "api_key_principal", "comma_user|u1")
      assert Ingress.provider_block(group(), forged, nil)["integrity"] == "data"
    end

    test "a message with too little to label carries no label at all" do
      assert Ingress.provider_block(group(), slack_metadata(%{"channel_id" => ""}), nil) == nil
      assert Ingress.provider_block(group(), %{"provider" => "slack"}, nil) == nil
      assert Ingress.provider_block(%{}, slack_metadata(%{}), nil) == nil
    end

    test "a Feishu one-to-one chat and group chat use the same vocabulary" do
      direct =
        Ingress.provider_block(
          group(),
          %{
            "provider" => "feishu",
            "connect_id" => @connect,
            "chat_id" => "oc_1",
            "chat_type" => "p2p",
            "sender_open_id" => "ou_a",
            "source_actor_type" => "provider_user"
          },
          nil
        )

      assert direct["label"] == ["scope|#{@connect}|@ou_a"]

      room =
        Ingress.provider_block(
          group(),
          %{
            "provider" => "feishu",
            "connect_id" => @connect,
            "chat_id" => "oc_2",
            "chat_type" => "group",
            "sender_open_id" => "ou_a",
            "source_actor_type" => "provider_user"
          },
          nil
        )

      assert room["label"] == ["scope|#{@connect}|oc_2"]
    end

    test "a Feishu one-to-one chat keeps its audience when named only by its chat id" do
      # A `p2p` chat payload names neither participant, so the pairing is
      # learned from the inbound that carries both. Everything that later names
      # only the chat id — a read of its history, a reply into it — must resolve
      # to the same one person.
      Ingress.provider_block(
        group(),
        %{
          "provider" => "feishu",
          "connect_id" => @connect,
          "chat_id" => "oc_direct",
          "chat_type" => "p2p",
          "sender_open_id" => "ou_b",
          "source_actor_type" => "provider_user"
        },
        nil
      )

      assert Ingress.scope_atoms(@scope, "oc_direct") == ["scope|#{@connect}|@ou_b"]

      # And a later event that mislabels it as a group does not widen it.
      widened =
        Ingress.provider_block(
          group(),
          %{
            "provider" => "feishu",
            "connect_id" => @connect,
            "chat_id" => "oc_direct",
            "chat_type" => "group",
            "sender_open_id" => "ou_c",
            "source_actor_type" => "provider_user"
          },
          nil
        )

      assert widened["label"] == ["scope|#{@connect}|@ou_b"]
    end

    test "a voice call is a one-to-one with its caller, also when named by its call id" do
      block =
        Ingress.provider_block(
          group(),
          %{
            "provider" => "voice",
            "connect_id" => @connect,
            "chat_id" => "vc_call_1",
            "chat_type" => "private",
            "from_user_id" => "+15551234567",
            "source_actor_type" => "provider_user"
          },
          %{"connect_id" => @connect, "subject_id" => "+15551234567"}
        )

      assert block["label"] == ["scope|#{@connect}|@+15551234567"]
      assert block["integrity"] == "command"
      # voice.say addresses the call id; it resolves to the same person.
      assert Ingress.scope_atoms(@scope, "vc_call_1") == block["label"]
    end

    test "a WebSocket voice call acts with its voice key; a forged key is data" do
      metadata = %{
        "provider" => "voice",
        "connect_id" => @connect,
        "chat_id" => "vc_ws_1",
        "chat_type" => "private",
        "from_user_id" => "api_key:gak_v1",
        "api_key_id" => "gak_v1",
        "api_key_principal" => "api_key|gak_v1|comma_user|u1",
        "source_actor_type" => "provider_system"
      }

      block = Ingress.provider_block(group(), metadata, nil)
      assert block["principal"] == "api_key|gak_v1|comma_user|u1"
      assert block["integrity"] == "command"
      assert Ingress.scope_atoms(@scope, "vc_ws_1") == block["label"]

      forged =
        Ingress.provider_block(
          group(),
          Map.put(metadata, "api_key_principal", "comma_user|u1"),
          nil
        )

      assert forged["integrity"] == "data"
      refute Map.has_key?(forged, "principal")
    end

    test "an internal Conversation and a Task get distinct audiences" do
      assert Ingress.conversation_block(%{
               "conversation_id" => "conv_1",
               "conversation_kind" => "user_chat",
               "source_actor_type" => "user"
             })["label"] == ["conversation|conv_1"]

      assert Ingress.conversation_block(%{
               "conversation_id" => "conv_2",
               "conversation_kind" => "agent_task",
               "source_actor_type" => "agent"
             }) == %{"label" => ["task|conv_2"], "integrity" => "data"}
    end
  end

  describe "the projection" do
    test "a one-to-one scope answers without any provider round trip" do
      assert {"@U_A", row} = Projection.facts(@scope, "@U_A")
      assert row.kind == "direct"
      assert row.members == ["U_A"]
      assert row.display_name == "私聊"
    end

    test "an unobserved channel stays unknown when the provider is unreachable" do
      assert {"C_UNKNOWN", row} = Projection.facts(@scope, "C_UNKNOWN")
      assert row.kind == nil
      assert row.members == :unknown
    end

    test "a stale observation reads as unknown rather than as an answer" do
      Store.observe_scope(@tenant, @group, @connect, "C1", %{kind: "room"})
      Store.replace_scope_members(@tenant, @group, @connect, "C1", ["U_A"])

      assert {"C1", fresh} = Projection.facts(@scope, "C1")
      assert fresh.members == ["U_A"]

      SalixStore.Repo.query!(
        "UPDATE ifc_scope_facts SET observed_at = now() - interval '1 day' WHERE scope_id = 'C1'"
      )

      assert {"C1", stale} = Projection.facts(@scope, "C1")
      assert stale.members == :unknown
      assert stale.kind == nil
    end

    test "a join for a conversation the projection never saw writes nothing" do
      Projection.observe_join(@scope, "C_UNSEEN", "U_B")
      assert {"C_UNSEEN", %{members: :unknown, kind: nil}} = Projection.facts(@scope, "C_UNSEEN")
    end

    test "join and leave events move the member set" do
      Store.observe_scope(@tenant, @group, @connect, "C1", %{kind: "room"})
      Store.replace_scope_members(@tenant, @group, @connect, "C1", ["U_A"])

      Projection.observe_join(@scope, "C1", "U_B")
      assert {"C1", %{members: ["U_A", "U_B"]}} = Projection.facts(@scope, "C1")

      Projection.observe_leave(@scope, "C1", "U_A")
      assert {"C1", %{members: ["U_B"]}} = Projection.facts(@scope, "C1")
    end

    test "guest flags decide placement, and nothing else guesses it" do
      assert Projection.provider_placement(%{"id" => "U1"}) == :internal
      assert Projection.provider_placement(%{"id" => "U1", "is_restricted" => true}) == :external

      assert Projection.provider_placement(%{"id" => "U1", "is_ultra_restricted" => true}) ==
               :external

      assert Projection.provider_placement(%{"id" => "U1", "is_stranger" => true}) == :external
      assert Projection.provider_placement(%{"id" => "U1", "is_bot" => true}) == :internal

      assert Projection.provider_placement(%{
               "id" => "U1",
               "is_bot" => true,
               "is_stranger" => true
             }) == :external

      assert Projection.provider_placement(%{}) == :unknown
    end

    test "a Slack channel's own flags decide what it is" do
      assert Projection.slack_kind(%{"is_ext_shared" => true, "is_private" => true}) == "shared"
      assert Projection.slack_kind(%{"is_im" => true}) == "direct"
      assert Projection.slack_kind(%{"is_mpim" => true}) == "room"
      assert Projection.slack_kind(%{"is_private" => true}) == "room"
      assert Projection.slack_kind(%{"is_channel" => true}) == "public"
    end

    test "a Feishu chat's own fields decide what it is" do
      # A chat that admits another tenant is shared whatever else it is, and
      # Feishu's own word for a room anyone in the tenant may join is `public`.
      assert Projection.feishu_kind(%{"external" => true, "chat_mode" => "group"}) == "shared"
      assert Projection.feishu_kind(%{"chat_mode" => "p2p"}) == "direct"

      assert Projection.feishu_kind(%{"chat_mode" => "group", "chat_type" => "public"}) ==
               "public"

      assert Projection.feishu_kind(%{"chat_mode" => "group", "chat_type" => "private"}) == "room"
      assert Projection.feishu_kind(%{"chat_mode" => "topic"}) == "room"
      assert Projection.feishu_kind(%{}) == "room"
    end

    test "a Telegram chat is a room unless it is one person or publicly joinable" do
      assert Projection.telegram_kind(%{"chat_type" => "private", "username" => "someone"}) ==
               "direct"

      assert Projection.telegram_kind(%{"chat_type" => "supergroup", "username" => "openroom"}) ==
               "public"

      assert Projection.telegram_kind(%{"chat_type" => "supergroup"}) == "room"
      assert Projection.telegram_kind(%{"chat_type" => "group", "username" => ""}) == "room"
      assert Projection.telegram_kind(%{}) == "room"
    end
  end

  describe "the facts resolver" do
    test "a product-authored pending Task has no human members; a human Task retains its requester" do
      previous = Application.get_env(:salix_store, :s3_backend)
      Application.put_env(:salix_store, :s3_backend, S3.Fake)
      if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
      on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)
      tenant = Ids.new_tenant_id()
      group_id = Ids.new_group_id(tenant)

      {:ok, _} =
        S3.put(
          Keys.ctl_group(group_id),
          Jason.encode!(%{
            "group_id" => group_id,
            "tenant_id" => tenant,
            "router_conversation_id" => Ids.new_conversation_id(),
            "ifc" => %{"mode" => "enforce"}
          })
        )

      for {requester, members} <- [
            {"system", []},
            {"provider_user|cnx1|U_A", ["provider_user|cnx1|U_A"]}
          ] do
        assert {:ok, reply} =
                 SalixIM.IFC.Facts.resolve(%{
                   "tenant_id" => tenant,
                   "group_id" => group_id,
                   "requester" => requester,
                   "atoms" => [],
                   "destination" => %{"kind" => "pending_task", "tool_call_id" => "create-1"}
                 })

        assert reply["membership"]["task|pending:create-1"]["members"] == members
      end
    end

    test "Worker configuration resolves to the authenticated Group, not a descriptor override" do
      previous = Application.get_env(:salix_store, :s3_backend)
      Application.put_env(:salix_store, :s3_backend, S3.Fake)
      if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
      on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)
      tenant = Ids.new_tenant_id()
      group_id = Ids.new_group_id(tenant)

      {:ok, _} =
        S3.put(
          Keys.ctl_group(group_id),
          Jason.encode!(%{
            "group_id" => group_id,
            "tenant_id" => tenant,
            "router_conversation_id" => Ids.new_conversation_id(),
            "ifc" => %{"mode" => "enforce"}
          })
        )

      assert {:ok, reply} =
               SalixIM.IFC.Facts.resolve(%{
                 "tenant_id" => tenant,
                 "group_id" => group_id,
                 "atoms" => [],
                 "destination" => %{"kind" => "agent_configuration", "group_id" => "other"}
               })

      assert reply["destination"] == %{"label" => ["group|" <> group_id], "writers" => "any"}
    end

    test "a Group that has not opted in is off, and answers nothing else" do
      assert SalixIM.IFC.Facts.mode(@tenant, "grp_missing") == "off"

      assert {:ok, %{"mode" => "off"} = reply} =
               SalixIM.IFC.Facts.resolve(%{
                 "tenant_id" => @tenant,
                 "group_id" => "grp_missing",
                 "destination" => %{"kind" => "public"}
               })

      refute Map.has_key?(reply, "scopes")
    end

    test "an unreadable request is refused rather than answered emptily" do
      assert {:error, :invalid_request} = SalixIM.IFC.Facts.resolve(nil)
    end
  end

  test "a delivered Slack bot request reaches IFC as itself and cannot borrow a human's access" do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)

    tenant = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant)
    router_id = Ids.new_agent_id(group_id)

    group = %{
      "tenant_id" => tenant,
      "group_id" => group_id,
      "router_agent_id" => router_id,
      "ifc" => %{"mode" => "enforce"}
    }

    router = %{
      "agent_id" => router_id,
      "role" => "router",
      "router_session_id" => Ids.new_session_id()
    }

    source_id = "im_provider:slack:#{@connect}:C1:123.456"

    metadata =
      slack_metadata(%{
        "app_authored" => true,
        "event_type" => "message",
        "user_id" => "U_BOT",
        "user_placement" => "internal",
        "thread_ts" => "123.000"
      })
      |> Map.delete("source_actor_type")

    assert {:ok, delivery} =
             SalixIM.AgentDeliveryPayload.provider_router_delivery(
               group,
               router,
               "Random number: 687728",
               metadata,
               source_message_id: source_id
             )

    origin = delivery["trusted_origin"]
    assert origin["source_actor_type"] == "provider_system"
    assert origin["principal_ref"]["subject_id"] == "U_BOT"
    bot = {:provider_user, @connect, "U_BOT"}
    assert SalixAgent.IFC.principal(origin) == bot
    assert origin["ifc"]["integrity"] == "command"

    wire =
      SalixAgent.IFC.Context.build(
        %{
          messages: [
            %{id: 370, role: "user", source_message_id: source_id, trusted_origin: origin}
          ]
        },
        source_message_id: source_id,
        source_message_ids: [source_id],
        trusted_origin: origin
      )

    assert wire["request"] == "src:q-370"
    assert wire["consumed_refs"] == ["src:q-370"]
    assert {:ok, activation} = SalixAgent.IFC.Context.activation(wire)
    assert activation.requester == bot

    alias SalixIFC.{Effect, Facts, Item, Label}
    source = Label.new([{:scope, @connect, "C1"}])

    effect = %Effect{
      destination: source,
      writers: MapSet.new([bot]),
      request: "src:q-370",
      sources: ["src:q-370"]
    }

    items = SalixAgent.IFC.Context.items(wire)
    facts = Facts.new(placements: %{bot => %{@connect => :internal}})
    assert {:allow, _} = SalixIFC.decide(effect, activation, items, facts)

    # Being a bot is not an external-guest flag, nor permission to write everywhere.
    assert {:deny, %{clause: :writer_not_authorized}} =
             SalixIFC.decide(
               %{effect | writers: MapSet.new([{:provider_user, @connect, "U_HUMAN"}])},
               activation,
               items,
               facts
             )

    secret = %Item{
      ref: "src:t-private",
      label: Label.new([{:scope, @connect, "@U_HUMAN"}]),
      integrity: :data
    }

    assert {:deny, _} =
             SalixIFC.decide(
               %{effect | sources: [secret.ref]},
               activation,
               items ++ [secret],
               facts
             )

    # Previously sealed data is not retroactively promoted by a new binary.
    legacy =
      put_in(
        Map.delete(origin, "principal_ref"),
        ["ifc"],
        Map.drop(origin["ifc"], ["principal"]) |> Map.put("integrity", "data")
      )

    assert SalixAgent.IFC.principal(legacy) == nil
  end

  describe "a sealed room" do
    test "keeps its own audience instead of collapsing into its space" do
      # A public room's content is normally its whole space. A sealed one must
      # not be: the space atom resolves to no row, so the seal would be stored
      # and shown to the operator while supplying the kernel nothing, and a
      # receipt would still authorize public egress out of a channel marked
      # never to leave.
      Store.observe_scope(@tenant, @group, @connect, "C_OPEN", %{kind: "public"})
      Store.observe_scope(@tenant, @group, @connect, "C_SEALED", %{kind: "public"})
      Store.put_scope_label(@tenant, @group, @connect, "C_SEALED", %{sealed: true})

      open =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "channel", "channel_id" => "C_OPEN"}),
          principal_ref()
        )

      sealed =
        Ingress.provider_block(
          group(),
          slack_metadata(%{"channel_type" => "channel", "channel_id" => "C_SEALED"}),
          principal_ref()
        )

      assert open["label"] == ["space|#{@connect}"]
      assert sealed["label"] == ["scope|#{@connect}|C_SEALED"]

      # And a read of the same room agrees, so citing a message and citing a
      # search hit from it are the same audience.
      assert Ingress.scope_atoms(@scope, "C_SEALED") == ["scope|#{@connect}|C_SEALED"]

      # The point of all of it: the atom the seal is attached to now reaches
      # the kernel as a sealed restriction.
      assert Projection.space_audience?(%{kind: "public", audience_mode: "space", sealed: false})

      refute Projection.space_audience?(%{kind: "public", audience_mode: "space", sealed: true})

      refute Projection.space_audience?(%{
               kind: "public",
               audience_mode: "members",
               sealed: false
             })

      refute Projection.space_audience?(%{kind: "room", audience_mode: "space", sealed: false})
    end

    test "hands the kernel a sealed restriction, so a receipt cannot release it" do
      # The operator's checkbox has to reach `SalixIFC.Policy.sealed_atoms`, or
      # it is a setting that stores and displays and does nothing.
      previous = Application.get_env(:salix_store, :s3_backend)
      Application.put_env(:salix_store, :s3_backend, S3.Fake)
      if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)
      on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)

      tenant = Ids.new_tenant_id()
      group_id = Ids.new_group_id(tenant)

      {:ok, _} =
        S3.put(
          Keys.ctl_group(group_id),
          Jason.encode!(%{
            "group_id" => group_id,
            "tenant_id" => tenant,
            "router_conversation_id" => Ids.new_conversation_id(),
            "ifc" => %{"mode" => "enforce"}
          })
        )

      Store.observe_scope(tenant, group_id, @connect, "C_SEALED", %{kind: "public"})
      Store.put_scope_label(tenant, group_id, @connect, "C_SEALED", %{sealed: true})

      sealed_atom = "scope|#{@connect}|C_SEALED"

      assert {:ok, reply} =
               SalixIM.IFC.Facts.resolve(%{
                 "tenant_id" => tenant,
                 "group_id" => group_id,
                 "atoms" => [sealed_atom],
                 "destination" => %{"kind" => "public"},
                 "now" => System.system_time(:millisecond)
               })

      assert sealed_atom in reply["policy"]["sealed_atoms"]
    end
  end
end
