defmodule BridgeForTeamsWeb.Dashboard.OnboardingLive.Catalog do
  @moduledoc """
  Static definitions behind the onboarding flow and the New Home board:
  capability groups (what the agent may do on the user's behalf), starter-task
  templates (suggestions derived from granted capabilities + connected
  platforms), and shared category/platform display metadata.

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
            key: "informed.morning_briefing",
            label: gettext("Morning briefing"),
            description: gettext("A daily digest of mail, meetings, and news.")
          },
          %{
            key: "informed.newsletter_digest",
            label: gettext("Newsletter digest"),
            description: gettext("Clean digests of your newsletters, on a schedule.")
          },
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
        key: "routines",
        icon: "clock",
        title: gettext("Scheduled Routines"),
        description: gettext("Recurring work your agent runs on a schedule."),
        capabilities: [
          %{
            key: "routines.scheduled",
            label: gettext("Scheduled routines"),
            description: gettext("Run recurring jobs on cron — briefings, reports, cleanups.")
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

  @doc """
  Starter-task suggestions for the granted `capabilities` and the set of
  connected OAuth `providers` (strings like `"google"`). A template is offered
  when its capability is granted AND (it needs no platform OR the platform is
  connected). Generic fallbacks keep the list from ever being empty.
  """
  @spec suggested_tasks(%{optional(String.t()) => boolean()}, MapSet.t()) :: [map()]
  def suggested_tasks(capabilities, providers) do
    task_templates()
    |> Enum.filter(fn template ->
      granted? = template.capability == nil or capabilities[template.capability] == true
      platform_ok? = template.provider == nil or MapSet.member?(providers, template.provider)
      granted? and platform_ok?
    end)
    |> Enum.with_index()
    |> Enum.map(fn {template, index} ->
      template
      |> Map.take([:title, :description, :category, :platform])
      |> Map.put(:id, "suggestion-#{index}")
    end)
  end

  defp task_templates do
    [
      %{
        capability: "inbox.draft_replies",
        provider: nil,
        title: gettext("Draft a reply to the most important email in my inbox"),
        description: gettext("Ready for your review before anything is sent."),
        category: "email_drafts",
        platform: "gmail"
      },
      %{
        capability: "inbox.label_new_mail",
        provider: "google",
        title: gettext("Label and triage today's incoming mail"),
        description: gettext("Topical labels applied as mail arrives."),
        category: "inbox",
        platform: "gmail"
      },
      %{
        capability: "informed.morning_briefing",
        provider: nil,
        title: gettext("Send me a morning briefing every weekday"),
        description: gettext("Mail, meetings, and portfolio news before 9am."),
        category: "routines",
        platform: "comma"
      },
      %{
        capability: "meetings.meeting_briefing",
        provider: nil,
        title: gettext("Recap last week's meetings and prep the next ones"),
        description: gettext("Summaries of what happened, briefs for what's ahead."),
        category: "meeting_recaps",
        platform: "google_calendar"
      },
      %{
        capability: "meetings.contact_dossier",
        provider: nil,
        title: gettext("Build research dossiers for my key contacts"),
        description: gettext("Backgrounds for the people you meet most."),
        category: "meetings",
        platform: "comma"
      },
      %{
        capability: "informed.github_reports",
        provider: "github",
        title: gettext("Compile a weekly engineering activity report"),
        description: gettext("PRs, commits, and reviews across connected repos."),
        category: "engineering",
        platform: "github"
      },
      %{
        capability: nil,
        provider: "linear",
        title: gettext("Summarize open Linear issues across teams"),
        description: gettext("What's in flight, what's blocked, what shipped."),
        category: "engineering",
        platform: "linear"
      },
      %{
        capability: nil,
        provider: "notion",
        title: gettext("Create a portfolio update template in Notion"),
        description: gettext("A reusable page for company status updates."),
        category: "portfolio",
        platform: "notion"
      },
      %{
        capability: "notifications.im_updates",
        provider: "slack",
        title: gettext("Post a weekly team activity digest in Slack"),
        description: gettext("Who's working on what, delivered to your channel."),
        category: "team_activity",
        platform: "slack"
      },
      %{
        capability: "calendar.schedule_optimizer",
        provider: nil,
        title: gettext("Rebalance next week's calendar for focus time"),
        description: gettext("Fewer back-to-backs, protected deep-work blocks."),
        category: "calendar",
        platform: "google_calendar"
      },
      %{
        capability: "routines.scheduled",
        provider: nil,
        title: gettext("Create a daily wrap-up routine"),
        description: gettext("An end-of-day summary of everything that moved."),
        category: "routines",
        platform: "comma"
      },
      # Fallbacks: no capability/platform requirement, so the list is never empty.
      %{
        capability: nil,
        provider: nil,
        title: gettext("Find everything I need to follow up on"),
        description: gettext("Unanswered threads, open asks, and stale promises."),
        category: "inbox",
        platform: "comma"
      },
      %{
        capability: nil,
        provider: nil,
        title: gettext("Compile a portfolio status overview"),
        description: gettext("One view of how every company is doing."),
        category: "portfolio",
        platform: "comma"
      }
    ]
  end

  @doc "Display metadata (icon + label) for an agent-task category."
  @spec category_meta(String.t()) :: %{icon: String.t(), label: String.t()}
  def category_meta("reports"), do: %{icon: "globe", label: gettext("Reports")}
  def category_meta("email_drafts"), do: %{icon: "envelope", label: gettext("Drafted emails")}
  def category_meta("meeting_recaps"), do: %{icon: "calendar", label: gettext("Meeting recaps")}
  def category_meta("portfolio"), do: %{icon: "chart-bar", label: gettext("Portfolio overview")}
  def category_meta("team_activity"), do: %{icon: "users", label: gettext("Team activity")}

  def category_meta("engineering"),
    do: %{icon: "code-bracket", label: gettext("Engineering activity")}

  def category_meta("metrics"), do: %{icon: "chart-bar", label: gettext("Key metrics")}
  def category_meta("inbox"), do: %{icon: "inbox", label: gettext("Inbox")}
  def category_meta("informed"), do: %{icon: "newspaper", label: gettext("Stay informed")}
  def category_meta("meetings"), do: %{icon: "users", label: gettext("Meetings")}
  def category_meta("general"), do: %{icon: "check", label: gettext("General tasks")}
  def category_meta("calendar"), do: %{icon: "calendar", label: gettext("Calendar")}
  def category_meta("routines"), do: %{icon: "clock", label: gettext("Routines")}
  def category_meta("issues"), do: %{icon: "bolt", label: gettext("Top issues")}
  def category_meta("suggestions"), do: %{icon: "sparkles", label: gettext("Suggestions")}
  def category_meta("devices"), do: %{icon: "cube", label: gettext("Devices")}
  def category_meta(_other), do: %{icon: "sparkles", label: gettext("Other")}

  @doc "Human label for an agent-task platform."
  @spec platform_label(String.t()) :: String.t()
  def platform_label("gmail"), do: "Gmail"
  def platform_label("google_calendar"), do: "Google Calendar"
  def platform_label("github"), do: "GitHub"
  def platform_label("linear"), do: "Linear"
  def platform_label("notion"), do: "Notion"
  def platform_label("slack"), do: "Slack"
  def platform_label("feishu"), do: "Feishu"
  def platform_label(_other), do: "Comma"

  @doc "Badge color for an agent-task platform."
  @spec platform_badge_color(String.t()) :: String.t()
  def platform_badge_color("gmail"), do: "red"
  def platform_badge_color("google_calendar"), do: "green"
  def platform_badge_color("github"), do: "neutral"
  def platform_badge_color("linear"), do: "brand"
  def platform_badge_color("notion"), do: "neutral"
  def platform_badge_color("slack"), do: "amber"
  def platform_badge_color("feishu"), do: "brand"
  def platform_badge_color(_other), do: "brand"

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
