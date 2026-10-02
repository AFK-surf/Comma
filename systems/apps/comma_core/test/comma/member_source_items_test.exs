defmodule Comma.MemberSourceItemsTest do
  use Comma.DataCase, async: false

  import Ecto.Query

  alias Comma.Data.{MemberSourceItem, RecommendationProfile, Workspace, WorkspaceMembership}
  alias Comma.{MemberSourceConsents, MemberSourceItems, Repo}
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

  test "current items follow each source's latest collection" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-09-24 08:00:00.000000Z]
    enabled = ~w(ca-mail ca-slack)

    {:ok, _} =
      record(
        profile,
        %{"ca-mail" => [mail("a", "A"), mail("b", "B")], "ca-slack" => [mail("s", "S")]},
        enabled,
        now
      )

    # Items keep the order of the source's latest collection.
    {:ok, _} = record(profile, %{"ca-mail" => [mail("b", "B"), mail("a", "A")]}, enabled, now)
    mail = Enum.find(MemberSourceItems.current(profile.id), &(&1.state.source_id == "ca-mail"))
    assert Enum.map(mail.items, & &1.title) == ["Mail b", "Mail a"]

    # Mail "a" left the inbox; Slack failed and keeps its items and success time.
    {:ok, _} =
      MemberSourceItems.record(
        profile.id,
        %{
          collected: %{"ca-mail" => source([mail("b", "B")])},
          failed: %{"ca-slack" => %{"appId" => "slack", "class" => "read", "message" => "503"}}
        },
        enabled,
        DateTime.add(now, 900)
      )

    current = Map.new(MemberSourceItems.current(profile.id), &{&1.state.source_id, &1})
    assert Enum.map(current["ca-mail"].items, & &1.title) == ["Mail b"]
    assert current["ca-slack"].items == []
    assert current["ca-slack"].state.failure["message"] == "503"
    assert current["ca-slack"].state.collected_at == now
    assert Repo.aggregate(items(profile.id), :count) == 3

    # A partial read keeps its readable items with its warning.
    {:ok, _} =
      MemberSourceItems.record(
        profile.id,
        %{
          collected: %{
            "ca-slack" =>
              source([mail("s", "S")])
              |> Map.put("warning", %{"class" => "read", "message" => "one search failed"})
          }
        },
        enabled,
        DateTime.add(now, 1_800)
      )

    slack = Enum.find(MemberSourceItems.current(profile.id), &(&1.state.source_id == "ca-slack"))
    assert Enum.map(slack.items, & &1.title) == ["Mail s"]
    assert slack.state.failure["message"] == "one search failed"

    # Every enabled source must have an attempt inside the window: mail was last
    # attempted at +900 seconds, Slack at +1,800.
    assert MemberSourceItems.fresh?(profile.id, enabled, 1_000, DateTime.add(now, 1_800))
    refute MemberSourceItems.fresh?(profile.id, enabled, 1_000, DateTime.add(now, 2_000))
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

  test "an empty first recording still makes later items arrivals" do
    {profile, _workspace} = profile_fixture!()
    assert {:ok, _} = record(profile, %{"ca-git" => []}, ["ca-git"])

    assert {:ok, %{new: 1}} =
             record(profile, %{"ca-git" => [mail("pr", "Review #884")]}, ["ca-git"])

    assert [%{title: "Mail pr"}] = MemberSourceItems.pending(profile.id, 24)
  end

  test "a source missing for the retention period records a new baseline" do
    {profile, _workspace} = profile_fixture!()
    now = ~U[2026-09-24 08:00:00.000000Z]
    days = MemberSourceItems.retention_days()

    assert {:ok, %{new: 0}} =
             record(profile, %{"ca-mail" => [mail("a", "Old mail")]}, ["ca-mail"], now)

    # Collection failed for longer than retention. Mail that was already there
    # when collection recovered is history again, also mail that changed before
    # the sweep removed its old version.
    later = DateTime.add(now, (days + 1) * 86_400, :second)

    assert {:ok, %{new: 0, changed: 0}} =
             record(
               profile,
               %{"ca-mail" => [mail("a", "Old mail, edited"), mail("b", "Older mail")]},
               ["ca-mail"],
               later
             )

    refute MemberSourceItems.pending?(profile.id)

    # Within the retention period, a new item is an arrival.
    assert {:ok, %{new: 1}} =
             record(
               profile,
               %{"ca-mail" => [mail("c", "New mail")]},
               ["ca-mail"],
               DateTime.add(later, 86_400, :second)
             )

    assert [%{title: "Mail c"}] = MemberSourceItems.pending(profile.id, 24)
  end

  test "items leave the pool when the source is removed, revoked, rebound or expired" do
    {profile, workspace} = profile_fixture!()
    user = %{"id" => profile.user_id}
    now = DateTime.utc_now()
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

    # Rebinding an app to another account deletes the earlier account's items.
    {:ok, :ok} = MemberSourceConsents.record(user, %{}, workspace.id, "gmail", "ca-mail-2")
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

  test "dates and context outside the prompt refresh evidence and reopen attention" do
    {profile, _workspace} = profile_fixture!()
    item = mail("event", "Launch approval") |> Map.put("facts", %{"start" => "2026-09-30"})
    {:ok, _} = record(profile, %{"ca-calendar" => [item]}, ["ca-calendar"])
    [%{items: [original]}] = MemberSourceItems.current(profile.id)

    changed =
      item
      |> Map.put("facts", %{"start" => "2026-09-25"})
      |> Map.put("context", %{"scope" => "search_neighbors", "text" => "Approval needed tomorrow"})

    assert {:ok, %{changed: 1}} =
             record(profile, %{"ca-calendar" => [changed]}, ["ca-calendar"])

    assert [updated] = MemberSourceItems.pending(profile.id, 24)
    assert updated.facts == changed["facts"]
    assert updated.context == changed["context"]
    assert updated.prompt_context == original.prompt_context
    refute updated.fingerprint == original.fingerprint

    :ok = MemberSourceItems.settle([updated], %{"outcome" => "quiet"})

    assert {:ok, %{changed: 0}} =
             record(profile, %{"ca-calendar" => [changed]}, ["ca-calendar"])

    refute MemberSourceItems.pending?(profile.id)
  end

  test "a late recording cannot restore a disabled source or a member pool in generic mode" do
    {profile, _workspace} = profile_fixture!()
    item = mail("a", "Approve today")
    {:ok, _} = record(profile, %{"ca-mail" => [item]}, ["ca-mail"])
    collection = %{collected: %{"ca-mail" => source([item])}}

    for change <- [
          [sources: [%{"connectionId" => "ca-mail", "enabled" => false}]],
          [
            relevance_mode: "generic",
            sources: [%{"connectionId" => "ca-mail", "enabled" => true}]
          ]
        ] do
      Repo.transaction(fn ->
        Repo.get!(RecommendationProfile, profile.id)
        |> Ecto.Changeset.change(change)
        |> Repo.update!()

        MemberSourceItems.retain_sources(profile.id, [])
      end)

      assert {:ok, %{new: 0, changed: 0}} =
               MemberSourceItems.record(profile.id, collection, ["ca-mail"])

      assert MemberSourceItems.current(profile.id) == []
    end
  end

  test "stored items keep bounded excerpts" do
    {profile, _workspace} = profile_fixture!()
    long = String.duplicate("x", 5_000)

    item =
      mail("big", "Big")
      |> Map.merge(%{"excerpt" => long, "context" => %{"text" => long}, "prompt_context" => long})

    {:ok, _} = record(profile, %{"ca-mail" => [item]}, ["ca-mail"])
    [stored] = Repo.all(items(profile.id))
    assert String.length(stored.excerpt) == 1_200
    assert String.length(stored.prompt_context) == 600
    assert byte_size(Jason.encode!(stored.context)) < 1_400
  end

  defp record(profile, sources, enabled, at \\ DateTime.utc_now()) do
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
        "email" => "source-items-#{System.unique_integer([:positive])}@comma.test"
      })

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    workspace =
      %Workspace{}
      |> Workspace.changeset(%{
        id: "wsp-source-items-#{System.unique_integer([:positive])}",
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
