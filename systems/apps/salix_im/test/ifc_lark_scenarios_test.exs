defmodule SalixIM.IFCLarkScenariosTest do
  @moduledoc """
  Information flow through one shared Lark Router session, end to end on the
  runtime side: real Lark ingress labels, the real facts resolver against a
  stubbed Lark OpenAPI, and the dispatch check that stands in front of every
  provider effect.
  """

  use SystemsClock.Case, async: false

  alias SalixAgent.IFC.{Check, Context}
  alias SalixIM.{AgentDeliveryPayload, ProviderConnects}
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @a "ou_alice"
  @b "ou_bob"
  @c "ou_carol"
  @chat_a "oc_p2p_alice"
  @chat_b "oc_p2p_bob"
  @team "oc_team"

  defmodule API do
    @moduledoc false
    import Plug.Conn

    @page_sizes Enum.map(1..100, &Integer.to_string/1)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)
      body = if raw == "", do: conn.query_params, else: Jason.decode!(raw)
      ["open-apis" | path] = conn.path_info
      {status, answer} = answer(conn.method, path, body)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(answer))
    end

    defp answer("POST", ["auth", "v3", "tenant_access_token", "internal"], body),
      do: {200, %{"code" => 0, "tenant_access_token" => "t-" <> body["app_id"], "expire" => 7200}}

    defp answer("GET", ["bot", "v3", "info"], _body),
      do: {200, %{"code" => 0, "bot" => %{"open_id" => "ou_bot", "app_name" => "Bot"}}}

    defp answer("GET", ["im", "v1", "chats", chat_id], _body) do
      case Map.get(chats(), chat_id) do
        nil ->
          {404, %{"code" => 404, "msg" => "not found"}}

        chat ->
          {200,
           %{"code" => 0, "data" => Map.drop(chat, ["members", "member_pages", "members_error"])}}
      end
    end

    # Lark's documented bound, and its answer to a request past it.
    defp answer("GET", ["im", "v1", "chats", _chat_id, "members"], %{"page_size" => size})
         when size not in @page_sizes do
      {400, %{"code" => 232_001, "msg" => "invalid request parameter"}}
    end

    defp answer("GET", ["im", "v1", "chats", chat_id, "members"], query) do
      case Map.get(chats(), chat_id) do
        %{"members_error" => {status, code}} ->
          {status, %{"code" => code, "msg" => "secret provider text about ou_secret"}}

        %{"member_pages" => pages} ->
          page = String.to_integer(Map.get(query, "page_token", "0"))
          more = page + 1 < length(pages)

          {200,
           %{
             "code" => 0,
             "data" => %{
               "items" => Enum.map(Enum.at(pages, page), &%{"member_id" => &1}),
               "has_more" => more,
               "page_token" => if(more, do: Integer.to_string(page + 1))
             }
           }}

        %{"members" => members, "has_more" => true} ->
          {200,
           %{
             "code" => 0,
             "data" => %{"items" => Enum.map(members, &%{"member_id" => &1}), "has_more" => true}
           }}

        %{"members" => members} ->
          {200,
           %{
             "code" => 0,
             "data" => %{
               "items" => Enum.map(members, &%{"member_id" => &1}),
               "has_more" => false
             }
           }}

        _other ->
          {404, %{"code" => 404, "msg" => "not found"}}
      end
    end

    defp answer(_method, _path, _body), do: {404, %{"code" => 404, "msg" => "not found"}}

    defp chats, do: SystemsRuntime.get_env(:salix_im, :ifc_lark_test_chats, %{})
  end

  setup do
    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      api: SystemsRuntime.get_env(:salix_im, :lark_api_base_url),
      facts: SystemsRuntime.get_env(:salix_agent, :ifc_facts_mod)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    SystemsRuntime.put_env(
      :salix_im,
      :lark_api_base_url,
      BanditServer.serve!(API) <> "/open-apis"
    )

    SystemsRuntime.put_env(:salix_agent, :ifc_facts_mod, SalixIM.IFC.Facts)
    SalixIM.Provider.Lark.API.reset_token_cache()

    SystemsRuntime.put_env(:salix_im, :ifc_lark_test_chats, %{
      @chat_a => %{"chat_mode" => "p2p"},
      @chat_b => %{"chat_mode" => "p2p"},
      @team => %{"chat_mode" => "group", "chat_type" => "private", "members" => [@a, @b]}
    })

    for table <-
          ~w(ifc_scope_labels ifc_tag_clearances ifc_principal_facts ifc_scope_facts ifc_scope_members ifc_receipts) do
      SalixStore.Repo.query!("DELETE FROM #{table}")
    end

    on_exit(fn ->
      for {app, key, value} <- [
            {:salix_store, :s3_backend, previous.s3},
            {:salix_im, :lark_api_base_url, previous.api},
            {:salix_agent, :ifc_facts_mod, previous.facts}
          ] do
        if value,
          do: SystemsRuntime.put_env(app, key, value),
          else: SystemsRuntime.delete_env(app, key)
      end

      SystemsRuntime.delete_env(:salix_im, :ifc_lark_test_chats)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant)

    router =
      SalixAgent.TestSupport.create_control_agent!(Ids.new_agent_id(group_id), %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _} =
      CasRecord.update(Keys.ctl_group(group_id), fn group ->
        group
        |> Map.put("router_agent_id", router["agent_id"])
        |> Map.put("ifc", %{"mode" => "enforce"})
      end)

    {:ok, connect} =
      ProviderConnects.create_lark_im_connect(tenant, group_id, %{
        "app_id" => "cli_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        "app_secret" => "secret",
        "verification_token" => "token",
        "encrypt_key" => "key"
      })

    {:ok, group} = SalixIM.GroupDirectory.get_group(group_id, tenant)
    {:ok, router} = SalixIM.GroupDirectory.get_agent(router["agent_id"])

    %{tenant: tenant, group_id: group_id, group: group, router: router, connect: connect}
  end

  # One Lark inbound, through the same delivery funnel the webhook uses.
  defp inbound(env, id, sender, chat_id, chat_type, text) do
    source_id = "im_provider:lark:#{env.connect["connect_id"]}:#{id}"

    metadata = %{
      "provider" => "lark",
      "connect_id" => env.connect["connect_id"],
      "chat_id" => chat_id,
      "chat_type" => chat_type,
      "message_id" => id,
      "sender_open_id" => sender,
      "sender_type" => "user",
      "event_type" => "lark.message",
      "source_actor_type" => "provider_user"
    }

    {:ok, delivery} =
      AgentDeliveryPayload.provider_router_delivery(env.group, env.router, text, metadata,
        source_message_id: source_id
      )

    %{source_id: source_id, origin: delivery["trusted_origin"], text: text}
  end

  # The Router session holding every inbound so far, acting on `current`.
  defp context(env, messages, current) do
    records =
      messages
      |> Enum.with_index(1)
      |> Enum.map(fn {message, seq} ->
        %{
          id: seq,
          role: "user",
          source_message_id: message.source_id,
          trusted_origin: message.origin
        }
      end)

    wire =
      Context.build(%{messages: records},
        source_message_id: current.source_id,
        source_message_ids: [current.source_id],
        trusted_origin: current.origin
      )

    %{
      messages: messages,
      ifc: wire,
      ifc_mode: :enforce,
      tenant_id: env.tenant,
      group_id: env.group_id,
      trusted_origin: current.origin
    }
  end

  # Each record's ref is its transcript position.
  defp ref(ctx, message) do
    seq = Enum.find_index(ctx.messages, &(&1.source_id == message.source_id)) + 1
    ref = "src:q-#{seq}"
    true = Enum.any?(ctx.ifc["items"], &(&1["ref"] == ref))
    ref
  end

  defp send(ctx, op, params, sources) do
    call = %{
      id: "call-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      name: "im_api.lark." <> op,
      args: params,
      ifc: %{"sources" => sources}
    }

    case Check.authorize([{:execute, call}], ctx) do
      [{:execute, _}] -> :allowed
      [{:blocked, _}] -> :blocked
    end
  end

  # The background listing ingress asks for (`SalixIM.IFC.MemberRefresh`),
  # run in place: test config does not start it.
  defp listed(env, chat_id) do
    SalixIM.IFC.Projection.refresh(
      %{tenant_id: env.tenant, group_id: env.group_id, connect_id: env.connect["connect_id"]},
      chat_id
    )
  end

  setup env do
    a = inbound(env, "om_a1", @a, @chat_a, "p2p", "Redis 3 期周五上线，ISO 文档审核员那边还没谈好")
    b = inbound(env, "om_b1", @b, @chat_b, "p2p", "Levin 跟审核员具体说了什么")
    team = inbound(env, "om_t1", @a, @team, "group", "@bot 本周发布节奏")
    listed(env, @team)
    %{a: a, b: b, team: team}
  end

  test "A's private chat does not reach B, by chat or by person", env do
    ctx = context(env, [env.a, env.team, env.b], env.b)
    leak = [ref(ctx, env.a)]

    assert send(ctx, "send_message", %{"chat_id" => @chat_b, "text" => "x"}, leak) == :blocked
    assert send(ctx, "send_message", %{"text" => "x"}, leak) == :blocked
    assert send(ctx, "send_message", %{"user_id" => @b, "text" => "x"}, leak) == :blocked
    assert send(ctx, "send_message", %{"chat_id" => @team, "text" => "x"}, leak) == :blocked
    # Undeclared sources mean the whole context, which holds A's chat.
    assert send(ctx, "send_message", %{"chat_id" => @chat_b, "text" => "x"}, "context") ==
             :blocked
  end

  test "B's own question is answered in B's chat, and A's in A's", env do
    ctx_b = context(env, [env.a, env.b], env.b)
    assert send(ctx_b, "send_message", %{"text" => "x"}, [ref(ctx_b, env.b)]) == :allowed
    assert send(ctx_b, "send_message", %{"chat_id" => @chat_b, "text" => "x"}, []) == :allowed

    ctx_a = context(env, [env.a, env.b], env.a)
    assert send(ctx_a, "send_message", %{"text" => "x"}, [ref(ctx_a, env.a)]) == :allowed
  end

  test "a group's content reaches its members, not anyone else", env do
    c = inbound(env, "om_c1", @c, "oc_p2p_carol", "p2p", "hi")
    ctx = context(env, [env.team, c, env.b], env.b)
    group = [ref(ctx, env.team)]

    assert send(ctx, "send_message", %{"chat_id" => @team, "text" => "x"}, group) == :allowed
    assert send(ctx, "send_message", %{"user_id" => @b, "text" => "x"}, group) == :allowed
    assert send(ctx, "send_message", %{"user_id" => @c, "text" => "x"}, group) == :blocked
  end

  test "a private chat keeps its person after the projection goes stale", env do
    # Fifteen minutes on, the chat's structure is read from Lark again. Lark
    # does not name the person of a p2p chat, so nothing may forget who it is.
    SystemsClock.manual()
    on_exit(&SystemsClock.reset/0)
    SystemsClock.advance(SalixIM.IFC.Projection.ttl_ms() + 1_000)
    ctx = context(env, [env.a, env.b], env.a)
    a = [ref(ctx, env.a)]
    b = [ref(ctx, env.b)]

    assert send(ctx, "send_message", %{"chat_id" => @chat_a, "text" => "x"}, a) == :allowed
    assert send(ctx, "send_message", %{"chat_id" => @chat_a, "text" => "x"}, b) == :blocked
  end

  describe "a Group supervisor" do
    setup env do
      SystemsRuntime.put_env(
        :salix_im,
        :ifc_lark_test_chats,
        SystemsRuntime.get_env(:salix_im, :ifc_lark_test_chats)
        |> Map.put("oc_p2p_carol", %{"chat_mode" => "p2p"})
        |> Map.put("oc_partner", %{
          "chat_mode" => "group",
          "external" => true,
          "members" => [@a, "ou_partner"]
        })
      )

      carol = "provider_user|#{env.connect["connect_id"]}|#{@c}"

      {:ok, _} =
        CasRecord.update(Keys.ctl_group(env.group_id), fn group ->
          put_in(group, ["ifc", "supervisors"], [carol])
        end)

      %{carol: inbound(env, "om_c1", @c, "oc_p2p_carol", "p2p", "本周各组进展如何")}
    end

    test "reads every group and private chat from her own chat", env do
      ctx = context(env, [env.a, env.team, env.carol], env.carol)
      sources = [ref(ctx, env.a), ref(ctx, env.team)]

      assert send(ctx, "send_message", %{"text" => "x"}, sources) == :allowed
      assert send(ctx, "send_message", %{"user_id" => @c, "text" => "x"}, sources) == :allowed
    end

    test "reads a chat shared with another organization", env do
      partner = inbound(env, "om_p1", @a, "oc_partner", "group", "@bot 报价")
      listed(env, "oc_partner")
      ctx = context(env, [partner, env.carol], env.carol)

      assert send(ctx, "send_message", %{"text" => "x"}, [ref(ctx, partner)]) == :allowed
    end

    test "gives nobody else her reach", env do
      ctx = context(env, [env.a, env.carol, env.b], env.b)

      assert send(ctx, "send_message", %{"text" => "x"}, [ref(ctx, env.a)]) == :blocked
      assert send(ctx, "send_message", %{"text" => "x"}, [ref(ctx, env.carol)]) == :blocked
    end

    test "reads a sealed chat, and its members keep its content", env do
      {:ok, _} =
        SalixStore.IFC.put_scope_label(
          env.tenant,
          env.group_id,
          env.connect["connect_id"],
          @team,
          %{sealed: true}
        )

      ctx = context(env, [env.team, env.carol], env.carol)
      assert send(ctx, "send_message", %{"text" => "x"}, [ref(ctx, env.team)]) == :allowed

      ctx = context(env, [env.team, env.b], env.b)

      assert send(ctx, "send_message", %{"chat_id" => @chat_b, "text" => "x"}, [
               ref(ctx, env.team)
             ]) == :allowed
    end
  end

  describe "a group with more members than one page" do
    setup env do
      fillers = Enum.map(1..100, &"ou_member_#{&1}")
      put_chat("oc_large", %{"member_pages" => [fillers, fillers, [@a]]})
      put_chat("oc_too_large", %{"member_pages" => List.duplicate(fillers, 10) ++ [[@a]]})
      put_chat("oc_empty_pages", %{"member_pages" => List.duplicate([], 10) ++ [[@a]]})

      unrelated = inbound(env, "om_elsewhere", @a, @chat_a, "p2p", "问题")
      %{ctx: context(env, [unrelated], unrelated)}
    end

    test "is read to its last page", %{ctx: ctx} = env do
      listed(env, "oc_large")

      assert send(ctx, "send_message", %{"chat_id" => "oc_large", "text" => "x"}, []) == :allowed
    end

    test "past the limit, leaves writers unknown", %{ctx: ctx} = env do
      listed(env, "oc_too_large")

      assert send(ctx, "send_message", %{"chat_id" => "oc_too_large", "text" => "x"}, []) ==
               :blocked
    end

    test "stops at the page limit when pages come back empty", %{ctx: ctx} = env do
      listed(env, "oc_empty_pages")

      assert send(ctx, "send_message", %{"chat_id" => "oc_empty_pages", "text" => "x"}, []) ==
               :blocked
    end

    defp put_chat(chat_id, chat) do
      SystemsRuntime.put_env(
        :salix_im,
        :ifc_lark_test_chats,
        Map.put(
          SystemsRuntime.get_env(:salix_im, :ifc_lark_test_chats),
          chat_id,
          Map.merge(%{"chat_mode" => "group", "chat_type" => "private"}, chat)
        )
      )
    end
  end

  describe "a group whose members cannot be listed" do
    setup env do
      handler = {__MODULE__, env.test}

      :ok =
        SystemsRuntime.Telemetry.attach(
          handler,
          [:salix, :operation, :stop],
          &__MODULE__.member_lookup/4,
          SystemsRuntime.Proc.self()
        )

      :ok =
        :logger.add_handler(:ifc_lark_members_test, __MODULE__.MemberLog, %{
          config: %{owner: SystemsRuntime.Proc.self()}
        })

      on_exit(fn ->
        SystemsRuntime.Telemetry.detach(handler)
        :logger.remove_handler(:ifc_lark_members_test)
      end)

      :ok
    end

    for {name, chat, outcome, log} <- [
          {"a refused lookup", %{"members_error" => {400, 230_027}}, "rejected",
           %{reason: :provider_error, lark_code: "230027", http_status: 400}},
          {"a failed lookup", %{"members_error" => {500, 1500}}, "failed",
           %{reason: :provider_error, lark_code: "1500", http_status: 500}},
          {"a partial list", %{"members" => [@a], "has_more" => true}, "partial",
           %{reason: :incomplete}}
        ] do
      test "#{name} leaves writers unknown and says why, without ids or text", env do
        chat_id = "oc_lookup_#{unquote(outcome)}"

        chat =
          Map.merge(
            %{"chat_mode" => "group", "chat_type" => "private"},
            unquote(Macro.escape(chat))
          )

        SystemsRuntime.put_env(
          :salix_im,
          :ifc_lark_test_chats,
          Map.put(SystemsRuntime.get_env(:salix_im, :ifc_lark_test_chats), chat_id, chat)
        )

        unrelated = inbound(env, "om_elsewhere", @a, @chat_a, "p2p", "问题")
        ctx = context(env, [unrelated], unrelated)

        log =
          ExUnit.CaptureLog.capture_log([metadata: :all], fn ->
            listed(env, chat_id)

            assert send(ctx, "send_message", %{"chat_id" => chat_id, "text" => "x"}, []) ==
                     :blocked
          end)

        expected = unquote(outcome)
        fields = Map.put(unquote(Macro.escape(log)), :outcome, expected)
        assert_received {:member_lookup, %{operation: "ifc_lark_members", outcome: ^expected}}
        assert_received {:member_log, ^fields}
        refute log =~ "secret provider text"
        refute log =~ chat_id
        refute log =~ @a
      end
    end
  end

  describe "a mention in a group whose members cannot be listed" do
    setup env do
      chats = SystemsRuntime.get_env(:salix_im, :ifc_lark_test_chats)

      unlisted = %{
        "chat_mode" => "group",
        "chat_type" => "private",
        "members_error" => {400, 230_027}
      }

      SystemsRuntime.put_env(
        :salix_im,
        :ifc_lark_test_chats,
        chats |> Map.put("oc_unlisted", unlisted) |> Map.put("oc_other_unlisted", unlisted)
      )

      question = inbound(env, "om_in_place", @a, "oc_unlisted", "group", "@bot 问题")
      %{question: question, ctx: context(env, [env.b, question], question)}
    end

    test "is answered in that group, with that mention as its source", %{ctx: ctx} = env do
      reply = %{"chat_id" => "oc_unlisted", "text" => "x"}
      assert send(ctx, "send_message", reply, [ref(ctx, env.question)]) == :allowed
      assert send(ctx, "send_message", Map.put(reply, "reply_to", "om_in_place"), []) == :allowed
    end

    test "the answer still cannot carry what the group may not read", %{ctx: ctx} = env do
      reply = %{"chat_id" => "oc_unlisted", "text" => "x"}
      assert send(ctx, "send_message", reply, [ref(ctx, env.b)]) == :blocked
      assert send(ctx, "send_message", reply, "context") == :blocked
    end

    # In-place use admits a requester's own unsealed content, and it does so
    # whether or not the group's members can be listed.
    test "the answer can carry the requester's own private content", env do
      ctx = context(env, [env.a, env.question], env.question)

      assert send(ctx, "send_message", %{"chat_id" => "oc_unlisted", "text" => "x"}, [
               ref(ctx, env.a)
             ]) == :allowed
    end

    test "a group with known members treats that content the same way", env do
      ctx = context(env, [env.a, env.team], env.team)

      assert send(ctx, "send_message", %{"chat_id" => @team, "text" => "x"}, [ref(ctx, env.a)]) ==
               :allowed
    end

    test "gives no standing in any other unlisted group", %{ctx: ctx} = env do
      reply = %{"chat_id" => "oc_other_unlisted", "text" => "x"}
      assert send(ctx, "send_message", reply, [ref(ctx, env.question)]) == :blocked
      assert send(ctx, "send_message", reply, []) == :blocked
    end

    test "another person's activation has no standing in it", env do
      other = inbound(env, "om_other", @b, @chat_b, "p2p", "hi")
      ctx = context(env, [other], other)

      assert send(ctx, "send_message", %{"chat_id" => "oc_unlisted", "text" => "x"}, []) ==
               :blocked
    end
  end

  defmodule MemberLog do
    @moduledoc false
    def log(%{meta: %{ifc_lark_members: fields}}, %{config: %{owner: owner}}),
      do: SystemsRuntime.Proc.send(owner, {:member_log, fields})

    def log(_event, _config), do: :ok
  end

  @doc false
  def member_lookup(_event, _measurements, metadata, owner) do
    if metadata[:operation] == "ifc_lark_members",
      do: SystemsRuntime.Proc.send(owner, {:member_lookup, metadata})
  end

  test "documents carry the same rule", env do
    ctx = context(env, [env.a, env.b], env.b)
    leak = [ref(ctx, env.a)]

    assert send(
             ctx,
             "share_doc",
             %{"doc" => "doxA", "member_type" => "user", "member_id" => @b},
             leak
           ) == :blocked

    assert send(
             ctx,
             "create_doc",
             %{"title" => "t", "share_user_id" => @b},
             leak
           ) == :blocked
  end
end
