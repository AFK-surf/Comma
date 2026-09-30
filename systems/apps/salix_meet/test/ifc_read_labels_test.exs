defmodule SalixMeet.IFCReadLabelsTest do
  use ExUnit.Case, async: false

  alias SalixMeet.IFC.ReadLabels
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @private %{"label" => ["agent_private"]}

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_store, :s3_backend, previous),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    connect = "meeting-read-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CasRecord.create(Keys.ctl_group(group), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "router_conversation_id" => Ids.new_conversation_id(),
        "ifc" => %{"mode" => "enforce"}
      })

    {:ok, _} =
      CasRecord.create(Keys.ctl_im_connect(group, connect), %{
        "tenant_id" => tenant,
        "group_id" => group,
        "connect_id" => connect,
        "provider" => "slack"
      })

    SalixStore.IFC.observe_scope(tenant, group, connect, "C_PUBLIC", %{kind: "public"})
    SalixStore.IFC.observe_scope(tenant, group, connect, "C_PRIVATE", %{kind: "room"})

    state = %{
      "tenant_id" => tenant,
      "group_id" => group,
      "provider" => "slack",
      "connect_id" => connect,
      "slack_ref" => %{"channel_id" => "C_PUBLIC"}
    }

    {:ok, state: state, meeting: %{"notes_delivery_status" => "visible"}, connect: connect}
  end

  test "published notes use the authoritative source scope, not the result's channel hint", ctx do
    space = "space|#{ctx.connect}"
    assert %{"label" => [^space]} = ReadLabels.for_meeting(ctx.state, ctx.meeting)

    state = put_in(ctx.state, ["slack_ref", "channel_id"], "C_PRIVATE")
    meeting = Map.put(ctx.meeting, "slack_channel_id", "C_PUBLIC")
    room = "scope|#{ctx.connect}|C_PRIVATE"
    assert %{"label" => [^room]} = ReadLabels.for_meeting(state, meeting)
  end

  test "unknown, unpublished and cross-tenant sources stay private", ctx do
    for status <- [nil, "pending", "unavailable"] do
      assert @private ==
               ReadLabels.for_meeting(ctx.state, %{"notes_delivery_status" => status})
    end

    for state <- [
          Map.delete(ctx.state, "connect_id"),
          Map.put(ctx.state, "provider", "unsupported"),
          Map.put(ctx.state, "connect_id", "missing"),
          Map.delete(ctx.state, "slack_ref")
        ] do
      assert @private == ReadLabels.for_meeting(state, ctx.meeting)
    end

    # The connect record must belong to the same tenant, not just occupy the
    # expected object key. No classification can be borrowed from another owner.
    {:ok, _} =
      CasRecord.update(Keys.ctl_im_connect(ctx.state["group_id"], ctx.connect), fn record ->
        Map.put(record, "tenant_id", Ids.new_tenant_id())
      end)

    assert @private == ReadLabels.for_meeting(ctx.state, ctx.meeting)
  end

  test "published Feishu notes retain their chat audience", ctx do
    {:ok, _} =
      CasRecord.update(Keys.ctl_im_connect(ctx.state["group_id"], ctx.connect), fn record ->
        Map.put(record, "provider", "feishu")
      end)

    state =
      ctx.state
      |> Map.put("provider", "feishu")
      |> Map.put("feishu_ref", %{"chat_id" => "C_PRIVATE"})

    room = "scope|#{ctx.connect}|C_PRIVATE"
    assert %{"label" => [^room]} = ReadLabels.for_meeting(state, ctx.meeting)
  end

  test "citing a published public meeting flows, private and unlabelled meetings do not", ctx do
    alias SalixIFC.{Activation, Codec, Effect, Facts, Item, Label, Reason}
    requester = {:provider_user, ctx.connect, "U_PUBLIC"}
    space = Label.new([{:space, ctx.connect}])
    room = {:scope, ctx.connect, "C_PRIVATE"}

    facts =
      Facts.new(
        scopes: %{room => [kind: :room, within: {:space, ctx.connect}]},
        membership: %{room => {:members, [], 1}},
        placements: %{requester => %{ctx.connect => :internal}}
      )

    activation = %Activation{
      requester: requester,
      source_scope: space,
      consumed_refs: MapSet.new(["q"])
    }

    effect = %Effect{destination: space, request: "q", writers: :any, sources: ["meeting"]}
    command = %Item{ref: "q", label: space, integrity: :command, principal: requester}

    decide = fn state, meeting ->
      {:ok, label} = ReadLabels.for_meeting(state, meeting)["label"] |> Codec.decode_label()

      SalixIFC.decide(
        effect,
        activation,
        [command, %Item{ref: "meeting", label: label, integrity: :data}],
        facts
      )
    end

    assert {:allow, _} = decide.(ctx.state, ctx.meeting)

    assert {:deny, %Reason{clause: :flow_denied, detail: [:scope]}} =
             decide.(put_in(ctx.state, ["slack_ref", "channel_id"], "C_PRIVATE"), ctx.meeting)

    assert {:deny, %Reason{clause: :flow_denied, detail: [:agent_private]}} =
             decide.(ctx.state, %{"notes_delivery_status" => "pending"})
  end

  test "IFC-off groups keep reads unlabelled", ctx do
    group = Ids.new_group_id(ctx.state["tenant_id"])

    {:ok, _} =
      CasRecord.create(Keys.ctl_group(group), %{
        "tenant_id" => ctx.state["tenant_id"],
        "group_id" => group,
        "router_conversation_id" => Ids.new_conversation_id(),
        "ifc" => %{"mode" => "off"}
      })

    assert nil == ReadLabels.for_meeting(Map.put(ctx.state, "group_id", group), ctx.meeting)
  end
end
