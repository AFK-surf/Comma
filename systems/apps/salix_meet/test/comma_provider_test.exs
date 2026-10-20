defmodule SalixMeet.CommaProviderTest do
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.SalixMeet"]

  alias SalixMeet.{CommaProvider, ProviderDispatcher, RuntimeEvents, Store}
  alias SalixStore.{Keys, S3}

  defmodule RuntimeDriver do
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def join(doc) do
      Agent.update(__MODULE__, &[doc | &1])
      SystemsRuntime.get_env(:salix_meet, :comma_test_join_result, :ok)
    end

    def calls, do: Agent.get(__MODULE__, &Enum.reverse/1)
  end

  # The runtime answers that no bot runs, which permits the store's join retry.
  defmodule NoSession do
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(_payload), do: {:error, :not_configured}

    @impl true
    def send_chat(_payload), do: {:error, :not_configured}

    @impl true
    def session_status(_payload), do: {:ok, :none}
  end

  defmodule Chat do
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def post(group_id, conversation_id, agent_id, key, text) do
      Agent.update(__MODULE__, fn posts ->
        if Enum.any?(posts, &(&1.key == key)),
          do: posts,
          else:
            posts ++
              [
                %{
                  group: group_id,
                  conversation: conversation_id,
                  agent: agent_id,
                  key: key,
                  text: text
                }
              ]
      end)

      {:ok, %{"message_id" => key}}
    end

    def posts, do: Agent.get(__MODULE__, & &1)
    def texts, do: Enum.map(posts(), & &1.text)
  end

  setup do
    envs = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, SalixAgent.LLM.Mock},
      {:salix_meet, :runtime_driver, RuntimeDriver},
      {:salix_meet, :comma_test_join_result, :ok},
      {:salix_meet, :meeting_dispatch_mod, NoSession},
      {:salix_meet, :agent_runtime_mod, SalixMeet.TestAgentRuntime},
      {:salix_meet, :comma_chat_mod, Chat},
      {:salix_meet, :meeting_status_notifier_mod, ProviderDispatcher}
    ]

    previous =
      Enum.map(envs, fn {app, key, value} ->
        old = SystemsRuntime.fetch_env(app, key)
        SystemsRuntime.put_env(app, key, value)
        {app, key, old}
      end)

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> SystemsRuntime.put_env(app, key, value)
        {app, key, :error} -> SystemsRuntime.delete_env(app, key)
      end)
    end)

    if is_nil(SystemsRuntime.Proc.whereis(SalixStore.S3.Fake)),
      do: start_supervised!(SalixStore.S3.Fake)

    SalixStore.S3.Fake.reset()
    start_supervised!(RuntimeDriver)
    start_supervised!(Chat)

    tenant_id = SalixStore.Ids.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    now = SystemsClock.system_time(:second)

    {:ok, _} =
      S3.put(
        Keys.ctl_group(group_id),
        Jason.encode!(%{
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "name" => "Workspace",
          "created_at" => now,
          "updated_at" => now
        }),
        if_none_match: "*"
      )

    source = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "conversation_id" => SalixStore.Ids.new_conversation_id(),
      "message_id" => "msg-1",
      "user_id" => "usr_sender",
      "agent_id" => "agent-router",
      "language" => "zh-CN",
      "text" => "帮我参加这个会 https://meet.google.com/abc-defg-hij"
    }

    %{source: source}
  end

  test "one message makes one guest join and its status speaks in the sender's language",
       %{source: source} do
    assert {:ok, %{"meeting_id" => meeting_id, "status" => "joining"}} =
             CommaProvider.join_from_router(source, %{})

    assert {:ok, %{"status" => "already_active"}} = CommaProvider.join_from_router(source, %{})

    assert [join] = RuntimeDriver.calls()
    assert join["id"] == meeting_id
    assert join["state"]["meet_url"] == "https://meet.google.com/abc-defg-hij"
    assert join["state"]["runtime_policy"]["join_as"] == "guest"
    assert join["state"]["comma_ref"]["conversation_id"] == source["conversation_id"]

    assert [%{agent: "agent-router", text: "正在以访客身份加入 Google Meet…"} = joining] =
             Chat.posts()

    assert joining.conversation == source["conversation_id"]
  end

  test "a later message with the same Meet reuses the running meeting until it ends",
       %{source: source} do
    {:ok, %{"meeting_id" => first}} = CommaProvider.join_from_router(source, %{})

    again = %{
      source
      | "message_id" => "msg-2",
        "text" => "进去了吗 https://meet.google.com/abc-defg-hij?authuser=0"
    }

    assert {:ok, %{"meeting_id" => ^first, "status" => "already_active"}} =
             CommaProvider.join_from_router(again, %{})

    elsewhere = %{again | "conversation_id" => SalixStore.Ids.new_conversation_id()}
    assert {:ok, %{"meeting_id" => other}} = CommaProvider.join_from_router(elsewhere, %{})
    assert other != first
    assert length(RuntimeDriver.calls()) == 2
    assert length(Chat.posts()) == 2

    runtime_status(first, %{"status" => "left"}, "left-1")
    {:ok, _, _} = Store.update_state_retrying(first, &Map.put(&1, "status", "done"))

    assert {:ok, %{"meeting_id" => next, "status" => "joining"}} =
             CommaProvider.join_from_router(again, %{})

    assert next not in [first, other]
  end

  test "a later message retries a join the runtime refused instead of reusing the stuck meeting",
       %{source: source} do
    SystemsRuntime.put_env(:salix_meet, :comma_test_join_result, {:error, :runtime_busy})
    assert {:error, {:join_failed, _reason}} = CommaProvider.join_from_router(source, %{})
    assert [%{"id" => first}] = RuntimeDriver.calls()

    SystemsRuntime.put_env(:salix_meet, :comma_test_join_result, :ok)
    again = %{source | "message_id" => "msg-2"}

    assert {:ok, %{"meeting_id" => ^first, "status" => "already_active"}} =
             CommaProvider.join_from_router(again, %{})

    assert [%{"id" => ^first}, %{"id" => ^first}] = RuntimeDriver.calls()

    assert {:ok, %{"state" => %{"join_dispatch" => %{"status" => "dispatched"}}}, _} =
             Store.get(first)

    assert {:ok, %{"status" => "already_active"}} = CommaProvider.join_from_router(again, %{})
    assert length(RuntimeDriver.calls()) == 2
  end

  test "a link is found whatever its case", %{source: source} do
    upper = %{source | "text" => "join HTTPS://MEET.GOOGLE.COM/ABC-DEFG-HIJ please"}
    assert {:ok, %{"meeting_id" => first}} = CommaProvider.join_from_router(upper, %{})

    lower = %{source | "message_id" => "msg-2"}

    assert {:ok, %{"meeting_id" => ^first, "status" => "already_active"}} =
             CommaProvider.join_from_router(lower, %{})
  end

  test "the chat shows waiting, joined and the reason the runtime reports", %{source: source} do
    {:ok, %{"meeting_id" => meeting_id}} = CommaProvider.join_from_router(source, %{})

    for {status, n} <- Enum.with_index(~w(waiting_room in_meeting in_meeting)) do
      runtime_status(meeting_id, %{"status" => status}, "s-#{n}")
    end

    runtime_status(
      meeting_id,
      %{"status" => "error", "reason_code" => "removed_from_meeting"},
      "s-err"
    )

    assert tl(Chat.texts()) == ["等待主持人批准入会。", "已加入会议。", "已被移出会议。"]
    assert {:ok, %{"state" => %{"status" => "failed"}}, _} = Store.get(meeting_id)
  end

  test "the Router names one of a message's two links; any other link is refused",
       %{source: source} do
    first = "https://meet.google.com/abc-defg-hij"
    second = "https://meet.google.com/xyz-abcd-efg"
    source = %{source | "text" => "#{first} or #{second}"}

    assert {:error, :ambiguous_meet_urls} = CommaProvider.join_from_router(source, %{})

    assert {:error, :meet_url_not_in_current_source} =
             CommaProvider.join_from_router(source, %{
               "meet_url" => "https://meet.google.com/aaa-bbbb-ccc"
             })

    assert RuntimeDriver.calls() == []
    assert Chat.posts() == []

    assert {:ok, _} = CommaProvider.join_from_router(source, %{"meet_url" => second})
    assert [%{"state" => %{"meet_url" => ^second}}] = RuntimeDriver.calls()
  end

  test "without a meeting runtime the Router gets the reason and nothing joins",
       %{source: source} do
    SystemsRuntime.delete_env(:salix_meet, :runtime_driver)

    assert {:error, :meeting_runtime_not_configured} =
             CommaProvider.join_from_router(source, %{})

    assert {:ok, []} = Store.list()
    assert Chat.posts() == []
  end

  test "the finished meeting's notes go back to the original chat", %{source: source} do
    {:ok, %{"meeting_id" => meeting_id}} = CommaProvider.join_from_router(source, %{})

    {:ok, _, _} =
      Store.update_state_retrying(meeting_id, fn state ->
        Map.merge(state, %{
          "status" => "done",
          "summary" => %{
            "title" => "周会",
            "key_points" => ["发布推迟到周五"],
            "action_items" => [
              %{"description" => "更新发布计划", "owner" => "Alice", "deadline" => "周四"}
            ]
          }
        })
      end)

    {:ok, _state, _etag, claim} = Store.claim_delivery(meeting_id, "test")
    payload = %{"meeting_id" => meeting_id, "kind" => "summary", "delivery_claim" => claim}

    assert {:ok, %{"published" => true}} = ProviderDispatcher.publish(%{}, payload)

    notes = Chat.texts() |> List.last()
    assert notes =~ "### 会议纪要：周会"
    assert notes =~ "- 发布推迟到周五"
    assert notes =~ "- 更新发布计划; 负责人: Alice; 截止: 周四"
    assert length(Chat.posts()) == 2

    assert {:ok, %{"state" => %{"delivery" => %{"status" => "published"}}}, _} =
             Store.get(meeting_id)
  end

  defp runtime_status(meeting_id, status, source_id) do
    event = %{
      "type" => "joiner_event",
      "meeting_id" => meeting_id,
      "joiner_event" => Map.merge(%{"type" => "status", "timestamp" => 1}, status)
    }

    assert {:ok, prepared} = RuntimeEvents.prepare(%{}, event)
    assert :ok = RuntimeEvents.apply(prepared, source_id)
  end
end
