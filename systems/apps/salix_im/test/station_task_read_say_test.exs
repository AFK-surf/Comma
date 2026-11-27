defmodule SalixIM.StationTaskReadSayTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixStore.{Ids, Keys}

  defmodule HostedTasksPort do
    @behaviour SalixIM.Ports.StationHostedTasks

    @impl true
    def read(_scope, _station_id, thread, opts) do
      owner = SystemsRuntime.fetch_env!(:salix_im, :station_task_read_say_test_pid)
      SystemsRuntime.Proc.send(owner, {:hosted_read, thread, opts})

      total =
        case thread do
          "short" -> 20
          "medium" -> 500
          "long" -> 5_000
          "stale" -> 65
          _ -> 2
        end

      after_seq = opts["after"] || 0
      limit = min(opts["limit"] || 100, 100)

      messages =
        if after_seq >= total do
          []
        else
          (after_seq + 1)..min(after_seq + limit, total)
          |> Enum.map(fn seq ->
            base = %{
              "seq" => seq,
              "author_kind" => if(rem(seq, 2) == 0, do: "agent", else: "person"),
              "author" => "member@example.test",
              "text" =>
                if(thread == "stale" and seq == 63,
                  do: "现在合并 PR #1（squash）",
                  else: "msg-#{seq}"
                ),
              "at" => seq * 1_000
            }

            cond do
              thread == "carded" and seq == total ->
                Map.put(base, "card", %{
                  "type" => "options",
                  "options" => [%{"label" => "Approve", "recommended" => true}]
                })

              thread == "stale" and seq == 62 ->
                Map.put(base, "card", %{
                  "type" => "options",
                  "options" => [
                    %{"label" => "现在合并 PR #1（squash）", "recommended" => true},
                    %{"label" => "暂不合并", "action" => "close"}
                  ]
                })

              true ->
                base
            end
          end)
        end

      {:ok,
       %{
         "title" => "Chat #{thread}",
         "through" => total,
         "messages" => messages
       }}
    end

    @impl true
    def say(_scope, _station_id, thread, text, key, requester, opts \\ %{}) do
      owner = SystemsRuntime.fetch_env!(:salix_im, :station_task_read_say_test_pid)
      SystemsRuntime.Proc.send(owner, {:hosted_say, thread, text, key, requester, opts})

      if thread == "stale" do
        {:error, {:station_refused, "stale_card: the card is no longer pending"}}
      else
        {:ok, %{"seq" => 42}}
      end
    end
  end

  defmodule Observer do
    def router_replied(group_id, conversation_id, seq) do
      owner = SystemsRuntime.fetch_env!(:salix_im, :station_task_read_say_test_pid)
      SystemsRuntime.Proc.send(owner, {:router_replied, group_id, conversation_id, seq})
      :ok
    end
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    keys = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_im, :station_hosted_tasks_mod, HostedTasksPort},
      {:salix_im, :station_task_observer, Observer},
      {:salix_im, :station_task_read_say_test_pid, SystemsRuntime.Proc.self()}
    ]

    previous =
      Enum.map(keys, fn {app, key, _value} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    Enum.each(keys, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        Enum.each(previous, fn
          {app, key, nil} -> SystemsRuntime.delete_env(app, key)
          {app, key, value} -> SystemsRuntime.put_env(app, key, value)
        end)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Station Hosted Read"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    station_id = String.duplicate("ab", 32)
    {:ok, group_id: group_id, router_id: router["agent_id"], station_id: station_id}
  end

  defp router_call(agent_id, api, params) do
    SalixIM.Provider.call_api(agent_id, "internal", api, %{
      "connect_id" => "internal",
      "params" => params
    })
  end

  test "read_conversation honors tail on short, medium and long station-hosted Tasks while preserving default after_seq behavior",
       ctx do
    short_ref = "station:#{ctx.station_id}:short"

    assert {:ok, %{"messages" => default_msgs, "through_seq" => 20}} =
             router_call(ctx.router_id, "internal.read_conversation", %{
               "conversation_id" => short_ref
             })

    assert_received {:hosted_read, "short", %{"after" => 0, "limit" => 50}}
    assert length(default_msgs) == 20

    assert {:ok, %{"messages" => short_tail, "through_seq" => 20}} =
             router_call(ctx.router_id, "internal.read_conversation", %{
               "conversation_id" => short_ref,
               "tail" => 12
             })

    assert_received {:hosted_read, "short", %{"after" => 0, "limit" => 100}}
    refute_received {:hosted_read, "short", _}
    assert Enum.map(short_tail, & &1["seq"]) == Enum.to_list(9..20)

    medium_ref = "station:#{ctx.station_id}:medium"

    assert {:ok, %{"messages" => medium_tail, "through_seq" => 500}} =
             router_call(ctx.router_id, "internal.read_conversation", %{
               "conversation_id" => medium_ref,
               "tail" => 12
             })

    assert Enum.map(medium_tail, & &1["seq"]) == Enum.to_list(489..500)

    long_ref = "station:#{ctx.station_id}:long"

    assert {:ok, %{"messages" => long_tail, "through_seq" => 5_000}} =
             router_call(ctx.router_id, "internal.read_conversation", %{
               "conversation_id" => long_ref,
               "tail" => 12
             })

    assert Enum.map(long_tail, & &1["seq"]) == Enum.to_list(4_989..5_000)

    long_reads = drain_reads("long", [])
    assert length(long_reads) <= 4
  end

  test "send_message on a station-hosted Task notifies the station_task_observer", ctx do
    ref = "station:#{ctx.station_id}:short"

    assert {:ok, %{"conversation_id" => ^ref, "seq" => 42, "hosted_on_station" => true}} =
             router_call(ctx.router_id, "internal.send_message", %{
               "conversation_id" => ref,
               "content" => "Ship the migration",
               "request_id" => "req-42"
             })

    assert_received {:hosted_say, "short", "Ship the migration", "req-42", "Router", %{}}
    assert_received {:router_replied, group_id, ^ref, 42}
    assert group_id == ctx.group_id
  end

  test "send_message on a station-hosted Task accepts text content block arrays", ctx do
    ref = "station:#{ctx.station_id}:short"

    assert {:ok, %{"conversation_id" => ^ref, "seq" => 42, "hosted_on_station" => true}} =
             router_call(ctx.router_id, "internal.send_message", %{
               "conversation_id" => ref,
               "content" => [%{"type" => "text", "text" => "Block array reply"}],
               "request_id" => "req-blocks-1"
             })

    assert_received {:hosted_say, "short", "Block array reply", "req-blocks-1", "Router", %{}}
  end

  test "server-built independent Home cards sync replies with CAS, handle stale_card, preserve Routine on dismiss, and fold by card_seq",
       ctx do
    {:ok, home} = SalixIM.RouterConversationInput.ensure(ctx.group_id)
    home_id = home["conversation_id"]
    ref = "station:#{ctx.station_id}:carded"

    # 0. Router cannot self-bind or forge `independent: true` via internal.send_message.
    assert {:ok, %{"message_id" => router_q_id}} =
             router_call(ctx.router_id, "internal.send_message", %{
               "conversation_id" => home_id,
               "request_id" => "router-q-1",
               "content" => [
                 %{
                   "type" => "question",
                   "source_ref" => ref,
                   "independent" => true,
                   "prompt" => "Router own question?",
                   "choices" => [%{"label" => "Yes"}, %{"label" => "No"}]
                 }
               ]
             })

    {:ok, router_q_msg} =
      SalixIM.Conversations.get_group_conversation_message(ctx.group_id, home_id, router_q_id)

    refute get_in(router_q_msg, ["metadata", "station_task_question"])
    refute SalixIM.ConversationQuestion.question_block(router_q_msg["content"])["independent"]

    # 1. Server builds an independent bound card for a CAS-capable station (with close action).
    card_messages = [
      %{
        "seq" => 17,
        "author_kind" => "agent",
        "text" => "Long comparison table...",
        "card" => %{
          "type" => "options",
          "options" => [
            %{"label" => "顺便改掉", "detail" => "立刻动手", "recommended" => true},
            %{"label" => "不用改", "action" => "close"}
          ]
        }
      }
    ]

    assert {:ok, built_cas} =
             SalixIM.StationTaskQuestionSync.build_home_notification(
               %{
                 ref: ref,
                 kind: "need",
                 card_kind: "options",
                 title: "PinShot 首页更新",
                 url: "https://still.fail/c/17",
                 note: "需要改代码吗？",
                 observation: "needs_review:1000",
                 cas_supported?: true,
                 locale: "zh-CN"
               },
               messages: card_messages
             )

    # Legacy station without `task_say_cas: 1` fails closed to a link without a clickable card.
    assert {:ok, built_legacy} =
             SalixIM.StationTaskQuestionSync.build_home_notification(
               %{
                 ref: ref,
                 kind: "need",
                 card_kind: "options",
                 title: "PinShot 首页更新",
                 url: "https://still.fail/c/17",
                 note: "需要改代码吗？",
                 observation: "needs_review:1000",
                 cas_supported?: false,
                 locale: "zh-CN"
               },
               messages: card_messages
             )

    assert is_nil(SalixIM.ConversationQuestion.question_block(built_legacy.content))
    assert built_legacy.metadata == %{}
    assert built_legacy.advise_router == true

    assert Enum.any?(
             built_legacy.content,
             &String.contains?(&1["text"] || "", "Long comparison table...")
           )

    assert built_cas.advise_router == true
    assert built_cas.router_context["excerpt"] == "Long comparison table..."
    assert built_cas.router_context["choices"] == ["顺便改掉", "不用改"]

    assert Enum.any?(built_cas.content, fn b ->
             b["type"] == "text" and String.contains?(b["text"] || "", "Long comparison table...")
           end)

    {:ok, %{"message_id" => q1_id}} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        ctx.group_id,
        home_id,
        ctx.router_id,
        %{
          "content" => built_cas.content,
          "client_request_id" => "direct-card-1",
          "delivery_filter" => %{"participant_ids" => []},
          "metadata" => built_cas.metadata
        }
      )

    {:ok, q1_msg} =
      SalixIM.Conversations.get_group_conversation_message(ctx.group_id, home_id, q1_id)

    q1_block = SalixIM.ConversationQuestion.question_block(q1_msg["content"])
    assert q1_block["skip_behavior"] == "dismiss"
    assert q1_block["independent"] == true
    assert q1_msg["metadata"]["station_task_question"]["conversation_id"] == ref
    assert q1_msg["metadata"]["station_task_question"]["card_seq"] == 17
    assert q1_msg["metadata"]["station_task_question"]["close_choice_ids"] == ["c2"]

    # 2. User picks the close-action option -> synced directly with close_card AND expected_card_seq CAS.
    assert {:ok, %{"message_id" => a1_id}} =
             SalixIM.RouterConversationInput.append_user_message(ctx.group_id, %{
               "user_id" => "usr_owner",
               "client_request_id" => "ans-close-1",
               "reply_to_message_id" => q1_id,
               "content" => [
                 %{"type" => "text", "text" => "不用改"},
                 %{
                   "type" => "question_answer",
                   "question_message_id" => q1_id,
                   "choice_ids" => ["c2"],
                   "skipped" => false
                 }
               ]
             })

    assert_received {:hosted_say, "carded", "不用改", "comma-card:ans-close-1", "Router",
                     %{"close_card" => true, "expected_card_seq" => 17}}

    assert_received {:router_replied, _, ^ref, 42}

    {:ok, a1_msg} =
      SalixIM.Conversations.get_group_conversation_message(ctx.group_id, home_id, a1_id)

    assert a1_msg["delivery_filter"] == %{"participant_ids" => []}
    assert a1_msg["metadata"]["synced_to_stillfail"]["closed_card"] == true

    # 2b. Late Router async advice replying to an already-answered/dismissed
    # still.fail card is rejected so no orphan bubble lands below a folded card.
    assert {:error, {:conflict, "station_task_question already resolved"}} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               ctx.group_id,
               home_id,
               ctx.router_id,
               %{
                 "content" => [%{"type" => "text", "text" => "Late advice after close"}],
                 "client_request_id" => "late-advice-1",
                 "reply_to_message_id" => q1_id
               }
             )

    # 2c. Failed stops sanitize raw OAuth/HTTP error dumps instead of posting
    # raw exception stacks into Home chat.
    assert {:ok, built_auth_fail} =
             SalixIM.StationTaskQuestionSync.build_home_notification(%{
               ref: ref,
               kind: "failed",
               title: "mbui 集成方式解析",
               url: "https://still.fail/c/fail-401",
               note:
                 "auth: UNAUTHENTICATED (code 401): Request had invalid authentication credentials. Expected OAuth 2 access token. See https://developers.google.com/identity/sign-in/web/devconsole-project.",
               observation: "failed:3000",
               locale: "zh-CN"
             })

    [fail_block] = built_auth_fail.content
    assert fail_block["text"] =~ "认证已失效"
    refute fail_block["text"] =~ "UNAUTHENTICATED"
    refute fail_block["text"] =~ "developers.google.com"

    # 3. Single-choice independent card dismissed in Home -> never calls still.fail, never closes Routine matter.
    assert {:ok, built_single} =
             SalixIM.StationTaskQuestionSync.build_home_notification(
               %{
                 ref: ref,
                 kind: "need",
                 card_kind: "options",
                 title: "Single option",
                 url: "https://still.fail/c/18",
                 note: "Confirm deploy?",
                 observation: "needs_review:2000",
                 cas_supported?: true,
                 locale: "en"
               },
               messages: [
                 %{
                   "seq" => 22,
                   "author_kind" => "agent",
                   "card" => %{
                     "type" => "options",
                     "options" => [%{"label" => "Confirm", "recommended" => true}]
                   }
                 }
               ]
             )

    {:ok, %{"message_id" => q2_id}} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        ctx.group_id,
        home_id,
        ctx.router_id,
        %{
          "content" => built_single.content,
          "client_request_id" => "direct-card-2",
          "delivery_filter" => %{"participant_ids" => []},
          "metadata" => built_single.metadata
        }
      )

    assert {:ok, %{"message_id" => a2_id}} =
             SalixIM.RouterConversationInput.append_user_message(ctx.group_id, %{
               "user_id" => "usr_owner",
               "client_request_id" => "ans-dismiss-2",
               "reply_to_message_id" => q2_id,
               "content" => [
                 %{"type" => "text", "text" => "Dismissed."},
                 %{
                   "type" => "question_answer",
                   "question_message_id" => q2_id,
                   "choice_ids" => [],
                   "skipped" => true
                 }
               ]
             })

    refute_received {:hosted_say, _, _, _, _, _}
    refute_received {:router_replied, _, _, _}

    {:ok, a2_msg} =
      SalixIM.Conversations.get_group_conversation_message(ctx.group_id, home_id, a2_id)

    assert a2_msg["delivery_filter"] == %{"participant_ids" => []}
    assert a2_msg["metadata"]["dismissed_station_task"] == ref

    # 4. Exact card_seq matching distinguishes resolved vs superseded receipts.
    q_block = SalixIM.ConversationQuestion.question_block(built_cas.content)

    assert {"顺便改掉", %{"choice_ids" => ["c1"], "skipped" => false}} =
             SalixIM.StationTaskQuestionSync.resolve_stillfail_answer(
               q_block,
               [
                 %{
                   "seq" => 17,
                   "author_kind" => "agent",
                   "card" => %{"type" => "options", "closed" => true, "choice" => "顺便改掉"}
                 },
                 %{
                   "seq" => 25,
                   "author_kind" => "agent",
                   "card" => %{"type" => "options", "options" => [%{"label" => "New Q"}]}
                 }
               ],
               card_seq: 17
             )

    assert {"Replaced by a newer question.", %{"choice_ids" => [], "skipped" => true}} =
             SalixIM.StationTaskQuestionSync.resolve_stillfail_answer(
               q_block,
               [
                 %{
                   "seq" => 17,
                   "author_kind" => "agent",
                   "card" => %{"type" => "options", "options" => [%{"label" => "顺便改掉"}]}
                 },
                 %{
                   "seq" => 25,
                   "author_kind" => "agent",
                   "card" => %{"type" => "options", "options" => [%{"label" => "New Q"}]}
                 }
               ],
               card_seq: 17,
               reason: :superseded,
               locale: "en"
             )
  end

  test "read_conversation preserves sanitized card payload on station-hosted Task messages",
       ctx do
    ref = "station:#{ctx.station_id}:carded"

    assert {:ok, %{"messages" => [_first, second]}} =
             router_call(ctx.router_id, "internal.read_conversation", %{
               "conversation_id" => ref
             })

    assert second["card"] == %{
             "type" => "options",
             "options" => [%{"label" => "Approve", "recommended" => true}]
           }
  end

  test "Home independent card answer forwards requester_email to StationHostedTasks.say without persisting it",
       ctx do
    ref = "station:#{ctx.station_id}:carded"
    {:ok, home} = SalixIM.RouterConversationInput.ensure(ctx.group_id)

    {:ok, notif} =
      SalixIM.StationTaskQuestionSync.build_home_notification(
        %{
          ref: ref,
          observation: "obs-1",
          title: "Deploy check",
          url: "https://app.monoid.zone/chats/carded",
          kind: "need",
          card_kind: "options",
          note: "Approve deploy?",
          cas_supported?: true
        },
        messages: [
          %{
            "seq" => 12,
            "author_kind" => "agent",
            "card" => %{
              "type" => "options",
              "options" => [%{"label" => "Approve"}]
            }
          }
        ]
      )

    {:ok, card_msg} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        ctx.group_id,
        home["conversation_id"],
        home["router_agent_id"],
        %{
          "content" => notif.content,
          "metadata" => notif.metadata
        }
      )

    question_block = SalixIM.ConversationQuestion.question_block(notif.content)
    choice_id = hd(question_block["choices"])["id"]

    assert {:ok, stored_answer} =
             SalixIM.RouterConversationInput.append_user_message(ctx.group_id, %{
               "user_id" => "usr_1",
               "requester_email" => "owner@comma.test",
               "client_request_id" => "req-card-ans-1",
               "reply_to_message_id" => card_msg["message_id"],
               "content" => [
                 %{
                   "type" => "question_answer",
                   "question_message_id" => card_msg["message_id"],
                   "choice_ids" => [choice_id]
                 }
               ]
             })

    assert_received {:hosted_say, "carded", "Approve", _key, _requester, opts}
    assert opts["requester_email"] == "owner@comma.test"
    assert opts["expected_card_seq"] == 12
    refute Map.has_key?(stored_answer, "requester_email")
  end

  test "internal.send_message rejects spoofed requester_email in LLM tool params and omits it on normal calls",
       ctx do
    ref = "station:#{ctx.station_id}:short"

    assert {:error, err} =
             router_call(ctx.router_id, "internal.send_message", %{
               "conversation_id" => ref,
               "content" => "Hello from router",
               "request_id" => "req-spoof-1",
               "requester_email" => "spoofed@evil.test"
             })

    assert err =~ "accepts only"

    assert {:ok, %{"seq" => 42}} =
             router_call(ctx.router_id, "internal.send_message", %{
               "conversation_id" => ref,
               "content" => "Hello from router",
               "request_id" => "req-normal-1"
             })

    assert_received {:hosted_say, "short", "Hello from router", "req-normal-1", _requester, opts}
    refute Map.has_key?(opts, "requester_email")
  end

  test "build_home_notification replaces relative still.fail image tags with inline placeholders" do
    {:ok, notif} =
      SalixIM.StationTaskQuestionSync.build_home_notification(
        %{
          ref: "station:s1:385",
          observation: "obs-img",
          title: "角色立绘选择",
          url: "https://app.still.fail/o/afk-ai/mini/chats/385",
          kind: "need",
          card_kind: "options",
          note: "挑一个角色",
          locale: "zh-CN",
          cas_supported?: true
        },
        messages: [
          %{
            "seq" => 10,
            "author_kind" => "agent",
            "text" =>
              "**A · 酒红歌剧千金**\n\n![](r1999_new_A_burgundy.jpg)\n\n![](https://example.com/ok.png)",
            "card" => %{
              "type" => "options",
              "options" => [%{"label" => "做 A"}]
            }
          }
        ]
      )

    [%{"type" => "text", "text" => header}, %{"type" => "question"} | _] = notif.content
    assert header =~ "[图片: r1999_new_A_burgundy.jpg]"
    refute header =~ "![](r1999_new_A_burgundy.jpg)"
    assert header =~ "![](https://example.com/ok.png)"
  end

  test "resolve_stillfail_answer strips leading blockquotes before matching choices and caps long other text" do
    q_block = %{
      "type" => "question",
      "prompt" => "选哪个角色",
      "choices" => [
        %{"id" => "c1", "label" => "做 C（复古神秘学家）"},
        %{"id" => "c2", "label" => "做 A（酒红歌剧千金）"}
      ],
      "allow_other" => true
    }

    assert {"做 C（复古神秘学家）", %{"choice_ids" => ["c1"], "skipped" => false}} =
             SalixIM.StationTaskQuestionSync.resolve_stillfail_answer(
               q_block,
               [
                 %{
                   "seq" => 10,
                   "author_kind" => "agent",
                   "card" => %{"type" => "options", "options" => [%{"label" => "做 C（复古神秘学家）"}]}
                 },
                 %{
                   "seq" => 11,
                   "author_kind" => "person",
                   "text" => "> 完全赞同这个方向——很长一段引用\n> 第二行引用\n\n做 C（复古神秘学家）"
                 }
               ],
               card_seq: 10
             )

    long_other = String.duplicate("a", 400)

    assert {display, %{"choice_ids" => [], "other" => other, "skipped" => false}} =
             SalixIM.StationTaskQuestionSync.resolve_stillfail_answer(
               q_block,
               [
                 %{
                   "seq" => 10,
                   "author_kind" => "agent",
                   "card" => %{"type" => "options", "options" => [%{"label" => "做 C（复古神秘学家）"}]}
                 },
                 %{
                   "seq" => 11,
                   "author_kind" => "person",
                   "text" => "> 引用\n\n" <> long_other
                 }
               ],
               card_seq: 10
             )

    assert byte_size(other) <= 240
    assert display == other
    assert String.ends_with?(other, "…")
  end

  test "stale_card click folds from station tail and returns ok without conflict or duplicate receipts",
       ctx do
    ref = "station:#{ctx.station_id}:stale"
    {:ok, home} = SalixIM.RouterConversationInput.ensure(ctx.group_id)
    home_id = home["conversation_id"]

    {:ok, notif} =
      SalixIM.StationTaskQuestionSync.build_home_notification(
        %{
          ref: ref,
          observation: "obs-stale",
          title: "Farview 运行状态检查",
          url: "https://app.still.fail/o/afk-ai/pengx17/chats/stale",
          kind: "need",
          card_kind: "options",
          note: "需要我现在帮你合进 main 吗？",
          locale: "zh-CN",
          cas_supported?: true
        },
        messages: [
          %{
            "seq" => 62,
            "author_kind" => "agent",
            "card" => %{
              "type" => "options",
              "options" => [
                %{"label" => "现在合并 PR #1（squash）", "recommended" => true},
                %{"label" => "暂不合并", "action" => "close"}
              ]
            }
          }
        ]
      )

    {:ok, %{"message_id" => q_id}} =
      SalixIM.ConversationServer.append_group_conversation_agent_message(
        ctx.group_id,
        home_id,
        ctx.router_id,
        %{
          "content" => notif.content,
          "client_request_id" => "stale-card-q-1",
          "delivery_filter" => %{"participant_ids" => []},
          "metadata" => notif.metadata
        }
      )

    question_block = SalixIM.ConversationQuestion.question_block(notif.content)
    choice_id = hd(question_block["choices"])["id"]

    # First click hits station CAS `stale_card`: folds from tail (>50 msgs) and returns {:ok, folded}.
    assert {:ok, %{"message_id" => folded_id}} =
             SalixIM.RouterConversationInput.append_user_message(ctx.group_id, %{
               "user_id" => "usr_owner",
               "client_request_id" => "ios-click-1",
               "reply_to_message_id" => q_id,
               "client_metadata" => %{"locale" => "zh-CN"},
               "content" => [
                 %{"type" => "text", "text" => "现在合并 PR #1（squash）"},
                 %{
                   "type" => "question_answer",
                   "question_message_id" => q_id,
                   "choice_ids" => [choice_id],
                   "skipped" => false
                 }
               ]
             })

    assert_received {:hosted_say, "stale", "现在合并 PR #1（squash）", "comma-card:ios-click-1",
                     "Router", %{"expected_card_seq" => 62}}

    {:ok, folded_msg} =
      SalixIM.Conversations.get_group_conversation_message(ctx.group_id, home_id, folded_id)

    assert [%{"type" => "question_answer", "choice_ids" => [^choice_id], "skipped" => false}] =
             folded_msg["content"]

    assert folded_msg["metadata"]["resolved_in_stillfail"] == true

    # Second click (retry from an out-of-date client) reuses the existing folded answer with no duplicate.
    assert {:ok, %{"message_id" => ^folded_id, "inserted" => false}} =
             SalixIM.RouterConversationInput.append_user_message(ctx.group_id, %{
               "user_id" => "usr_owner",
               "client_request_id" => "ios-click-2",
               "reply_to_message_id" => q_id,
               "content" => [
                 %{"type" => "text", "text" => "现在合并 PR #1（squash）"},
                 %{
                   "type" => "question_answer",
                   "question_message_id" => q_id,
                   "choice_ids" => [choice_id],
                   "skipped" => false
                 }
               ]
             })
  end

  test "build_home_notification includes staged file blocks and strips their relative markdown refs while falling back for unstaged images",
       ctx do
    ref = "station:#{ctx.station_id}:img-card"

    staged_file = %{
      "type" => "file",
      "path" => "/uploads/stillfail/abcdef0123456789/win-flat-simple.png",
      "file_name" => "win-flat-simple.png",
      "blob_ref" => %{"uuid" => "blob-1", "size" => 1234, "sha256" => "deadbeef"}
    }

    assert {:ok, built} =
             SalixIM.StationTaskQuestionSync.build_home_notification(
               %{
                 ref: ref,
                 kind: "need",
                 card_kind: "options",
                 title: "图标调整",
                 url: "https://still.fail/c/img",
                 note: "选哪版图标？",
                 observation: "needs_review:2000",
                 cas_supported?: true,
                 locale: "zh-CN"
               },
               messages: [
                 %{
                   "seq" => 8,
                   "author_kind" => "agent",
                   "text" => "先看两张预览：\n\n![](win-flat-simple.png)\n\n![](fallback.png)",
                   "card" => %{
                     "type" => "options",
                     "options" => [%{"label" => "用第一版", "recommended" => true}]
                   }
                 }
               ],
               attachments: [staged_file]
             )

    assert [
             %{"type" => "text", "text" => text},
             ^staged_file,
             %{"type" => "question", "independent" => true},
             %{"type" => "text", "fallback_for" => "question"}
           ] = built.content

    refute text =~ "win-flat-simple.png"
    assert text =~ "[图片: fallback.png]"
    assert built.router_context["excerpt"] =~ "[图片: win-flat-simple.png]"
  end

  defp drain_reads(thread, acc) do
    receive do
      {:hosted_read, ^thread, opts} -> drain_reads(thread, [opts | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
