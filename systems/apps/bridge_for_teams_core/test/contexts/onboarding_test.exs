defmodule BridgeForTeams.OnboardingTest do
  @moduledoc """
  Context tests for the dashboard first-run onboarding: role-based step lists,
  data-derived step completion (Agent Swarms / org OAuth apps via the
  in-process Salix control plane / observed connections), UI-state writes, and
  the member→admin OAuth reminders.
  """
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, Memberships, Onboarding, Orgs, OrgOAuthApps, Projects}

  setup do
    SalixStore.S3.Fake.reset()
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme-onboarding"})
    {:ok, owner} = Accounts.create_user(%{"email" => "owner@example.com", "name" => "Owner"})
    {:ok, member} = Accounts.create_user(%{"email" => "member@example.com", "name" => "Member"})
    {:ok, _} = Memberships.put_org_member(org.id, owner.id, "owner")
    {:ok, _} = Memberships.put_org_member(org.id, member.id, "member")
    Onboarding.invalidate_oauth_cache(org.id)
    %{org: org, owner: owner, member: member}
  end

  test "steps depend on role" do
    assert Onboarding.steps_for_role("owner") == ["swarm", "oauth", "connect"]
    assert Onboarding.steps_for_role("admin") == ["swarm", "oauth", "connect"]
    assert Onboarding.steps_for_role("member") == ["swarm", "connect"]
    assert Onboarding.steps_for_role(nil) == []
  end

  test "snapshot derives everything undone for a fresh org", %{org: org, owner: owner} do
    snap = Onboarding.snapshot(org, owner.id, "owner")

    assert snap.done == %{"swarm" => false, "oauth" => false, "connect" => false}
    assert snap.done_count == 0
    assert snap.total == 3
    refute snap.all_done?
    assert snap.first_project == nil
  end

  test "swarm step derives from visible projects and prefers the user's own",
       %{org: org, owner: owner, member: member} do
    {:ok, other} = Projects.create_project(org.id, %{"name" => "Other", "slug" => "other"})

    {:ok, mine} =
      Projects.create_project(org.id, %{"name" => "Mine", "slug" => "mine"},
        creator_user_id: owner.id
      )

    snap = Onboarding.snapshot(org, owner.id, "owner")
    assert snap.done["swarm"]
    assert snap.first_project.id == mine.id

    # The member has no ACL grant on any project, so their swarm step is undone.
    snap = Onboarding.snapshot(org, member.id, "member")
    refute snap.done["swarm"]

    {:ok, _} = Memberships.put_project_member(other.id, member.id, "user")
    snap = Onboarding.snapshot(org, member.id, "member")
    assert snap.done["swarm"]
    assert snap.first_project.id == other.id
  end

  test "oauth step derives from configured provider apps (cache invalidated on write)",
       %{org: org, owner: owner} do
    refute Onboarding.snapshot(org, owner.id, "owner").done["oauth"]

    {:ok, _} =
      OrgOAuthApps.upsert_org_oauth_app(org.id, "github", %{
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    # Still cached as unconfigured until invalidated.
    refute Onboarding.snapshot(org, owner.id, "owner").done["oauth"]
    assert Onboarding.snapshot(org, owner.id, "owner", refresh_oauth: true).done["oauth"]
  end

  test "connect step derives from the observed-connection cache", %{org: org, owner: owner} do
    refute Onboarding.snapshot(org, owner.id, "owner").done["connect"]

    :ok = Onboarding.observe_connected(org.id, owner.id)
    :ok = Onboarding.observe_connected(org.id, owner.id)

    snap = Onboarding.snapshot(org, owner.id, "owner")
    assert snap.done["connect"]
    assert snap.done_count == 1
  end

  test "explicitly skipped steps count as done", %{org: org, owner: owner} do
    {:ok, _} = Onboarding.skip_step(org.id, owner.id, "swarm")
    # Idempotent — skipping again never duplicates the entry.
    {:ok, _} = Onboarding.skip_step(org.id, owner.id, "swarm")
    assert Onboarding.get_state(org.id, owner.id).skipped_steps == ["swarm"]

    snap = Onboarding.snapshot(org, owner.id, "owner")
    assert snap.done["swarm"]
    assert snap.done_count == 1
    refute snap.all_done?

    {:ok, _} = Onboarding.skip_step(org.id, owner.id, "oauth")
    {:ok, _} = Onboarding.skip_step(org.id, owner.id, "connect")
    assert Onboarding.snapshot(org, owner.id, "owner").all_done?
  end

  test "ui state transitions", %{org: org, owner: owner} do
    state = Onboarding.get_state(org.id, owner.id)
    assert state.id == nil
    refute state.dismissed_at

    {:ok, _} = Onboarding.dismiss(org.id, owner.id)
    state = Onboarding.get_state(org.id, owner.id)
    assert state.dismissed_at

    {:ok, _} = Onboarding.celebrate(org.id, owner.id)
    state = Onboarding.get_state(org.id, owner.id)
    assert state.celebrated_at
  end

  test "oauth reminders are idempotent and listed for admins",
       %{org: org, owner: owner, member: member} do
    assert Onboarding.pending_oauth_reminders(org.id) == []

    {:ok, first} = Onboarding.remind_admins(org.id, member.id)
    {:ok, again} = Onboarding.remind_admins(org.id, member.id)
    assert first.oauth_reminded_at == again.oauth_reminded_at

    {:ok, _} = Onboarding.remind_admins(org.id, owner.id)

    reminders = Onboarding.pending_oauth_reminders(org.id)
    assert length(reminders) == 2
    assert [%{user: %{id: first_id}}, _] = reminders
    assert first_id == member.id
  end
end
