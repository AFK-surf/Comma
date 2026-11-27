defmodule CommaWeb.ProactiveCheckTest do
  use ExUnit.Case, async: true

  alias Comma.Data.MemberSourceItem
  alias CommaWeb.ProactiveCheck

  @now ~U[2026-11-10 02:40:15Z]

  test "mail age starts at provider receipt even when collection just found it" do
    for toolkit <- ~w(gmail outlook) do
      candidate =
        candidate(toolkit, %{"messageTimestamp" => "2026-11-10T10:26:02+08:00"})

      assert candidate["minutesAgo"] == 14
    end
  end

  test "mail with an unknown receipt time is not presented as newly received" do
    for facts <- [%{}, %{"messageTimestamp" => "invalid"}] do
      refute Map.has_key?(candidate("outlook", facts), "minutesAgo")
    end
  end

  test "a fresh mail keeps its age and other sources keep collection age" do
    assert candidate("gmail", %{"messageTimestamp" => "2026-11-10T02:39:15Z"})["minutesAgo"] == 1
    assert candidate("slack", %{})["minutesAgo"] == 0
  end

  test "pull request link evidence preserves draft status and Routine excludes settled terminal outcomes" do
    matter = %{
      "url" => "https://github.com/acme/cue/pull/4973",
      "excerpt" => "Please check",
      "members" => [
        %{"url" => "https://github.com/acme/cue/pull/4973", "excerpt" => "Please check"}
      ]
    }

    targets = CommaWeb.ProactiveEvidence.targets(matter)

    read =
      CommaWeb.ProactiveEvidence.read(targets, fn :github, _url ->
        {:ok,
         %{
           "html_url" => "https://github.com/acme/cue/pull/4973",
           "title" => "WIP feature",
           "state" => "open",
           "merged" => false,
           "draft" => true
         }}
      end)

    assert [%{"kind" => "github_pull_request", "draft" => true, "state" => "open"}] = read

    refute SalixStore.ProactiveKernel.routine_candidate?(%{"outcome" => "resolved"})
    refute SalixStore.ProactiveKernel.routine_candidate?(%{"outcome" => "dismissed"})
    refute SalixStore.ProactiveKernel.routine_candidate?(%{"outcome" => "duplicate"})
    refute SalixStore.ProactiveKernel.routine_candidate?(%{"role" => "reference"})

    refute SalixStore.ProactiveKernel.routine_candidate?(%{
             "outcome" => "quiet",
             "assessment" => %{"link" => "subscribed"}
           })

    assert SalixStore.ProactiveKernel.routine_candidate?(%{
             "outcome" => "quiet",
             "decision" => "briefing",
             "role" => "act"
           })
  end

  test "active worker strong anchors settle passive alerts into waiting briefing without suppressing mentions" do
    anchors = ["github:acme/cue#4973"]

    assert SalixStore.ProactiveKernel.absorb_by_worker?(
             false,
             false,
             false,
             ["github:acme/cue#4973"],
             anchors
           )

    refute SalixStore.ProactiveKernel.absorb_by_worker?(
             true,
             false,
             false,
             ["github:acme/cue#4973"],
             anchors
           )

    assert SalixStore.ProactiveKernel.effective_busy_until(:code, 123_456) == nil
    assert SalixStore.ProactiveKernel.effective_busy_until(:ordinary, 123_456) == 123_456
  end

  test "pregate_request carries duty, ongoing and active notebook lines alongside exclusions" do
    statements =
      [
        %{"text" => "关于你 · 名字与账号: kai, kai@example.com · 2026-11-24"},
        %{"text" => "关于你 · 职责: 维护 3D 勋章应用 Medalsmith · 2026-11-24"},
        %{"text" => "关于你 · 进行中: 测试 Comma 1.0.4 Usage 订阅与积分包 · 2026-11-24"}
      ] ++
        for(i <- 1..12, do: %{"text" => "关于你 · 常在: 频道 ##{i} · 2026-11-24"}) ++
        [
          %{"text" => "关于你 · 不归你: 财务报销审批 · 2026-11-24"},
          %{"text" => "关于你 · 偏好: 不要转发普通促销邮件 · 2026-11-24"},
          %{"text" => "关于你 · 兴趣: 关注 Steam 独立游戏史低折扣 · 2026-11-24"}
        ]

    notebook = """
    # Comma 笔记本

    ## 进行中与等待
    - Comma 1.0.4 Usage 页内购测试（测积分到账需 cue.surf 或 comma.surf 邮箱工作区）

    ## Comma 对你的了解
    - 关于你 · 职责: 维护 3D 勋章应用 Medalsmith · 2026-11-24
    """

    req =
      ProactiveCheck.pregate_request(
        %{"title" => "TestFlight: Comma 1.0.4 (23)", "excerpt" => "Ready to test"},
        statements,
        notebook
      )

    portrait = req["state"]["portrait"]
    refute Enum.any?(portrait, &String.contains?(&1, "名字与账号"))
    assert Enum.any?(portrait, &String.contains?(&1, "Medalsmith"))
    assert Enum.any?(portrait, &String.contains?(&1, "Comma 1.0.4"))
    assert Enum.any?(portrait, &String.contains?(&1, "财务报销审批"))
    assert Enum.any?(portrait, &String.contains?(&1, "不要转发普通促销邮件"))
    assert Enum.any?(portrait, &String.contains?(&1, "Steam 独立游戏史低折扣"))

    assert req["state"]["notebook"] == [
             "Comma 1.0.4 Usage 页内购测试（测积分到账需 cue.surf 或 comma.surf 邮箱工作区）"
           ]
  end

  test "signal decisions route only when grounded to the owner and never from the junk folder" do
    matter = %{
      "id" => "i1",
      "url" => "https://outlook.office.com/mail/inbox/id/dex",
      "relationship" => "your_recent_inbox_and_upcoming_events"
    }

    grounded_answer = %{
      "id" => "i1",
      "repeats" => false,
      "code" => false,
      "role" => "reference",
      "link" => "portrait",
      "cost" => "",
      "due" => nil,
      "reversible" => true,
      "decision" => "signal",
      "reason" => "DEX Weekly #373 featured Medalsmith, which the member maintains.",
      "message" => "Medalsmith 被 DEX 周刊 #373 收录推荐了。"
    }

    assert {:ok, {:handoff, item, "Medalsmith 被 DEX 周刊 #373 收录推荐了。"}} =
             ProactiveCheck.decide(grounded_answer, matter, @now, [])

    assert item["decision"] == "signal"
    assert item["assessment"]["signal"] == true
    refute ProactiveCheck.reserve_eligible?(item, @now)

    # Unowned subscribed/none or omitted/invalid links cannot route as signal without matchedPortraitTerms.
    for unowned_link <- ["subscribed", "none", nil, "bogus"] do
      assert {:ok, {:settle, "briefing", _}} =
               ProactiveCheck.decide(
                 Map.put(grounded_answer, "link", unowned_link),
                 matter,
                 @now,
                 []
               )
    end

    # Junk-folder items can never route as non-obligation signals.
    junk_matter = Map.put(matter, "relationship", "in_your_junk_folder")

    assert {:ok, {:settle, "briefing", _}} =
             ProactiveCheck.decide(grounded_answer, junk_matter, @now, [])

    # Even if a model sets code=true on a signal, decide/5 forces code=false so it stays in the signal pool.
    assert {:ok, {:handoff, signal_item, _}} =
             ProactiveCheck.decide(Map.put(grounded_answer, "code", true), matter, @now, [])

    assert signal_item["assessment"]["code"] == false

    # Gmail Promotions rescues (mentions_your_work) are strictly signal-only and never spend interrupt/reserve.
    promo_matter = %{
      "id" => "i_promo",
      "toolkit" => "gmail",
      "relationship" => "mentions_your_work",
      "url" => "https://mail.google.com/mail/u/0/#inbox/steam-flash",
      "matchedPortraitTerms" => ["Steam"]
    }

    promo_interrupt = %{
      "id" => "i_promo",
      "repeats" => false,
      "code" => true,
      "role" => "act",
      "link" => "portrait",
      "cost" => "Steam 80% off deal ends in 6 hours",
      "due" => "2026-10-12T12:00:00Z",
      "reversible" => false,
      "decision" => "interrupt",
      "reason" => "Sale ends soon.",
      "message" => "Steam sale ends in 6 hours."
    }

    assert {:ok, {:settle, "briefing", settled_assessment}} =
             ProactiveCheck.decide(promo_interrupt, promo_matter, @now, [])

    assert settled_assessment["code"] == false

    refute ProactiveCheck.reserve_eligible?(
             Map.put(promo_matter, "assessment", %{"reversible" => false, "role" => "act"}),
             @now
           )

    # Personal-interest someday or promotions-rescue signals stay plain text (no draft_task card).
    refute CommaWeb.ProactiveExecution.actionable?(%{
             "decision" => "signal",
             "role" => "someday",
             "relationship" => "your_recent_inbox_and_upcoming_events",
             "assessment" => %{"cost" => "Sale ends tonight"}
           })

    refute CommaWeb.ProactiveExecution.actionable?(%{
             "decision" => "signal",
             "role" => "reference",
             "relationship" => "mentions_your_work",
             "assessment" => %{"cost" => "Sale ends tonight"}
           })

    refute CommaWeb.ProactiveExecution.actionable?(%{
             "decision" => "signal",
             "role" => "act",
             "relationship" => "mentions_your_work",
             "assessment" => %{"cost" => ""}
           })
  end

  test "pregate_request never lets abundant interest lines crowd out exclusions, preferences, or work duties" do
    statements =
      for(i <- 1..12, do: %{"text" => "关于你 · 兴趣: 兴趣项 #{i} · 2026-11-26"}) ++
        [
          %{"text" => "关于你 · 职责: 维护核心支付服务 · 2026-11-26"},
          %{"text" => "关于你 · 进行中: 上线 1.0.5 计费修复 · 2026-11-26"},
          %{"text" => "关于你 · 不归你: 财务报销审批 · 2026-11-26"},
          %{"text" => "关于你 · 偏好: 生产事故必须立刻提醒 · 2026-11-26"}
        ]

    req =
      ProactiveCheck.pregate_request(
        %{"title" => "核心支付服务异常", "excerpt" => "Payment webhook failed"},
        statements,
        nil
      )

    portrait = req["state"]["portrait"]
    assert length(portrait) == 12
    assert Enum.any?(portrait, &String.contains?(&1, "财务报销审批"))
    assert Enum.any?(portrait, &String.contains?(&1, "生产事故必须立刻提醒"))
    assert Enum.any?(portrait, &String.contains?(&1, "维护核心支付服务"))
    assert Enum.any?(portrait, &String.contains?(&1, "上线 1.0.5 计费修复"))
    assert Enum.count(portrait, &String.contains?(&1, "兴趣项")) >= 3
  end

  test "RecommendationRenderer.content classifies account-level provider errors separately from item-level permanent errors" do
    alias CommaWeb.RecommendationRenderer

    # Map-form billing_unavailable (quota_exhausted with funding.reset_at, subscription sign-in, model_unavailable)
    reset_at = div(SystemsClock.system_time(:millisecond), 1000) + 1_800

    assert {:error, {:provider_unavailable, "quota_exhausted", ms}} =
             RecommendationRenderer.content(
               {:error,
                %{
                  "error_class" => "billing_unavailable",
                  "reason" => "quota_exhausted",
                  "funding" => %{"reset_at" => reset_at}
                }}
             )

    assert is_integer(ms) and ms > 1_700_000 and ms <= 1_800_000

    assert {:error, {:provider_unavailable, "subscription_authentication_required", nil}} =
             RecommendationRenderer.content(
               {:error,
                %{
                  "error_class" => "billing_unavailable",
                  "reason" => "subscription_authentication_required"
                }}
             )

    # HTTP 401/402/403/404 credential/model errors -> account-level provider_unavailable
    for status <- [401, 402, 403, 404] do
      expected = "http_#{status}"

      assert {:error, {:provider_unavailable, ^expected, nil}} =
               RecommendationRenderer.content(
                 {:error, %{"category" => "permanent_provider_error", "status" => status}}
               )
    end

    # HTTP 429 with long retry_after_ms (>= 60s) preserves retry_after_ms; transient 429 without long backoff stays retryable
    assert {:error, {:provider_unavailable, "rate_limited", 950_400_000}} =
             RecommendationRenderer.content(
               {:error,
                %{
                  "category" => "retryable_provider_error",
                  "status" => 429,
                  "retry_after_ms" => 950_400_000
                }}
             )

    assert {:error, {:model_error, "retryable_provider_error"}} =
             RecommendationRenderer.content(
               {:error, %{"category" => "retryable_provider_error", "status" => 429}}
             )

    assert {:error, {:model_error, "retryable_provider_error"}} =
             RecommendationRenderer.content(
               {:error,
                %{
                  "category" => "retryable_provider_error",
                  "status" => 429,
                  "retry_after_ms" => 30_000
                }}
             )

    # Empty subscription pool 503 -> provider_unavailable; short cooling (<60s) stays retryable; long cooling (>=60s) snoozes
    assert {:error, {:provider_unavailable, "subscription_accounts_unavailable", nil}} =
             RecommendationRenderer.content(
               {:error, %{"status" => 503, "body" => "subscription accounts unavailable"}}
             )

    assert {:error, {:model_error, "retryable_provider_error"}} =
             RecommendationRenderer.content(
               {:error,
                %{
                  "category" => "retryable_provider_error",
                  "status" => 503,
                  "body" => "subscription accounts unavailable",
                  "retry_after_ms" => 30_000
                }}
             )

    assert {:error, {:provider_unavailable, "subscription_accounts_cooling", 120_000}} =
             RecommendationRenderer.content(
               {:error,
                %{
                  "status" => 503,
                  "body" => "subscription accounts unavailable",
                  "retry_after_ms" => 120_000
                }}
             )

    # Generic item-level permanent_provider_error (no account HTTP status / error_class) stays model_error
    assert {:error, {:model_error, "permanent_provider_error"}} =
             RecommendationRenderer.content(
               {:error, %{"category" => "permanent_provider_error", "retryable" => false}}
             )

    # Snooze clamping: 15m min, 1h default, 6h max
    assert ProactiveCheck.provider_snooze_seconds(30_000) == 15 * 60
    assert ProactiveCheck.provider_snooze_seconds(2_700_000) == 45 * 60
    assert ProactiveCheck.provider_snooze_seconds(950_400_000) == 6 * 60 * 60
    assert ProactiveCheck.provider_snooze_seconds(nil) == 60 * 60

    # Timeout isolation requires repeated failures (>= 2); item-level permanent_provider_error isolates immediately.
    first_timeout = ProactiveCheck.next_failure_attention(nil, :model_timed_out, true, 1_000)

    assert first_timeout == %{
             "outcome" => "retry",
             "attempts" => 0,
             "failures" => 1,
             "isolated" => false,
             "at" => 1_000
           }

    second_timeout =
      ProactiveCheck.next_failure_attention(first_timeout, :model_timed_out, true, 2_000)

    assert second_timeout == %{
             "outcome" => "retry",
             "attempts" => 0,
             "failures" => 2,
             "isolated" => true,
             "at" => 2_000
           }

    perm =
      ProactiveCheck.next_failure_attention(
        nil,
        {:model_error, "permanent_provider_error"},
        true,
        3_000
      )

    assert perm == %{
             "outcome" => "retry",
             "attempts" => 0,
             "failures" => 1,
             "isolated" => true,
             "at" => 3_000
           }
  end

  test "merge_full_mail accepts attachment-only emails and rejects completely empty mail reads" do
    item = %{
      "toolkit" => "gmail",
      "messageId" => "m-att-1",
      "context" => %{
        "scope" => "snippet",
        "text" => "Original snippet",
        "attachments" => "unread"
      }
    }

    # Empty body with readable attachment text succeeds and marks attachments read.
    assert {:ok, updated} =
             ProactiveCheck.merge_full_mail(item, %{
               "messages" => [%{"message_id" => "m-att-1", "body" => "   "}],
               "attachments_read" => true,
               "attachments" => [%{"name" => "invoice.txt", "text" => "Amount due: $420"}]
             })

    assert updated["context"]["scope"] == "full_message"
    assert updated["context"]["truncated"] == false
    assert updated["context"]["attachments"] == "read"
    assert updated["context"]["text"] =~ "attachment invoice.txt:"
    assert updated["context"]["text"] =~ "Amount due: $420"

    # Empty body with unreadable binary attachment still preserves marker without failing.
    assert {:ok, binary_updated} =
             ProactiveCheck.merge_full_mail(item, %{
               "messages" => [%{"message_id" => "m-att-1", "body" => ""}],
               "attachments_read" => false,
               "attachments" => [
                 %{"name" => "scan.pdf", "content_type" => "application/pdf", "size" => 8192}
               ]
             })

    assert binary_updated["context"]["attachments"] == "unread"

    assert binary_updated["context"]["text"] =~
             "attachment scan.pdf (application/pdf, 8192 bytes): not read"

    # Completely empty body and no attachments returns :error so pooled excerpt stays intact.
    assert :error =
             ProactiveCheck.merge_full_mail(item, %{
               "messages" => [%{"message_id" => "m-att-1", "body" => "  "}],
               "attachments_read" => true,
               "attachments" => []
             })
  end

  test "route_screened treats provider_unavailable as batch-fatal and all-saturated as retryable without poisoning items" do
    matter_a = %{"id" => "i1", "meeting_prep" => true}
    matter_b = %{"id" => "i2", "meeting_prep" => true}

    # Account-level provider_unavailable aborts batch cleanly before settling anything.
    assert {:error, {:provider_unavailable, "http_401", nil}} =
             ProactiveCheck.route_screened(
               %{},
               %{},
               "home",
               %{id: "p1", user_id: "u1"},
               %{},
               [
                 {matter_a, {:error, :batch_aborted}},
                 {matter_b, {:error, {:provider_unavailable, "http_401", nil}}}
               ],
               1_000_000
             )

    # All-saturated batch returns {:error, :dependency_saturated} so Oban backs off.
    assert {:error, :dependency_saturated} =
             ProactiveCheck.route_screened(
               %{},
               %{},
               "home",
               %{id: "p1", user_id: "u1"},
               %{},
               [
                 {matter_a, {:error, :dependency_saturated}},
                 {matter_b, {:error, :dependency_saturated}}
               ],
               1_000_000
             )

    # All-403 batch (zero peers succeeded) aborts as account-level provider_unavailable.
    assert {:error, {:provider_unavailable, "http_403", nil}} =
             ProactiveCheck.route_screened(
               %{},
               %{},
               "home",
               %{id: "p1", user_id: "u1"},
               %{},
               [
                 {matter_a, {:error, {:provider_unavailable, "http_403", nil}}},
                 {matter_b, {:error, {:provider_unavailable, "http_403", nil}}}
               ],
               1_000_000
             )

    # Local non-LLM settlements (worker absorption / pre-gate quiet) do NOT count as provider success:
    # an account-wide 403 on the sole LLM call still aborts and snoozes without poisoning the item.
    assert {:error, {:provider_unavailable, "http_403", nil}} =
             ProactiveCheck.route_screened(
               %{},
               %{},
               "home",
               %{id: "p1", user_id: "u1"},
               %{},
               [
                 {matter_a,
                  {:ok,
                   {:settle_local, "briefing", %{"role" => "reference", "reason" => "Pre-gated"}}}},
                 {matter_b, {:error, {:provider_unavailable, "http_403", nil}}}
               ],
               1_000_000
             )

    # Mixed batch (real peer LLM call succeeded + 1 item hit 403 WAF/moderation) does NOT abort the batch.
    assert {:ok, :deferred} =
             ProactiveCheck.route_screened(
               %{},
               %{},
               "home",
               %{id: "p1", user_id: "u1"},
               %{},
               [
                 {matter_a, {:error, {:provider_unavailable, "http_403", nil}}},
                 {matter_b,
                  {:ok, {:settle, "briefing", %{"role" => "reference", "reason" => "ok"}}}}
               ],
               1_000_000
             )

    # Order-independent deterministic recovery precedence across all concurrent error permutations:
    # billing denial (cancel) > account provider_unavailable (snooze) > retryable provider error (retry).
    retryable_429 = {:error, {:model_error, "retryable_provider_error"}}
    auth_401 = {:error, {:provider_unavailable, "http_401", nil}}
    forbidden_403 = {:error, {:provider_unavailable, "http_403", nil}}
    no_credits = {:error, :insufficient_credits}
    short_snooze = {:error, {:provider_unavailable, "rate_limited", 1_200_000}}
    long_snooze = {:error, {:provider_unavailable, "rate_limited", 7_200_000}}

    for pair <- [
          {retryable_429, auth_401, auth_401},
          {retryable_429, no_credits, no_credits},
          {auth_401, no_credits, no_credits},
          {retryable_429, forbidden_403, forbidden_403},
          {short_snooze, long_snooze, long_snooze}
        ] do
      {err1, err2, expected} = pair

      assert expected ==
               ProactiveCheck.route_screened(
                 %{},
                 %{},
                 "home",
                 %{id: "p1", user_id: "u1"},
                 %{},
                 [{matter_a, err1}, {matter_b, err2}],
                 1_000_000
               )

      assert expected ==
               ProactiveCheck.route_screened(
                 %{},
                 %{},
                 "home",
                 %{id: "p1", user_id: "u1"},
                 %{},
                 [{matter_a, err2}, {matter_b, err1}],
                 1_000_000
               )
    end

    # Partial :invalid_briefing_content and partial :dependency_saturated do NOT abort the batch.
    assert {:ok, :deferred} =
             ProactiveCheck.route_screened(
               %{},
               %{},
               "home",
               %{id: "p1", user_id: "u1"},
               %{},
               [
                 {matter_a, {:error, :invalid_briefing_content}},
                 {matter_b, {:error, :dependency_saturated}}
               ],
               1_000_000
             )
  end

  defp candidate(toolkit, facts) do
    item = %MemberSourceItem{
      id: "mail",
      toolkit: toolkit,
      facts: facts,
      first_seen_at: @now
    }

    %{"candidates" => [candidate]} =
      ProactiveCheck.attention_input([ProactiveCheck.view(item)], [], [], @now)

    candidate
  end
end
