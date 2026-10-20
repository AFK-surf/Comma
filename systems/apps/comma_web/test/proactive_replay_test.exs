defmodule CommaWeb.ProactiveReplayTest do
  use ExUnit.Case, async: true

  alias CommaWeb.{MemberPortrait, ProactiveReplay}

  @case_path Path.expand("fixtures/proactive_replay/patrol_token_2026_10_11.json", __DIR__)

  setup do
    {:ok, kase: ProactiveReplay.load!(@case_path)}
  end

  test "judges the pending items the recorded Slack reads produce, with the production messages",
       %{kase: kase} do
    test = self()

    judge = fn messages ->
      %{"candidates" => candidates} = user_input(messages)
      send(test, {:judged, candidates})
      alert = Enum.find(candidates, &(Jason.encode!(&1) =~ "PATROL_CREDIT_TOKEN"))
      {:ok, "Answer: " <> Jason.encode!(%{"most_urgent" => urgent(alert["id"], "ask")})}
    end

    [first, injected] =
      ProactiveReplay.run(
        scenarios(kase, ~w(first_collection_without_portrait judge_if_collected)),
        judge
      )

    # Without a portrait the first collection reads only direct relationships;
    # mentions older than the check window are not judged.
    assert "mention_share_logs" in first["collected"]
    assert first["pending"] == []
    assert first["judgment"] == %{"outcome" => "idle"}

    # The alert and the bot's reply in its thread are one matter, judged
    # through the newest message.
    assert ["owner_ask_1305z", "alert_1304z"] in injected["matters"]
    assert %{"outcome" => "routed", "url" => "owner_ask_1305z"} = injected["judgment"]

    # A handoff carries what the matter's links say now.
    linked = injected["judgment"]["linked"]

    assert %{"kind" => "slack_thread", "replies" => 2} =
             Enum.find(linked, &(&1["kind"] == "slack_thread"))

    assert %{"conclusion" => "failure", "attempt" => 1} =
             Enum.find(linked, &(&1["kind"] == "github_actions_run"))
  end

  test "the portrait keeps only evidenced entries and reaches the judgment", %{kase: kase} do
    test = self()

    judge = fn messages ->
      case user_input(messages) do
        %{"ownMessages" => [own | _] = all} ->
          send(test, {:own, all})

          {:ok,
           Jason.encode!(%{
             "entries" => [
               %{
                 "kind" => "duty",
                 "text" => "renews the patrol token",
                 "evidence" => [own["permalink"]]
               },
               %{
                 "kind" => "duty",
                 "text" => "approves payroll",
                 "evidence" => ["https://example.com/made-up"]
               }
             ]
           })}

        %{"candidates" => candidates} = input ->
          send(test, {:member, input["member"]})
          alert = Enum.find(candidates, &(Jason.encode!(&1) =~ "patrol failed"))
          {:ok, Jason.encode!(%{"most_urgent" => urgent(alert["id"], "critical")})}
      end
    end

    [scenario] = ProactiveReplay.run(scenarios(kase, ~w(judge_if_collected_with_portrait)), judge)

    # The owner's messages carry the start of the thread each answered.
    assert_received {:own, own}
    assert Enum.any?(own, &(&1["text"] == "换了 auth token 了" and &1["thread"] =~ "401"))

    # The entry lands in the portrait section of the Router's memory file,
    # dated, in the owner's language, before the file's other facts.
    assert [
             %{"text" => "关于你 · 职责: renews the patrol token · 2026-10-11"},
             %{"text" => "Prefers short replies in Chinese."}
           ] = scenario["portrait"]

    assert_received {:member,
                     [
                       "关于你 · 职责: renews the patrol token · 2026-10-11",
                       "Prefers short replies in Chinese."
                     ]}

    assert %{"outcome" => "routed", "urgency" => "critical"} = scenario["judgment"]
  end

  test "the portrait's targets read where the owner's work is reported, filtered by rules",
       %{kase: kase} do
    test = self()

    judge = fn messages ->
      case user_input(messages) do
        %{"ownMessages" => [own | _]} ->
          watch = ["#patrol-test", "#made-up", "kw:payroll"]

          {:ok,
           Jason.encode!(%{
             "entries" => [
               %{
                 "kind" => "duty",
                 "text" => "renews the patrol token",
                 "evidence" => [own["permalink"]],
                 "watch" => watch
               }
             ]
           })}

        %{"candidates" => candidates} ->
          send(test, {:candidates, candidates})
          {:ok, ~s({"most_urgent": null})}
      end
    end

    [scenario] = ProactiveReplay.run(scenarios(kase, ~w(steady_state)), judge)
    queries = Enum.map(scenario["queries"], & &1["query"])

    # Only channels the input names survive; keywords are not targets.
    assert "in:#patrol-test after:2026-10-10" in queries
    refute Enum.any?(queries, &(is_binary(&1) and (&1 =~ "made-up" or &1 =~ "payroll")))

    # A thread counts once, by its latest message; chatter without a request,
    # a bot or the owner's terms stays out.
    assert "owner_ask_1305z" in scenario["pending"]
    refute "alert_1304z" in scenario["collected"]
    assert_received {:candidates, candidates}

    assert Enum.all?(
             candidates,
             &(&1["relationship"] == "posted_where_your_work_is")
           )
  end

  test "a portrait entry not confirmed for 60 days expires, except an exclusion" do
    note = """
    # User

    - Prefers short replies.

    <!-- comma:portrait: Comma keeps this section from your own messages; tell your Router to change it -->
    - 关于你 · 职责: renews the patrol token · 2026-08-01
    - 关于你 · 不归你: payroll approvals · 2026-06-01
    - 关于你 · 常在: patrol-test · 2026-10-01
    <!-- /comma:portrait -->

    - Lives in Shanghai.
    """

    input = MemberPortrait.input([], [], MemberPortrait.statements(note), "kai")
    assert input["facts"] == ["Prefers short replies.", "Lives in Shanghai."]

    kept = fn kind, text -> %{"kind" => kind, "text" => text, "evidence" => ["previous"]} end

    {:ok, entries} =
      MemberPortrait.build(
        %{
          "entries" => [
            kept.("duty", "renews the patrol token"),
            kept.("exclusion", "payroll approvals"),
            kept.("place", "patrol-test"),
            kept.("ongoing", "a reworded entry nobody confirmed")
          ]
        },
        input,
        ~D[2026-10-12]
      )

    assert Enum.map(entries, &{&1["text"], &1["seen"]}) == [
             {"payroll approvals", ~D[2026-06-01]},
             {"patrol-test", ~D[2026-10-01]}
           ]

    # The refresh replaces only the portrait section.
    assert Enum.map(
             MemberPortrait.statements(MemberPortrait.render_note(note, entries, "zh-CN")),
             & &1["text"]
           ) ==
             [
               "关于你 · 不归你: payroll approvals · 2026-06-01",
               "关于你 · 常在: patrol-test · 2026-10-01",
               "Prefers short replies.",
               "Lives in Shanghai."
             ]
  end

  test "personal mail is judged from its text, and a loss that cannot be undone soon is critical" do
    kase =
      "fixtures/proactive_replay/personal_mail_2026_10_13.json"
      |> Path.expand(__DIR__)
      |> ProactiveReplay.load!()

    # The judge answers low, as staging did, but states what the mail says.
    # The deadline and the loss are past the 255-character preview.
    judge = fn messages ->
      %{"candidates" => candidates} = user_input(messages)

      answer =
        case Enum.find(candidates, &(Jason.encode!(&1) =~ "within the next 3 days")) do
          %{"id" => id} ->
            %{
              "id" => id,
              "cost" => "LastPass deletes the account and its vault",
              "due" => "2026-10-16T02:00:44Z",
              "reversible" => false,
              "urgency" => "low",
              "message" => "LastPass 3 天后会永久删除你的账号。要我提醒你登录吗？"
            }

          nil ->
            %{
              "id" => hd(candidates)["id"],
              "cost" => "",
              "due" => nil,
              "reversible" => true,
              "urgency" => "low",
              "message" => "没有需要你处理的。"
            }
        end

      {:ok, Jason.encode!(%{"most_urgent" => answer})}
    end

    [lastpass, nothing] =
      ProactiveReplay.run(scenarios(kase, ~w(lastpass_among_noise nothing_to_lose)), judge)

    assert %{
             "outcome" => "routed",
             "url" => "lastpass_final",
             "urgency" => "critical",
             "assessment" => %{"reversible" => false, "due" => "2026-10-16T02:00:44Z"}
           } = lastpass["judgment"]

    assert Enum.all?(lastpass["checks"], & &1["pass"])

    assert %{"outcome" => "quiet", "urgency" => "low", "assessment" => %{"cost" => ""}} =
             nothing["judgment"]

    assert Enum.all?(nothing["checks"], & &1["pass"])
  end

  test "an owner's preference stays in the portrait like an exclusion" do
    note = """
    <!-- comma:portrait: Comma keeps this section from your own messages; tell your Router to change it -->
    - 关于你 · 偏好: always tell me before an account is deleted · 2026-06-01
    - 关于你 · 进行中: the spring launch · 2026-06-01
    <!-- /comma:portrait -->
    """

    input = MemberPortrait.input([], [], MemberPortrait.statements(note), "kai")
    kept = fn kind, text -> %{"kind" => kind, "text" => text, "evidence" => ["previous"]} end

    {:ok, entries} =
      MemberPortrait.build(
        %{
          "entries" => [
            kept.("preference", "always tell me before an account is deleted"),
            kept.("ongoing", "the spring launch")
          ]
        },
        input,
        ~D[2026-10-12]
      )

    assert Enum.map(entries, & &1["text"]) == ["always tell me before an account is deleted"]
  end

  defp scenarios(kase, names),
    do: Map.update!(kase, "scenarios", fn all -> Enum.filter(all, &(&1["name"] in names)) end)

  defp user_input(messages) do
    [content] = for %{role: "user", content: content} <- messages, do: content
    Jason.decode!(content)
  end

  defp urgent(id, urgency),
    do: %{"id" => id, "urgency" => urgency, "message" => "巡检挂了。要我看看吗？"}
end
