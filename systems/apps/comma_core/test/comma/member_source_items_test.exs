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
