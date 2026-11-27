defmodule Comma.MemberSourceItemsTest do
  use Comma.DataCase, async: false

  import Ecto.Query

  alias Comma.Data.{MemberSourceItem, RecommendationProfile, Workspace, WorkspaceMembership}
  alias Comma.{MemberSourceConsents, MemberSourceItems, OpenThreads, Repo}
  alias SalixStore.Ids

  test "a first recording is history, later arrivals and changes are pending once" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-09-24 08:00:00.000000Z]

    assert {:ok, %{new: 0, changed: 0}} =
             record(profile, %{"ca-mail" => [mail("a", "Weekly digest")]}, ["ca-mail"], now)

    refute MemberSourceItems.pending?(profile.id)

    assert {:ok, %{new: 1, changed: 1}} =
             record(
               profile,
               %{
                 "ca-mail" => [mail("a", "Weekly digest, now urgent"), mail("b", "Approve today")]
               },
               ["ca-mail"],
               DateTime.add(now, 900)
             )

    pending = Enum.sort_by(MemberSourceItems.pending(profile.id, 24), & &1.title)
    assert Enum.map(pending, & &1.title) == ["Mail a", "Mail b"]
    assert Enum.all?(pending, &(not &1.baseline))

    # An outcome settles only the version it judged.
    [first, second] = pending
    stale = %{second | fingerprint: "an older version"}
    :ok = MemberSourceItems.settle([first, stale], %{"outcome" => "quiet"})
    assert [%{id: id}] = MemberSourceItems.pending(profile.id, 24)
    assert id == second.id

    # An unusable judgment keeps the item waiting for a bounded number of tries.
    :ok = MemberSourceItems.settle([second], %{"outcome" => "retry", "attempts" => 1})
    assert [%{id: ^id}] = MemberSourceItems.pending(profile.id, 24)

    :ok =
      MemberSourceItems.settle([second], %{
        "outcome" => "retry",
        "attempts" => MemberSourceItems.judge_attempts()
      })

    assert MemberSourceItems.pending(profile.id, 24) == []
  end

  test "a judged item waits again from its next_at, a bounded number of times, and from its due_at" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-09-24 08:00:00.000000Z]
    assert {:ok, _} = record(profile, %{"ca-mail" => []}, ["ca-mail"], now)

    assert {:ok, %{new: 1}} =
             record(profile, %{"ca-mail" => [mail("a", "Review")]}, ["ca-mail"], now)

    [item] = MemberSourceItems.pending(profile.id, 24)
    clock = SystemsClock.system_time(:millisecond)
    cap = MemberSourceItems.rechecks()

    waits? = fn attention ->
      :ok = MemberSourceItems.settle([item], attention)
      MemberSourceItems.pending?(profile.id)
    end

    # Not before its time.
    refute waits?.(%{"outcome" => "deferred", "next_at" => clock + 60_000, "rechecks" => 1})
    assert waits?.(%{"outcome" => "deferred", "next_at" => clock, "rechecks" => 1})

    # After the budget rechecks it stays in the owner's next actions.
    refute waits?.(%{"outcome" => "deferred", "next_at" => clock, "rechecks" => cap})

    # Its own due time still wakes it, also when the judgment kept it quiet.
    assert waits?.(%{
             "outcome" => "deferred",
             "next_at" => clock,
             "rechecks" => cap,
             "due_at" => clock
           })

    assert waits?.(%{"outcome" => "quiet", "due_at" => clock})
    refute waits?.(%{"outcome" => "quiet", "due_at" => clock + 60_000})
  end

  test "a full 1,200-byte record context keeps its scope, attachments and stable fingerprint" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-11-25 04:18:00.000000Z]

    full_text = "body: " <> String.duplicate("a", 1_194)
    assert byte_size(full_text) == 1_200

    item =
      mail("invite", "Apple Developer invite")
      |> Map.put("context", %{
        "scope" => "record_excerpt",
        "text" => full_text,
        "truncated" => true,
        "attachments" => "unread"
      })

    assert {:ok, %{new: 0, changed: 0}} =
             record(profile, %{"ca-mail" => [item]}, ["ca-mail"], now)

    refute MemberSourceItems.pending?(profile.id)

    [stored] = Repo.all(items(profile.id))
    assert stored.baseline == true
    assert stored.context["scope"] == "record_excerpt"
    assert stored.context["attachments"] == "unread"
    assert stored.context["text"] == full_text

    # Re-recording the same item alongside an unrelated new arrival keeps the
    # baseline item unchanged and leaves only the new arrival pending.
    later = DateTime.add(now, 900)

    assert {:ok, %{new: 1, changed: 0}} =
             record(
               profile,
               %{"ca-mail" => [item, mail("newer", "New mail")]},
               ["ca-mail"],
               later
             )

    assert [%{item_key: "newer"}] = MemberSourceItems.pending(profile.id, 24)
    assert Repo.get!(MemberSourceItem, stored.id).baseline == true
  end

  test "pre-v2 fingerprints rebase silently once without clearing baseline or attention" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-11-25 04:18:00.000000Z]

    base = mail("base", "Old baseline mail")
    quiet = mail("quiet", "Settled quiet mail")

    assert {:ok, %{new: 0, changed: 0}} =
             record(profile, %{"ca-mail" => [base]}, ["ca-mail"], now)

    assert {:ok, %{new: 1, changed: 0}} =
             record(profile, %{"ca-mail" => [base, quiet]}, ["ca-mail"], DateTime.add(now, 60))

    [quiet_row] = MemberSourceItems.pending(profile.id, 24)
    :ok = MemberSourceItems.settle([quiet_row], %{"outcome" => "quiet"})
    [base_row] = Repo.all(from(i in items(profile.id), where: i.item_key == "base"))

    # Simulate legacy unprefixed fingerprints from before the per-item context fix.
    legacy_fp = String.duplicate("a", 64)
    Repo.update_all(items(profile.id), set: [fingerprint: legacy_fp])

    # Re-collecting with expanded context rebases silently: changed == 0,
    # baseline and attention remain intact, and fingerprints upgrade to `v2:` <= 64 chars.
    expanded_base =
      Map.put(base, "context", %{
        "scope" => "record_excerpt",
        "text" => "body: expanded base",
        "truncated" => false
      })

    expanded_quiet =
      Map.put(quiet, "context", %{
        "scope" => "record_excerpt",
        "text" => "body: expanded quiet",
        "truncated" => false
      })

    later = DateTime.add(now, 900)

    assert {:ok, %{new: 0, changed: 0}} =
             record(profile, %{"ca-mail" => [expanded_base, expanded_quiet]}, ["ca-mail"], later)

    refute MemberSourceItems.pending?(profile.id)

    rebased_base = Repo.get!(MemberSourceItem, base_row.id)
    rebased_quiet = Repo.get!(MemberSourceItem, quiet_row.id)

    assert String.starts_with?(rebased_base.fingerprint, "v2:")
    assert byte_size(rebased_base.fingerprint) <= 64
    assert rebased_base.baseline == true
    assert rebased_base.changed_at == base_row.changed_at
    assert rebased_base.context["text"] == "body: expanded base"

    assert String.starts_with?(rebased_quiet.fingerprint, "v2:")
    assert rebased_quiet.attention == %{"outcome" => "quiet"}
    assert rebased_quiet.changed_at == quiet_row.changed_at
    assert rebased_quiet.context["text"] == "body: expanded quiet"

    # Once on `v2:`, a genuine edit triggers `changed: 1` as usual.
    edited_quiet =
      Map.put(expanded_quiet, "context", %{
        "scope" => "record_excerpt",
        "text" => "body: urgent follow-up",
        "truncated" => false
      })

    assert {:ok, %{new: 0, changed: 1}} =
             record(
               profile,
               %{"ca-mail" => [expanded_base, edited_quiet]},
               ["ca-mail"],
               DateTime.add(later, 900)
             )

    assert [%{item_key: "quiet"}] = MemberSourceItems.pending(profile.id, 24)
  end

  test "a new quote keeps the item's version and outcome" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-09-24 08:00:00.000000Z]
    assert {:ok, _} = record(profile, %{"ca-mail" => []}, ["ca-mail"], now)

    item = Map.put(mail("a", "Approve today"), "quote", %{"title" => "Mail a"})
    at = DateTime.add(now, 900)
    assert {:ok, %{new: 1}} = record(profile, %{"ca-mail" => [item]}, ["ca-mail"], at)

    assert [%{quote: %{"title" => "Mail a"}} = arrived] =
             MemberSourceItems.pending(profile.id, 24)

    :ok = MemberSourceItems.settle([arrived], %{"outcome" => "quiet"})

    # Observations and handled marks are keyed by the version, so display
    # text must not change it or send the item to consumers again.
    reworded = Map.put(item, "quote", %{"title" => "Mail a", "lines" => ["Approve today"]})
    at = DateTime.add(now, 1_800)

    assert {:ok, %{new: 0, changed: 0}} =
             record(profile, %{"ca-mail" => [reworded]}, ["ca-mail"], at)

    refute MemberSourceItems.pending?(profile.id)
    stored = Repo.get!(MemberSourceItem, arrived.id)
    assert stored.quote == %{"title" => "Mail a", "lines" => ["Approve today"]}

    assert {stored.fingerprint, stored.changed_at, stored.attention} ==
             {arrived.fingerprint, arrived.changed_at, %{"outcome" => "quiet"}}
  end

  test "an item waits only while its source's latest successful collection returns it" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-09-24 08:00:00.000000Z]
    at = &DateTime.add(now, &1 * 900)
    inbox = &record(profile, %{"ca-mail" => &1}, ["ca-mail"], &2)

    {:ok, _} = inbox.([mail("a", "Digest")], now)
    {:ok, _} = inbox.([mail("a", "Digest"), mail("b", "Approve today")], at.(1))
    assert [%{title: "Mail b"} = arrived] = MemberSourceItems.pending(profile.id, 24)

    # The member answered: the next collection no longer returns the mail.
    {:ok, _} = inbox.([mail("a", "Digest")], at.(2))
    refute MemberSourceItems.pending?(profile.id)

    assert {:error, :withdrawn} =
             MemberSourceItems.while_pending(arrived, fn -> flunk("told") end)

    # Returned again unchanged, it still waits for its first outcome.
    {:ok, _} = inbox.([mail("a", "Digest"), mail("b", "Approve today")], at.(3))
    assert [%{id: id}] = MemberSourceItems.pending(profile.id, 24)
    assert id == arrived.id

    # A failed read cannot confirm it, so it waits for a successful read.
    {:ok, _} =
      MemberSourceItems.record(
        profile.id,
        %{failed: %{"ca-mail" => %{"appId" => "gmail", "class" => "read", "message" => "503"}}},
        ["ca-mail"],
        at.(4)
      )

    refute MemberSourceItems.pending?(profile.id)
    {:ok, _} = inbox.([mail("a", "Digest"), mail("b", "Approve today")], at.(5))
    assert {:ok, :sent} = MemberSourceItems.while_pending(arrived, fn -> {:ok, :sent} end)

    # A changed version needs a new judgment; the judged version is withdrawn.
    {:ok, _} = inbox.([mail("a", "Digest"), mail("b", "Approve today by noon")], at.(6))

    assert {:error, :withdrawn} =
             MemberSourceItems.while_pending(arrived, fn -> flunk("told") end)

    assert [%{id: ^id}] = MemberSourceItems.pending(profile.id, 24)
  end

  test "items leave the pool when the source is removed, revoked, rebound or expired" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}
    now = SystemsClock.utc_now()
    {:ok, :ok} = MemberSourceConsents.record(user, %{}, workspace.id, "gmail", "ca-mail")
    {:ok, :ok} = MemberSourceConsents.record(user, %{}, workspace.id, "slack", "ca-slack")

    collect = fn sources ->
      {:ok, _} =
        record(profile, Map.new(sources, &{&1, [mail(&1, "Item from " <> &1)]}), sources, now)
    end

    collect.(~w(ca-mail ca-slack ca-calendar))

    # A source the profile no longer enables loses its items on the next recording.
    collect.(~w(ca-mail ca-slack))
    assert sources(profile.id) == ~w(ca-mail ca-slack)

    # Another consented account of the toolkit is its own source; a
    # reconnection that replaces the account takes the old account's items.
    {:ok, :ok} = MemberSourceConsents.record(user, %{}, workspace.id, "gmail", "ca-mail-3")
    assert sources(profile.id) == ~w(ca-mail ca-slack)

    {:ok, :ok} =
      MemberSourceConsents.replace(user, %{}, workspace.id, "gmail", "ca-mail", "ca-mail-2")

    assert sources(profile.id) == ~w(ca-slack)

    :ok = MemberSourceConsents.forget_connection(workspace.id, "ca-slack")
    assert sources(profile.id) == []
    # Their states go too, so a reconnected account records a new baseline.
    assert MemberSourceItems.current(profile.id) == []

    collect.(~w(ca-mail-2))
    old = DateTime.add(now, -(MemberSourceItems.retention_days() * 86_400 + 60), :second)
    Repo.update_all(items(profile.id), set: [last_seen_at: old])
    assert MemberSourceItems.expire(now) == 1
    assert sources(profile.id) == []
  end

  test "an open thread keeps the owner's correction and leaves with its source" do
    {profile, workspace} = profile_fixture!()
    now = ~U[2026-11-01 08:00:00.000000Z]
    {:ok, _} = record(profile, %{"ca-slack" => []}, ["ca-slack"], now)

    thread = fn key, status, summary ->
      %{
        "thread_key" => key,
        "kind" => "promised",
        "status" => status,
        "summary" => summary,
        "url" => "https://team.slack.com/archives/C1/p1",
        "evidence_at" => now
      }
    end

    put = fn entries, opts ->
      OpenThreads.record(
        profile.id,
        "ca-slack",
        "slack",
        entries,
        Keyword.merge([now: now], opts)
      )
    end

    list = fn -> OpenThreads.list(profile.id, now) end

    # A thread first seen resolved is not recorded.
    assert {:ok, %{open: 2}} =
             put.(
               [
                 thread.("slack:C1/1.0", "open", "Send Lena the numbers"),
                 thread.("slack:C1/2.0", "resolved", "Done"),
                 thread.("slack:C1/3.0", "open", "Reply to Milo")
               ],
               []
             )

    [%{id: lena}] = Enum.filter(list.(), &(&1.thread_key == "slack:C1/1.0"))
    [%{id: milo}] = Enum.filter(list.(), &(&1.thread_key == "slack:C1/3.0"))

    # A later message in the same thread updates it.
    assert {:ok, %{open: 2}} =
             put.([thread.("slack:C1/1.0", "open", "Send Lena the Q3 numbers")], [])

    assert %{summary: "Send Lena the Q3 numbers"} = Enum.find(list.(), &(&1.id == lena))

    # Only the owner's profile corrects a thread, and a correction stands: the
    # extraction neither reopens nor rewrites it.
    {other, _} = profile_fixture!()
    assert {:error, :open_thread_not_found} = OpenThreads.set_status(other.id, lena, "dismissed")
    assert {:ok, _} = OpenThreads.set_status(profile.id, lena, "dismissed")
    assert {:ok, _} = OpenThreads.set_status(profile.id, milo, "resolved")

    assert {:ok, %{open: 0}} =
             put.(
               [
                 thread.("slack:C1/1.0", "open", "Again"),
                 thread.("slack:C1/3.0", "open", "Again")
               ],
               []
             )

    assert [%{status: "dismissed", summary: "Send Lena the Q3 numbers"}] =
             Enum.filter(list.(), &(&1.id == lena))

    assert [%{status: "resolved", summary: "Reply to Milo"}] =
             Enum.filter(list.(), &(&1.id == milo))

    # The profile's bound drops old uncorrected threads, never a correction.
    many = for n <- 1..45, do: thread.("slack:C2/#{n}.0", "open", "Item #{n}")
    assert {:ok, %{open: 40}} = put.(many, [])
    assert Enum.any?(list.(), &(&1.id == lena))

    # Opening it again returns it to the extraction.
    assert {:ok, _} = OpenThreads.set_status(profile.id, milo, "open")

    replied =
      Map.put(
        thread.("slack:C1/3.0", "resolved", "Replied to Milo"),
        "evidence_at",
        DateTime.add(now, 60)
      )

    assert {:ok, _} = put.([replied], [])

    assert [%{status: "resolved", summary: "Replied to Milo"}] =
             Enum.filter(list.(), &(&1.id == milo))

    # Stale or equal-timestamp evidence cannot resurrect an uncorrected resolved thread.
    stale_open =
      Map.put(
        thread.("slack:C1/3.0", "open", "Stale open replay"),
        "evidence_at",
        DateTime.add(now, 30)
      )

    assert {:ok, _} = put.([stale_open], [])

    assert [%{status: "resolved", summary: "Replied to Milo"}] =
             Enum.filter(list.(), &(&1.id == milo))

    # A source the member no longer collects, or a read the current account
    # check rejects, records nothing.
    assert {:error, :member_source_changed} =
             OpenThreads.record(
               profile.id,
               "ca-other",
               "slack",
               [thread.("slack:C3/1.0", "open", "x")],
               now: now
             )

    assert {:error, :member_source_changed} =
             put.([thread.("slack:C3/1.0", "open", "x")], current?: fn _profile -> false end)

    refute Enum.any?(list.(), &(&1.thread_key == "slack:C3/1.0"))

    # Past retention a thread is no longer listed, and the hourly sweep deletes it.
    later = DateTime.add(now, 46 * 86_400, :second)
    assert OpenThreads.list(profile.id, later) == []
    count = length(list.())
    assert OpenThreads.expire_all(DateTime.add(later, 60)) == count
    assert list.() == []

    # Tracking resolves an open thread it found done, never a correction, and
    # the cursor keeps the newest message the extraction judged.
    {:ok, _} = put.([thread.("slack:C1/4.0", "open", "Ask Ana")], read_until: "100.000001")
    [%{id: ana}] = Enum.filter(list.(), &(&1.thread_key == "slack:C1/4.0"))
    assert OpenThreads.cursor(profile.id, "ca-slack") == "100.000001"
    assert [%{id: ^ana, checked_ts: nil}] = OpenThreads.tracked(profile.id, "ca-slack")
    {:ok, _} = OpenThreads.set_status(profile.id, ana, "dismissed")
    {:ok, _} = put.([], closed: [ana], checked: %{ana => "101.000001"})
    assert [%{status: "dismissed"}] = Enum.filter(list.(), &(&1.id == ana))
    {:ok, _} = OpenThreads.set_status(profile.id, ana, "open")
    {:ok, _} = put.([], closed: [ana], checked: %{ana => "102.000001"}, read_until: "103.000001")

    assert [%{status: "resolved", checked_ts: "102.000001"}] =
             Enum.filter(list.(), &(&1.id == ana))

    assert OpenThreads.cursor(profile.id, "ca-slack") == "103.000001"

    # Revoking the account deletes its threads and its cursor with its items.
    {:ok, _} = put.([thread.("slack:C1/5.0", "open", "Ask Bo")], [])
    :ok = MemberSourceConsents.forget_connection(workspace.id, "ca-slack")
    assert list.() == []
    assert OpenThreads.cursor(profile.id, "ca-slack") == nil
  end

  test "tracking takes every open thread in turn, those read longest ago first" do
    {profile, _workspace} = profile_fixture!()
    now = SystemsClock.utc_now()
    {:ok, _} = record(profile, %{"ca-slack" => []}, ["ca-slack"], now)

    entries =
      for n <- 1..12,
          do: %{
            "thread_key" => "slack:C1/#{n}.0",
            "kind" => "asked",
            "status" => "open",
            "summary" => "Question #{n}",
            "url" => "https://team.slack.com/archives/C1/p#{n}",
            "evidence_at" => now
          }

    {:ok, %{open: 12}} = OpenThreads.record(profile.id, "ca-slack", "slack", entries, now: now)
    first = OpenThreads.tracked(profile.id, "ca-slack")
    assert length(first) == 10

    # A read without news still counts as a turn.
    {:ok, _} =
      OpenThreads.record(profile.id, "ca-slack", "slack", [],
        now: now,
        tracked: Enum.map(first, & &1.id)
      )

    second = OpenThreads.tracked(profile.id, "ca-slack")
    rest = Enum.map(second, & &1.id) -- Enum.map(first, & &1.id)
    assert length(rest) == 2
    assert Enum.take(Enum.map(second, & &1.id), 2) == rest
  end

  test "a retryable item keeps a bounded recovery window across rolling source pages and survives the 400-item pool sweep" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-11-20 02:00:00.000000Z]

    gh_item = fn key, text ->
      %{
        "item_key" => key,
        "toolkit" => "github",
        "app" => "GitHub",
        "url" => "https://github.com/AFK-surf/still.fail/actions/runs/" <> key,
        "title" => "CI run " <> key,
        "excerpt" => text,
        "prompt_context" => text,
        "relationship" => "failed_in_your_repo",
        "facts" => %{},
        "provider_ids" => %{},
        "fingerprint" => :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
      }
    end

    record_gh = fn items, at ->
      Repo.get!(RecommendationProfile, profile.id)
      |> Ecto.Changeset.change(sources: [%{"connectionId" => "ca-gh", "enabled" => true}])
      |> Repo.update!()

      MemberSourceItems.record(
        profile.id,
        %{collected: %{"ca-gh" => %{"toolkit" => "github", "app" => "GitHub", "items" => items}}},
        ["ca-gh"],
        at
      )
    end

    {:ok, _} = record_gh.([], now)

    {:ok, %{new: 1}} =
      record_gh.([gh_item.("1001", "Gate failed on main")], DateTime.add(now, 60))

    [run_1] = MemberSourceItems.pending(profile.id, 24)

    # First judgment timed out (`attempts: 0, failures: 1`), then 3 newer CI runs
    # push `1001` out of the per-repo `current_keys` window.
    :ok =
      MemberSourceItems.settle([run_1], %{
        "outcome" => "retry",
        "attempts" => 0,
        "failures" => 1
      })

    newer = for k <- ~w(1002 1003 1004), do: gh_item.(k, "Failure " <> k)
    {:ok, %{new: 3}} = record_gh.(newer, DateTime.add(now, 960))

    pending_keys = MemberSourceItems.pending(profile.id, 24) |> Enum.map(& &1.item_key)
    assert "1001" in pending_keys
    assert {:ok, :recovered} = MemberSourceItems.while_pending(run_1, fn -> {:ok, :recovered} end)

    # Settle the newer 3 items and flood 405 passive settled notifications so the
    # source exceeds the 400-item retention bound: active `retry` row `1001` stays.
    newer_rows =
      MemberSourceItems.pending(profile.id, 24) |> Enum.reject(&(&1.item_key == "1001"))

    :ok = MemberSourceItems.settle(newer_rows, %{"outcome" => "quiet"})

    flood = for n <- 1..405, do: gh_item.("noise-#{n}", "Subscribed notification #{n}")
    {:ok, _} = record_gh.(flood, DateTime.add(now, 1_800))

    flood_rows =
      Repo.all(
        from(i in MemberSourceItem,
          where: i.profile_id == ^profile.id and i.source_id == "ca-gh" and is_nil(i.attention)
        )
      )

    :ok = MemberSourceItems.settle(flood_rows, %{"outcome" => "quiet"})
    {:ok, _} = record_gh.([gh_item.("noise-406", "One more")], DateTime.add(now, 2_400))

    total_count =
      Repo.one!(
        from(i in MemberSourceItem,
          where: i.profile_id == ^profile.id and i.source_id == "ca-gh",
          select: count(i.id)
        )
      )

    assert total_count == 400
    assert Repo.get(MemberSourceItem, run_1.id) != nil
    assert "1001" in Enum.map(MemberSourceItems.pending(profile.id, 24), & &1.item_key)

    # Off-window recovery stops once failures reach 3 or the 48-hour grace elapses.
    :ok =
      MemberSourceItems.settle([run_1], %{
        "outcome" => "retry",
        "attempts" => 0,
        "failures" => 3
      })

    refute "1001" in Enum.map(MemberSourceItems.pending(profile.id, 24), & &1.item_key)

    :ok =
      MemberSourceItems.settle([run_1], %{
        "outcome" => "retry",
        "attempts" => 0,
        "failures" => 1
      })

    {:ok, _} = record_gh.([gh_item.("noise-406", "One more")], DateTime.add(now, 49 * 3_600))
    refute "1001" in Enum.map(MemberSourceItems.pending(profile.id, 24), & &1.item_key)

    # Non-truncated mailbox reads still withdraw answered mail immediately, while
    # a truncated mailbox read keeps a retryable mail item eligible.
    {:ok, _} = record(profile, %{"ca-mail" => []}, ["ca-mail"], now)

    {:ok, _} =
      record(profile, %{"ca-mail" => [mail("m1", "Urgent")]}, ["ca-mail"], DateTime.add(now, 60))

    [m1] = MemberSourceItems.pending(profile.id, 24)

    :ok =
      MemberSourceItems.settle([m1], %{"outcome" => "retry", "attempts" => 0, "failures" => 1})

    {:ok, _} =
      MemberSourceItems.record(
        profile.id,
        %{
          collected: %{
            "ca-mail" => %{
              "toolkit" => "gmail",
              "app" => "Gmail",
              "bound" => %{"truncated" => false},
              "items" => []
            }
          }
        },
        ["ca-mail"],
        DateTime.add(now, 120)
      )

    assert MemberSourceItems.pending(profile.id, 24) == []

    {:ok, _} =
      MemberSourceItems.record(
        profile.id,
        %{
          collected: %{
            "ca-mail" => %{
              "toolkit" => "gmail",
              "app" => "Gmail",
              "bound" => %{"truncated" => true},
              "items" => []
            }
          }
        },
        ["ca-mail"],
        DateTime.add(now, 180)
      )

    assert [%{id: id}] = MemberSourceItems.pending(profile.id, 24)
    assert id == m1.id
  end

  test "the 400-item sweep keeps first only the items that can still wait for a consumer" do
    {profile, _workspace} = profile_fixture!()
    start = ~U[2026-11-20 02:00:00.000000Z]
    at = DateTime.add(start, 50 * 3_600)
    clock = SystemsClock.system_time(:millisecond)
    cap = MemberSourceItems.rechecks()
    recent = DateTime.add(at, -3_600)
    stale = DateTime.add(at, -49 * 3_600)

    {:ok, _} = collect(profile, "ca-gh", "github", [], nil, start)

    put_rows!(profile, "ca-gh", "github", start, [
      # Off-window retries whose recovery window has closed.
      {"retry-exhausted", %{"outcome" => "retry", "attempts" => 0, "failures" => 3}, recent},
      {"retry-stale", %{"outcome" => "retry", "attempts" => 0, "failures" => 1}, stale},
      # A deferred matter after its last recheck, with no due time.
      {"deferred-spent", %{"outcome" => "deferred", "next_at" => clock, "rechecks" => cap},
       recent},
      # Items a later check can still wake.
      {"retry-live", %{"outcome" => "retry", "attempts" => 0, "failures" => 1}, recent},
      {"quiet-due", %{"outcome" => "quiet", "due_at" => clock + 3_600_000}, recent},
      {"deferred-due",
       %{"outcome" => "deferred", "next_at" => clock, "rechecks" => cap, "due_at" => clock},
       recent}
    ])

    {:ok, %{new: 1}} = collect(profile, "ca-gh", "github", [run("new")], nil, at)

    assert source_count(profile, "ca-gh") == 400

    assert kept_special_keys(profile, "ca-gh") ==
             ~w(deferred-due new quiet-due retry-live)

    # A non-truncated mailbox read reflects the live inbox, so an off-window
    # mail retry has no recovery window to keep. A truncated read keeps it.
    for {truncated, kept} <- [{false, ~w(new)}, {true, ~w(new retry-live)}] do
      bound = %{"truncated" => truncated}
      {:ok, _} = collect(profile, "ca-mail", "gmail", [], bound, start)

      put_rows!(profile, "ca-mail", "gmail", start, [
        {"retry-live", %{"outcome" => "retry", "attempts" => 0, "failures" => 1}, recent}
      ])

      {:ok, _} = collect(profile, "ca-mail", "gmail", [mail("new", "New")], bound, at)

      assert source_count(profile, "ca-mail") == 400
      assert kept_special_keys(profile, "ca-mail") == kept
      MemberSourceItems.reset(profile.id)
    end
  end

  # Settled rows of one source: the given special rows, seen first, and 400
  # quiet notifications seen later, so the specials go first in a plain sweep.
  defp put_rows!(profile, source_id, toolkit, start, specials) do
    noise =
      for n <- 1..400 do
        {"noise-#{n}", %{"outcome" => "quiet"}, DateTime.add(start, 3_600 + n)}
      end

    rows =
      for {{key, attention, changed_at}, index} <- Enum.with_index(specials ++ noise) do
        seen = if index < length(specials), do: start, else: changed_at

        %{
          id: SystemsRuntime.Proc.uuid(),
          profile_id: profile.id,
          source_id: source_id,
          toolkit: toolkit,
          item_key: key,
          url: "https://example.test/" <> key,
          fingerprint: key,
          baseline: false,
          attention: attention,
          facts: %{},
          provider_ids: %{},
          first_seen_at: start,
          last_seen_at: seen,
          changed_at: changed_at
        }
      end

    Repo.insert_all(MemberSourceItem, rows)
  end

  defp collect(profile, source_id, toolkit, items, bound, at) do
    Repo.get!(RecommendationProfile, profile.id)
    |> Ecto.Changeset.change(sources: [%{"connectionId" => source_id, "enabled" => true}])
    |> Repo.update!()

    source = %{"toolkit" => toolkit, "app" => toolkit, "bound" => bound, "items" => items}
    MemberSourceItems.record(profile.id, %{collected: %{source_id => source}}, [source_id], at)
  end

  defp source_count(profile, source_id),
    do: Repo.one!(from(i in items(profile.id), where: i.source_id == ^source_id, select: count()))

  defp kept_special_keys(profile, source_id) do
    from(i in items(profile.id),
      where: i.source_id == ^source_id and not like(i.item_key, "noise-%"),
      select: i.item_key,
      order_by: i.item_key
    )
    |> Repo.all()
  end

  defp run(key) do
    %{
      "item_key" => key,
      "toolkit" => "github",
      "app" => "GitHub",
      "url" => "https://github.com/AFK-surf/still.fail/actions/runs/" <> key,
      "title" => "CI run " <> key,
      "excerpt" => key,
      "fingerprint" => key
    }
  end

  defp record(profile, sources, enabled, at \\ SystemsClock.utc_now()) do
    # Fixture settings represent the selection captured by a normal collection.
    Repo.get!(RecommendationProfile, profile.id)
    |> Ecto.Changeset.change(
      sources: Enum.map(enabled, &%{"connectionId" => &1, "enabled" => true})
    )
    |> Repo.update!()

    MemberSourceItems.record(
      profile.id,
      %{collected: Map.new(sources, fn {id, items} -> {id, source(items)} end)},
      enabled,
      at
    )
  end

  defp source(items), do: %{"toolkit" => "gmail", "app" => "Gmail", "items" => items}

  # One item whose source text is `text`; changed text is a new version.
  defp mail(key, text) do
    %{
      "item_key" => key,
      "toolkit" => "gmail",
      "app" => "Gmail",
      "url" => "https://mail.google.com/mail/#inbox/" <> key,
      "title" => "Mail " <> key,
      "excerpt" => text,
      "prompt_context" => text,
      "relationship" => "unread_in_inbox",
      "facts" => %{},
      "provider_ids" => %{},
      # A caller's text-only version must not hide changes to other evidence.
      "fingerprint" => :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
    }
  end

  defp items(profile_id), do: from(i in MemberSourceItem, where: i.profile_id == ^profile_id)

  defp sources(profile_id),
    do: Repo.all(from(i in items(profile_id), select: i.source_id, distinct: true, order_by: 1))

  defp profile_fixture! do
    {:ok, user} =
      Comma.Accounts.create_user(%{
        "email" => "source-items-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-source-items-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant_id,
        salix_group_id: group_id,
        group_generation: "generation-1",
        salix_router_agent_id: Ids.new_agent_id(group_id),
        salix_worker_agent_id: Ids.new_agent_id(group_id),
        billing_owner_id: "billing-#{user["id"]}",
        name: "Source items",
        status: "active"
      })
      |> Repo.insert!()

    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(%{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })
    |> Repo.insert!()

    profile =
      %RecommendationProfile{}
      |> RecommendationProfile.create_changeset(%{
        workspace_id: workspace.id,
        user_id: user["id"],
        relevance_mode: "member",
        timezone: "Asia/Singapore"
      })
      |> Repo.insert!()

    {profile, workspace}
  end
end
