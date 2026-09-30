defmodule BridgeForTeams.ProviderScopes do
  @moduledoc """
  Derive the OAuth scopes a provider connection should request from the
  capabilities the user actually granted during onboarding
  (`user_onboardings.capabilities` — the boolean grant map from
  `BridgeForTeamsWeb.Dashboard.OnboardingLive.Catalog`).

  Scope minimization is the point: the consent screen asks only for what the
  granted capabilities need, and later grants widen the connection through
  Google's incremental authorization (the adapter already sends
  `include_granted_scopes=true`, so re-running the connect flow adds scopes
  without losing previously granted ones).

  Google is the only provider with capability-derived scope mappings in this
  module; other providers return `[]` and fall back to their adapter defaults.
  The Gmail scopes are Google
  "restricted" scopes — production apps need Google's app verification (and a
  security assessment) before consent works outside test users.

  Drafting capabilities map to the granular `gmail.drafts.create` scope, so
  "draft replies — nothing sends itself" holds at the scope level: the token
  cannot send mail (`gmail.compose`/`gmail.send` are deliberately never
  requested).
  """

  @gmail_read "https://www.googleapis.com/auth/gmail.readonly"
  @gmail_modify "https://www.googleapis.com/auth/gmail.modify"
  @gmail_drafts_create "https://www.googleapis.com/auth/gmail.drafts.create"
  @calendar_read "https://www.googleapis.com/auth/calendar.readonly"
  @calendar_events "https://www.googleapis.com/auth/calendar.events"
  @contacts_read "https://www.googleapis.com/auth/contacts.readonly"

  # Capability key (catalog) → the Google scopes that capability needs.
  # Reading mail rides gmail.readonly; labeling/archiving are mailbox writes
  # (gmail.modify); drafting needs gmail.drafts.create plus read to find the
  # thread; scheduling/briefings read the calendar; the optimizer writes
  # events; the contact dossier reads contacts.
  @google %{
    "inbox.label_new_mail" => [@gmail_modify],
    "inbox.archive_unimportant" => [@gmail_modify],
    "inbox.draft_replies" => [@gmail_drafts_create, @gmail_read],
    "inbox.decline_cold_outreach" => [@gmail_drafts_create, @gmail_read],
    "inbox.assist_scheduling" => [@gmail_read, @calendar_read],
    "informed.morning_briefing" => [@gmail_read, @calendar_read],
    "informed.newsletter_digest" => [@gmail_read],
    "meetings.meeting_briefing" => [@calendar_read],
    "meetings.contact_dossier" => [@calendar_read, @contacts_read],
    "calendar.schedule_optimizer" => [@calendar_events]
  }

  # Broader scope → the narrower ones it already covers; requesting both would
  # only lengthen the consent screen.
  @supersedes %{
    @gmail_modify => [@gmail_read, @gmail_drafts_create],
    @calendar_events => [@calendar_read]
  }

  @doc """
  The scopes to request when connecting `provider` for a user whose granted
  capabilities are `capabilities` (the boolean map; reserved `_`-prefixed keys
  are ignored). Returns a sorted, deduplicated list; `[]` means "adapter
  defaults" (identity-only for Google).
  """
  @spec scopes(String.t(), map() | nil) :: [String.t()]
  def scopes("google", capabilities) when is_map(capabilities) do
    requested =
      @google
      |> Enum.filter(fn {capability, _scopes} -> capabilities[capability] == true end)
      |> Enum.flat_map(fn {_capability, scopes} -> scopes end)
      |> MapSet.new()

    superseded =
      @supersedes
      |> Enum.filter(fn {broad, _narrow} -> MapSet.member?(requested, broad) end)
      |> Enum.flat_map(fn {_broad, narrow} -> narrow end)
      |> MapSet.new()

    requested
    |> MapSet.difference(superseded)
    |> Enum.sort()
  end

  def scopes(_provider, _capabilities), do: []
end
