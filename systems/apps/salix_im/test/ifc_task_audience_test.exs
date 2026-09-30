defmodule SalixIM.IFCTaskAudienceTest do
  use ExUnit.Case, async: false

  alias SalixIM.IFC.{AudiencePlacement, Facts}
  alias SalixIFC.{Activation, Codec, Effect, Item, Label}
  alias SalixStore.{Ids, Keys, S3}
  alias SalixStore.IFC, as: Store

  defmodule Slack do
    use Plug.Builder
    plug(:dispatch)

    defp dispatch(conn, _) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      id = URI.decode_query(body)["user"]

      payload =
        Agent.get_and_update(__MODULE__, fn {profiles, calls} ->
          {Map.get(profiles, id, %{"ok" => false, "error" => "user_not_found"}),
           {profiles, [id | calls]}}
        end)

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(payload))
    end
  end

  setup do
    previous = Application.get_env(:salix_store, :s3_backend)
    base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    if Process.whereis(S3.Fake), do: S3.Fake.reset(), else: start_supervised!(S3.Fake)

    start_supervised!(%{
      id: Slack,
      start: {Agent, :start_link, [fn -> {%{}, []} end, [name: Slack]]}
    })

    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    start_supervised!({Bandit, plug: Slack, port: port})
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")
    :ets.delete_all_objects(:salix_ifc_audience_placement)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous)

      if base,
        do: Application.put_env(:salix_im, :slack_api_base_url, base),
        else: Application.delete_env(:salix_im, :slack_api_base_url)
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    connect = Ids.new_connect_id()
    task = Ids.new_conversation_id()
    worker = Ids.new_agent_id(group)
    scope = %{tenant_id: tenant, group_id: group, connect_id: connect}

    put(Keys.ctl_group(group), %{
      "group_id" => group,
      "tenant_id" => tenant,
      "router_conversation_id" => Ids.new_conversation_id(),
      "ifc" => %{"mode" => "enforce"}
    })

    installation = %{
      "group_id" => group,
      "tenant_id" => tenant,
      "connect_id" => connect,
      "provider" => "slack",
      "bot_token" => "xoxb-test",
      "workspace_id" => "TTEST",
      "connect_generation" => "generation-1"
    }

    put(Keys.ctl_im_connect(group, connect), installation)
    ctx = %{scope: scope, task: task, worker: worker, installation: installation}
    task(ctx, ["U1"])
    profile("U1", %{"id" => "U1"})
    {:ok, ctx}
  end

  defp put(key, value), do: S3.put(key, Jason.encode!(value))
  defp principal(ctx, id), do: "provider_user|#{ctx.scope.connect_id}|#{id}"

  defp profile(id, user) do
    Agent.update(Slack, fn {profiles, calls} ->
      {Map.put(profiles, id, %{"ok" => true, "user" => user}), calls}
    end)
  end

  defp calls, do: Agent.get(Slack, fn {_, calls} -> Enum.reverse(calls) end)

  defp task(ctx, members) do
    put(Keys.ctl_group_conversation(ctx.scope.group_id, ctx.task), %{
      "conversation_id" => ctx.task,
      "kind" => "agent_task",
      "source_refs" => %{"ifc_members" => Enum.map(members, &principal(ctx, &1))}
    })
  end

  defp facts(ctx) do
    {:ok, facts} =
      Facts.resolve(%{
        "tenant_id" => ctx.scope.tenant_id,
        "group_id" => ctx.scope.group_id,
        "requester" => "agent|#{ctx.worker}",
        "atoms" => ["space|#{ctx.scope.connect_id}", "task|#{ctx.task}"],
        "destination" => %{"kind" => "conversation", "conversation_id" => ctx.task},
        "trusted_origin" => %{"provider" => "internal", "ifc" => %{"integrity" => "data"}}
      })

    facts
  end

  defp decide(ctx, facts) do
    destination = Label.new([{:task, ctx.task}])
    actor = {:agent, ctx.worker}

    activation = %Activation{
      requester: actor,
      source_scope: destination,
      consumed_refs: MapSet.new(["src:q-2"])
    }

    items = [
      %Item{ref: "src:q-2", label: destination, integrity: :command, principal: actor},
      %Item{ref: "src:a-16", label: Label.new([{:space, ctx.scope.connect_id}]), integrity: :data}
    ]

    effect = %Effect{
      destination: destination,
      writers: :any,
      request: "src:q-2",
      sources: ["src:a-16"]
    }

    SalixIFC.decide(effect, activation, items, Codec.decode_facts(facts))
  end

  test "an agent report resolves its human Task audience and passes IFC", ctx do
    resolved = facts(ctx)
    assert resolved["placements"][principal(ctx, "U1")][ctx.scope.connect_id] == "internal"
    assert {:allow, _} = decide(ctx, resolved)
    assert calls() == ["U1"]
    assert {:allow, _} = decide(ctx, facts(ctx))
    assert calls() == ["U1"]
  end

  test "guest, stranger, deleted, missing and mismatched profiles never grant space access",
       ctx do
    for {id, user} <- [
          {"UG", %{"id" => "UG", "is_restricted" => true}},
          {"US", %{"id" => "US", "is_stranger" => true}},
          {"UD", %{"id" => "UD", "deleted" => true}},
          {"UM", %{}},
          {"UX", %{"id" => "somebody-else"}}
        ] do
      task(ctx, [id])
      profile(id, user)
      assert {:deny, _} = decide(ctx, facts(ctx))
    end

    task(ctx, ["UNOTFOUND"])
    assert {:deny, %{clause: :membership_unknown}} = decide(ctx, facts(ctx))
  end

  test "all Task readers must belong to the source audience", ctx do
    task(ctx, ["U1", "U2"])
    profile("U2", %{"id" => "U2", "is_ultra_restricted" => true})
    assert {:deny, _} = decide(ctx, facts(ctx))
    assert Enum.sort(calls()) == ["U1", "U2"]
  end

  test "an operator override takes precedence over a cached provider observation", ctx do
    assert {:allow, _} = decide(ctx, facts(ctx))

    assert {:ok, _} =
             Store.put_principal_fact(
               ctx.scope.tenant_id,
               ctx.scope.group_id,
               ctx.scope.connect_id,
               "U1",
               "external"
             )

    assert {:deny, _} = decide(ctx, facts(ctx))
    assert calls() == ["U1"]
  end

  test "expiration and installation replacement do not reuse an old grant", ctx do
    assert {:allow, _} = decide(ctx, facts(ctx))
    profile("U1", %{"id" => "U1", "is_restricted" => true})

    for {slot, key, _, value} <- :ets.tab2list(:salix_ifc_audience_placement) do
      :ets.insert(
        :salix_ifc_audience_placement,
        {slot, key, System.monotonic_time(:millisecond) - 1, value}
      )
    end

    assert {:deny, _} = decide(ctx, facts(ctx))
    profile("U1", %{"id" => "U1"})

    put(
      Keys.ctl_im_connect(ctx.scope.group_id, ctx.scope.connect_id),
      Map.put(ctx.installation, "connect_generation", "generation-2")
    )

    assert {:allow, _} = decide(ctx, facts(ctx))
    assert calls() == ["U1", "U1", "U1"]
  end

  test "a disabled or wrong-tenant installation cannot reuse a cached grant", ctx do
    assert {:allow, _} = decide(ctx, facts(ctx))

    put(
      Keys.ctl_im_connect(ctx.scope.group_id, ctx.scope.connect_id),
      Map.put(ctx.installation, "disabled_at", 1)
    )

    assert {:deny, _} = decide(ctx, facts(ctx))

    put(
      Keys.ctl_im_connect(ctx.scope.group_id, ctx.scope.connect_id),
      Map.put(ctx.installation, "tenant_id", "another-tenant")
    )

    assert {:deny, _} = decide(ctx, facts(ctx))
    assert calls() == ["U1"]
  end

  test "provider reads are bounded and unresolved Task members still block", ctx do
    ids = Enum.map(1..21, &"U#{&1}")
    Enum.each(ids, fn id -> profile(id, %{"id" => id}) end)
    task(ctx, ids)
    assert {:deny, _} = decide(ctx, facts(ctx))
    assert length(calls()) == 20
    assert :ets.info(:salix_ifc_audience_placement, :size) <= 4096
  end

  test "non-Slack connections do not infer membership", ctx do
    put(
      Keys.ctl_im_connect(ctx.scope.group_id, ctx.scope.connect_id),
      Map.put(ctx.installation, "provider", "feishu")
    )

    assert AudiencePlacement.resolve(ctx.scope, ["U1"]) == %{}
    assert calls() == []
  end
end
