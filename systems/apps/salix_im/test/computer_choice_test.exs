defmodule SalixIM.ComputerChoiceTest do
  use ExUnit.Case, async: true

  alias SalixIM.{ComputerChoice, TaskPlacement}

  @macbook %{
    "device_id" => "dev_mbp",
    "station_id" => "aaa",
    "name" => "Peng's MacBook Pro",
    "os" => "darwin"
  }
  @mini %{
    "device_id" => "dev_mini",
    "station_id" => "bbb",
    "name" => "Mac mini (office)",
    "os" => "darwin"
  }
  @pc %{"device_id" => "dev_pc", "station_id" => "ccc", "name" => "DESKTOP-7", "os" => "windows"}
  @two [@macbook, @mini]

  defp user(text), do: %{"actor_type" => "user", "message_id" => text, "content" => text(text)}
  defp text(text), do: [%{"type" => "text", "text" => text}]

  defp decide(computers, aimed, messages),
    do: ComputerChoice.decide(computers, aimed, messages, fn _ -> nil end)

  defp card(id, labels, metadata \\ %{}) do
    %{
      "actor_type" => "agent",
      "message_id" => id,
      "metadata" => metadata,
      "content" => [
        %{
          "type" => "question",
          "prompt" => "Which?",
          "choices" =>
            Enum.map(labels, fn {choice, label} -> %{"id" => choice, "label" => label} end)
        }
      ]
    }
  end

  defp answer(question, choices, other \\ nil) do
    %{
      "actor_type" => "user",
      "message_id" => "answer-" <> question,
      "content" => [
        %{"type" => "text", "text" => "ok"},
        %{
          "type" => "question_answer",
          "question_message_id" => question,
          "choice_ids" => choices,
          "other" => other
        }
      ]
    }
  end

  test "a request that does not distinguish two computers is refused with both named" do
    assert {:error, {:computer_choice_required, @two} = reason} =
             decide(@two, [@macbook], [user("把 still.fail 在我 Mac 上用模拟器跑起来")])

    message = TaskPlacement.message({:runs_on, reason, :salix})
    assert message =~ "question card"
    assert message =~ "Mac mini (office)"
    assert message =~ "station:aaa"
  end

  test "the person's own words name a computer, however loosely" do
    for words <- ["用 mini 跑", "在 MacBook 上跑", "run it on the Mac mini (office)", "station:bbb 上跑"] do
      named = ComputerChoice.named(words, @two)
      assert named != [], words
    end

    assert decide(@two, [@mini], [user("用 mini 跑")]) == :ok
  end

  test "words alone never refuse a Task for being on the wrong computer; the Router asks once" do
    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@macbook], [user("用 mini 跑")])
  end

  test "an everyday word is not a computer's name" do
    assert decide([@macbook, @pc], [@macbook], [
             user("We need to win this benchmark"),
             user("Use MacBook Pro")
           ]) == :ok
  end

  test "a clause that rules a computer out chooses nothing" do
    tower = %{@pc | "name" => "Windows Tower"}
    words = user("Don't use Windows Tower; use the other computer")

    assert {:error, {:computer_choice_required, _}} =
             decide([@macbook, tower], [@macbook], [words])

    assert {:error, {:computer_choice_required, _}} = decide([@macbook, tower], [tower], [words])
    assert decide([@macbook, tower], [@macbook], [user("not the tower, use macbook")]) == :ok
  end

  test "an operating system names the computer only when it tells them apart" do
    assert ComputerChoice.named("在我 Mac 上跑", [@macbook, @pc]) == [@macbook]
    assert ComputerChoice.named("在我 Mac 上跑", @two) == []
  end

  test "a card's pick outranks older words, and a newer mention of the Task's computer passes" do
    asked = card("q", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])

    assert {:error, {:computer_choice_other, [@mini]}} =
             decide(@two, [@macbook], [answer("q", ["c2"]), asked, user("用 macbook")])

    assert decide(@two, [@macbook], [user("换成 macbook"), answer("q", ["c2"]), asked]) == :ok
  end

  test "a person's earlier word still counts on a follow-up turn; agents' words do not" do
    agent = %{
      "actor_type" => "agent",
      "message_id" => "a",
      "content" => text("Mac mini (office) 上跑")
    }

    assert decide(@two, [@mini], [user("再跑一次"), agent, user("用 mini")]) == :ok

    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@mini], [user("再跑一次"), agent])
  end

  test "an answered which-computer card counts by the choice picked" do
    asked = card("q", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])

    assert decide(@two, [@mini], [answer("q", ["c2"]), asked]) == :ok

    assert {:error, {:computer_choice_other, [@macbook]}} =
             decide(@two, [@mini], [answer("q", ["c1"]), asked])
  end

  test "a which-computer card answered in other words is not asked again" do
    asked = card("q", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])
    assert decide(@two, [@mini], [answer("q", [], "办公室那台"), asked]) == :ok
  end

  test "a card about something else, or a skipped card, says nothing" do
    other = card("q", [{"c1", "Debug"}, {"c2", "Release"}])

    skipped =
      put_in(answer("q", [])["content"], [
        %{"type" => "question_answer", "question_message_id" => "q", "skipped" => true}
      ])

    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@mini], [answer("q", ["c1"]), other])

    assert {:error, {:computer_choice_required, _}} = decide(@two, [@mini], [skipped, other])
  end

  test "a local-account card names the computer it is bound to" do
    asked =
      card("q", [{"use_local_account", "用这台电脑的登录"}, {"drive_remotely", "不用"}], %{
        "local_account" => %{"device_id" => "dev_mini", "runtime" => "claude"}
      })

    assert decide(@two, [@mini], [answer("q", ["drive_remotely"]), asked]) == :ok
  end

  test "a card outside the window is read by id" do
    asked = card("old", [{"c1", @macbook["name"]}, {"c2", @mini["name"]}])

    assert ComputerChoice.decide(@two, [@mini], [answer("old", ["c2"])], fn "old" -> asked end) ==
             :ok
  end

  test "a Task aims at the station it names, or a computer whose id its words carry" do
    station = %{"kind" => "station", "device_id" => "dev_mini"}
    assert ComputerChoice.aimed(@two, %{}, station) == [@mini]

    assert ComputerChoice.aimed(@two, %{}, %{"kind" => "station", "device_id" => "vmm"}) == []

    assert ComputerChoice.aimed(@two, %{"content" => "station:bbb"}, %{"kind" => "cloud_vm"}) ==
             []

    assert ComputerChoice.aimed(
             @two,
             %{"content" => "device_id station:aaa，environment station"},
             nil
           ) ==
             [@macbook]

    assert ComputerChoice.aimed(
             @two,
             %{"content" => [%{"type" => "text", "text" => "device_id dev_mini"}]},
             nil
           ) == [@mini]

    assert ComputerChoice.aimed(
             @two,
             %{"title" => "Write an article about Peng's MacBook Pro"},
             nil
           ) ==
             []

    assert ComputerChoice.aimed(@two, %{"content" => "写一篇关于 MacBook 的短文"}, nil) == []
  end

  test "external_thread_key groups Slack threads, Slack DMs, and other IM chats" do
    slack_root = %{
      "provider" => "slack",
      "provider_context" => %{
        "connect_id" => "c1",
        "channel_id" => "C1",
        "channel_type" => "mpim",
        "message_ts" => "100.1"
      }
    }

    slack_reply = %{
      "provider" => "slack",
      "provider_context" => %{
        "connect_id" => "c1",
        "channel_id" => "C1",
        "channel_type" => "mpim",
        "thread_ts" => "100.1",
        "message_ts" => "100.2"
      }
    }

    assert ComputerChoice.external_thread_key(slack_root) ==
             ComputerChoice.external_thread_key(slack_reply)

    slack_dm_1 = %{
      "provider" => "slack",
      "provider_context" => %{
        "connect_id" => "c1",
        "channel_id" => "D1",
        "channel_type" => "im",
        "message_ts" => "200.1"
      }
    }

    slack_dm_2 = %{
      "provider" => "slack",
      "provider_context" => %{
        "connect_id" => "c1",
        "channel_id" => "D1",
        "channel_type" => "im",
        "message_ts" => "200.2"
      }
    }

    assert ComputerChoice.external_thread_key(slack_dm_1) ==
             ComputerChoice.external_thread_key(slack_dm_2)

    imsg_1 = %{
      "provider" => "imessage",
      "provider_context" => %{"connect_id" => "c_im", "chat_id" => "chat_1"}
    }

    imsg_2 = %{
      "provider" => "imessage",
      "provider_context" => %{"connect_id" => "c_im", "chat_id" => "chat_1"}
    }

    assert ComputerChoice.external_thread_key(imsg_1) ==
             ComputerChoice.external_thread_key(imsg_2)
  end

  test "an external IM unplaced reply right after a which-computer question avoids looping" do
    asked = %{
      "actor_type" => "agent",
      "external_reply" => true,
      "content" => text("要在 Peng's MacBook Pro 还是 Mac mini (office) 上跑？")
    }

    assert decide(@two, [@mini], [user("第二台"), asked, user("帮我跑一下")]) == :ok

    # Explicit mention of another computer still does not silently allow the wrong target.
    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@macbook], [user("用 mini 跑"), asked, user("帮我跑一下")])

    # An unrelated later turn after a non-question agent reply asks again.
    done = %{
      "actor_type" => "agent",
      "external_reply" => true,
      "content" => text("任务已经完成了。")
    }

    assert {:error, {:computer_choice_required, _}} =
             decide(@two, [@mini], [user("再帮我跑个脚本"), done, user("第二台"), asked])
  end

  test "external IM and automatic refusal messages match the surface and hint cloud alternatives" do
    ext_msg =
      TaskPlacement.message({:runs_on, {:computer_choice_required, @two, "imessage"}, :automatic})

    assert ext_msg =~ "imessage conversation"
    refute ext_msg =~ "im_api.internal.send_message"
    assert ext_msg =~ "cloud sandbox"

    ext_other =
      TaskPlacement.message({:runs_on, {:computer_choice_other, [@mini], "slack"}, :requested})

    assert ext_other =~ "slack conversation"
    refute ext_other =~ "question card"
  end
end

defmodule SalixIM.ComputerChoicePlacementTest do
  use ExUnit.Case, async: false

  alias SalixIM.{ComputerChoice, TaskPlacement}
  alias SalixStore.Ids

  @macbook %{
    "device_id" => "dev_mbp",
    "station_id" => "aaa",
    "name" => "Peng's MacBook Pro",
    "os" => "darwin"
  }
  @mini %{
    "device_id" => "dev_mini",
    "station_id" => "bbb",
    "name" => "Mac mini (office)",
    "os" => "darwin"
  }
  @two [@macbook, @mini]

  defmodule FakePort do
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_g, _d, _t, _a), do: {:error, :unused}

    @impl true
    def personal_computers(_scope),
      do: {:ok, SystemsRuntime.get_env(:salix_im, :cc_test_computers, [])}

    @impl true
    def external_choice_messages(_scope, _origin, _limit),
      do: {:ok, SystemsRuntime.get_env(:salix_im, :cc_test_ext_messages, [])}

    @impl true
    def runs_on(_scope, _request),
      do: SystemsRuntime.get_env(:salix_im, :cc_test_runs_on, {:ok, %{"kind" => "sandbox"}})

    @impl true
    def session_model(_scope, choice), do: {:ok, choice}
  end

  setup do
    prev_port = SystemsRuntime.get_env(:salix_im, :task_create_mod)
    prev_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_im, :task_create_mod, FakePort)
    SystemsRuntime.put_env(:salix_im, :cc_test_computers, @two)
    SystemsRuntime.put_env(:salix_im, :cc_test_ext_messages, [])
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Computer choice test"})

    worker_doc =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "name" => "Worker",
        "role" => "worker"
      })

    worker = worker_doc["agent_id"]

    on_exit(fn ->
      if prev_port,
        do: SystemsRuntime.put_env(:salix_im, :task_create_mod, prev_port),
        else: SystemsRuntime.delete_env(:salix_im, :task_create_mod)

      if prev_s3,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, prev_s3),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)

      SystemsRuntime.delete_env(:salix_im, :cc_test_computers)
      SystemsRuntime.delete_env(:salix_im, :cc_test_ext_messages)
      SystemsRuntime.delete_env(:salix_im, :cc_test_runs_on)
    end)

    {:ok, tenant: tenant, group: group, worker: worker}
  end

  defp external_origin(provider, text, opts \\ []) do
    %{
      "provider" => provider,
      "source_actor_type" => Keyword.get(opts, :actor_type, "provider_user"),
      "source_message_id" => Keyword.get(opts, :message_id, "m1"),
      "source_text" => text,
      "provider_context" =>
        case provider do
          "slack" ->
            %{
              "connect_id" => "c_slack",
              "channel_id" => "C1",
              "channel_type" => "mpim",
              "thread_ts" => "100.1"
            }

          _ ->
            %{"connect_id" => "c_im", "chat_id" => "chat_1"}
        end
    }
  end

  test "external IM requests with multiple computers require choice unless named in turn or history" do
    station = %{"kind" => "station", "device_id" => "dev_mbp"}

    assert {:error, {:computer_choice_required, @two, "slack"}} =
             ComputerChoice.check(
               %{computer_choice: external_origin("slack", "帮我在本地跑一下")},
               %{},
               station
             )

    assert :ok =
             ComputerChoice.check(
               %{computer_choice: external_origin("slack", "在 MacBook Pro 上跑一下")},
               %{},
               station
             )

    SystemsRuntime.put_env(:salix_im, :cc_test_ext_messages, [
      %{
        "actor_type" => "user",
        "message_id" => "m0",
        "content" => [%{"type" => "text", "text" => "后面都用 mini 跑"}]
      }
    ])

    assert :ok =
             ComputerChoice.check(
               %{computer_choice: external_origin("imessage", "跑一下这个项目")},
               %{},
               %{"kind" => "station", "device_id" => "dev_mini"}
             )

    # Non-human provider system events do not trigger computer choice.
    assert :ok =
             ComputerChoice.check(
               %{
                 computer_choice:
                   external_origin("slack", "scheduled", actor_type: "provider_system")
               },
               %{},
               station
             )
  end

  test "automatic placement onto one of multiple personal computers requires user choice", %{
    tenant: tenant,
    group: group,
    worker: worker
  } do
    SystemsRuntime.put_env(
      :salix_im,
      :cc_test_runs_on,
      {:ok, %{"kind" => "station", "device_id" => "dev_mbp"}}
    )

    params = %{
      "model" => %{"kind" => "runtime", "provider" => "codex"}
    }

    scope = %{
      tenant_id: tenant,
      group_id: group,
      computer_choice: external_origin("imessage", "手机上下个任务帮我跑脚本")
    }

    assert {:error, {:runs_on, {:computer_choice_required, @two, "imessage"}, :automatic}} =
             TaskPlacement.resolve(scope, worker, params, false)

    assert {:error, {:runs_on, {:computer_choice_required, @two, "imessage"}, :requested}} =
             TaskPlacement.resolve(
               scope,
               worker,
               Map.put(params, "runs_on", %{"kind" => "default"}),
               false
             )

    named_scope = %{
      scope
      | computer_choice: external_origin("imessage", "在 MacBook Pro 上跑这个脚本")
    }

    assert {:ok, %{runs_on: %{"kind" => "station", "device_id" => "dev_mbp"}, source: :automatic}} =
             TaskPlacement.resolve(named_scope, worker, params, false)

    # Automatic placement landing on a sandbox is not blocked by multiple personal computers.
    SystemsRuntime.put_env(:salix_im, :cc_test_runs_on, {:ok, %{"kind" => "sandbox"}})

    assert {:ok, %{runs_on: %{"kind" => "sandbox"}, source: :automatic}} =
             TaskPlacement.resolve(scope, worker, params, false)

    # Explicit Group default_task_place (:default) stays respected without re-asking.
    SystemsRuntime.put_env(
      :salix_im,
      :cc_test_runs_on,
      {:ok, %{"kind" => "station", "device_id" => "dev_mbp"}}
    )

    {:ok, _} =
      SalixStore.CasRecord.update(SalixStore.Keys.ctl_group(group), fn doc ->
        Map.put(doc, "default_task_place", %{"kind" => "station", "device_id" => "dev_mbp"})
      end)

    assert {:ok, %{runs_on: %{"kind" => "station", "device_id" => "dev_mbp"}, source: :default}} =
             TaskPlacement.resolve(scope, worker, params, false)
  end
end
