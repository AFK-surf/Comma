defmodule BridgeForTeamsWeb.Dashboard.OnboardingLive.Catalog do
  @moduledoc """
  Static definitions behind the onboarding flow: capability groups (what the
  agent may do on the user's behalf) and integration display metadata.

  Everything user-visible is a gettext call inside a function so labels resolve
  against the process locale at render time. Capability keys are stable strings
  (`"group.capability"`) persisted in `user_onboardings.capabilities`; each one
  is grounded in a real Comma runtime capability (Gmail/Calendar via the Google
  OAuth adapter, GitHub/Linear/Notion/Slack OAuth tools, IM connects, cron
  schedules, semantic memory).
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  @doc "Capability groups for the onboarding capabilities step, in display order."
  @spec capability_groups() :: [map()]
  def capability_groups do
    [
      %{
        key: "inbox",
        icon: "envelope",
        title: gettext("Manage Your Inbox"),
        description: gettext("Your inbox, organized without the work."),
        capabilities: [
          %{
            key: "inbox.label_new_mail",
            label: gettext("Label new mail"),
            description: gettext("Sort incoming email into topical labels.")
          },
          %{
            key: "inbox.archive_unimportant",
            label: gettext("Archive unimportant emails"),
            description: gettext("Move low-signal mail out of the inbox automatically.")
          },
          %{
            key: "inbox.assist_scheduling",
            label: gettext("Assist with scheduling"),
            description: gettext("Spot scheduling requests and propose times.")
          },
          %{
            key: "inbox.draft_replies",
            label: gettext("Draft replies to important emails"),
            description: gettext("Prepare replies for your review — nothing sends itself.")
          },
          %{
            key: "inbox.decline_cold_outreach",
            label: gettext("Decline cold outreach"),
            description: gettext("Keep your inbox clear of unsolicited pitches.")
          }
        ]
      },
      %{
        key: "informed",
        icon: "newspaper",
        title: gettext("Stay informed"),
        description: gettext("Start your day knowing exactly what matters."),
        capabilities: [
          %{
            key: "informed.competitive_intel",
            label: gettext("Competitive intel briefing"),
            description: gettext("Track the companies you care about. Stay ahead.")
          },
          %{
            key: "informed.github_reports",
            label: gettext("GitHub reports"),
            description: gettext("Engineering activity summaries from connected repos.")
          }
        ]
      },
      %{
        key: "meetings",
        icon: "users",
        title: gettext("Prepare for Meetings"),
        description: gettext("Walk in knowing who you'll meet and why."),
        capabilities: [
          %{
            key: "meetings.meeting_briefing",
            label: gettext("Meeting briefing"),
            description: gettext("Prep notes before internal and external meetings.")
          },
          %{
            key: "meetings.contact_dossier",
            label: gettext("Contact research dossier"),
            description: gettext("Executive-ready briefings for new contacts.")
          }
        ]
      },
      %{
        key: "calendar",
        icon: "calendar",
        title: gettext("Manage Your Calendar"),
        description: gettext("Smarter weeks, fewer back-to-backs."),
        capabilities: [
          %{
            key: "calendar.schedule_optimizer",
            label: gettext("Schedule optimizer"),
            description: gettext("Rebalance your week and protect focus time.")
          }
        ]
      },
      %{
        key: "notifications",
        icon: "chat-bubble",
        title: gettext("Proactive Notifications"),
        description: gettext("Get pinged where you already work."),
        capabilities: [
          %{
            key: "notifications.im_updates",
            label: gettext("IM updates"),
            description: gettext("Send updates in Slack or Feishu when something needs you.")
          }
        ]
      },
      %{
        key: "memory",
        icon: "sparkles",
        title: gettext("Agent Memory"),
        description: gettext("A persistent model of you and your team."),
        capabilities: [
          %{
            key: "memory.semantic_profile",
            label: gettext("Personal memory"),
            description: gettext("Maintain a durable profile of your preferences and context.")
          }
        ]
      }
    ]
  end

  @doc """
  Default capability grants: opt-out posture (everything on) except
  auto-archiving, which stays off until explicitly enabled.
  """
  @spec default_capabilities() :: %{optional(String.t()) => boolean()}
  def default_capabilities do
    for group <- capability_groups(),
        capability <- group.capabilities,
        into: %{} do
      {capability.key, capability.key != "inbox.archive_unimportant"}
    end
  end

  @doc "Display name for an integration key (OAuth provider or Composio toolkit slug)."
  @spec provider_label(String.t()) :: String.t()
  def provider_label("google"), do: "Google"
  def provider_label("gmail"), do: "Gmail"
  def provider_label("googlecalendar"), do: "Google Calendar"
  def provider_label("github"), do: "GitHub"
  def provider_label("linear"), do: "Linear"
  def provider_label("notion"), do: "Notion"
  def provider_label("slack"), do: "Slack"
  def provider_label(other), do: String.capitalize(other)

  @doc "What connecting an integration unlocks (shown on the integrations step)."
  @spec provider_description(String.t()) :: String.t()
  def provider_description("google"),
    do: gettext("Gmail, Calendar, Drive, and Contacts power inbox and meeting features.")

  def provider_description("gmail"),
    do: gettext("Inbox triage, drafted replies, and mail digests.")

  def provider_description("googlecalendar"),
    do: gettext("Meeting briefings and a smarter, rebalanced week.")

  def provider_description("github"),
    do: gettext("Engineering activity from your portfolio's repositories.")

  def provider_description("linear"),
    do: gettext("Issue tracking visibility across teams.")

  def provider_description("notion"),
    do: gettext("Read and create pages in your workspace.")

  def provider_description("slack"),
    do: gettext("Search and send messages on your behalf.")

  def provider_description(_other), do: ""
end
