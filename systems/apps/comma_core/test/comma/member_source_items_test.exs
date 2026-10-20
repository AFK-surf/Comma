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
