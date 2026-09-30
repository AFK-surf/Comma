defmodule BridgeForTeams.ProviderScopesTest do
  @moduledoc """
  Capability→scope derivation: consent asks only for what the granted
  capabilities need, broader scopes supersede narrower ones, drafting never
  requests a scope that can send mail, and non-Google providers keep their
  adapter defaults.
  """
  use ExUnit.Case, async: true

  alias BridgeForTeams.ProviderScopes

  @gmail_read "https://www.googleapis.com/auth/gmail.readonly"
  @gmail_modify "https://www.googleapis.com/auth/gmail.modify"
  @gmail_drafts_create "https://www.googleapis.com/auth/gmail.drafts.create"
  @calendar_read "https://www.googleapis.com/auth/calendar.readonly"
  @calendar_events "https://www.googleapis.com/auth/calendar.events"
  @contacts_read "https://www.googleapis.com/auth/contacts.readonly"

  test "no grants (or no google-relevant grants) means adapter defaults" do
    assert ProviderScopes.scopes("google", %{}) == []
    assert ProviderScopes.scopes("google", %{"notifications.im_updates" => true}) == []
    # Revoked grants don't count.
    assert ProviderScopes.scopes("google", %{"inbox.draft_replies" => false}) == []
  end

  test "read-only grants request read-only scopes" do
    assert ProviderScopes.scopes("google", %{"informed.newsletter_digest" => true}) ==
             [@gmail_read]

    assert ProviderScopes.scopes("google", %{"informed.morning_briefing" => true}) ==
             Enum.sort([@gmail_read, @calendar_read])
  end

  test "drafting uses gmail.drafts.create, never a scope that can send" do
    scopes = ProviderScopes.scopes("google", %{"inbox.draft_replies" => true})

    assert scopes == Enum.sort([@gmail_drafts_create, @gmail_read])
    refute Enum.any?(scopes, &String.contains?(&1, "compose"))
    refute Enum.any?(scopes, &String.contains?(&1, "gmail.send"))
  end

  test "gmail.modify supersedes gmail.readonly and gmail.drafts.create" do
    scopes =
      ProviderScopes.scopes("google", %{
        "inbox.label_new_mail" => true,
        "inbox.draft_replies" => true,
        "informed.newsletter_digest" => true
      })

    assert scopes == [@gmail_modify]
  end

  test "calendar.events supersedes calendar.readonly" do
    scopes =
      ProviderScopes.scopes("google", %{
        "calendar.schedule_optimizer" => true,
        "meetings.meeting_briefing" => true
      })

    assert scopes == [@calendar_events]
  end

  test "the everything-granted set stays minimal and send-free" do
    all =
      ~w(inbox.label_new_mail inbox.archive_unimportant inbox.draft_replies
         inbox.decline_cold_outreach inbox.assist_scheduling informed.morning_briefing
         informed.newsletter_digest meetings.meeting_briefing meetings.contact_dossier
         calendar.schedule_optimizer)
      |> Map.new(&{&1, true})

    assert ProviderScopes.scopes("google", all) ==
             Enum.sort([@gmail_modify, @calendar_events, @contacts_read])
  end

  test "other providers fall back to adapter defaults" do
    grants = %{"informed.github_reports" => true}
    assert ProviderScopes.scopes("github", grants) == []
    assert ProviderScopes.scopes("notion", nil) == []
  end
end
