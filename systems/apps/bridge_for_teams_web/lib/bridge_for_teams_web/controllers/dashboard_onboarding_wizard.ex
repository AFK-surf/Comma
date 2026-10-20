defmodule BridgeForTeamsWeb.DashboardOnboardingWizard do
  @moduledoc """
  The first-run onboarding wizard (`/onboarding`, React) for
  `DashboardAPIController`: three steps, then the dashboard.

    1. `capabilities` - what the agent may do for the user (grouped grants).
    2. `profile`      - the user model the agent starts from: identity, a few
                        real teammates, and plans that say "learning" only
                        once Google is really connected.
    3. `integrations` - Composio toolkits and messaging for the user's own
                        Agent Swarm. Finishing here completes onboarding.

  The wizard belongs to the user, not to an organization: it acts on the
  user's first organization (the one `/` opens) and, in it, on the swarm
  `Projects.default_project_for_user/2` picks. Reading the wizard while it is
  in progress creates a swarm the user owns when they own none, so the
  integrations step has somewhere to connect accounts to. A user without an
  organization still goes through every step; the integrations step then has
  no swarm.

  Connecting is swarm-scoped, so it needs the effective project role
  `admin` (an org member who owns their swarm may connect). A refused connect
  records a denied audit entry. Every call makes a fixed number of queries and
  Salix calls, whatever the size of the organization.

  The capability keys are stable and stored in `user_onboardings.capabilities`;
  `BridgeForTeams.ProviderScopes` derives OAuth scopes from them.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  require Logger

  alias BridgeForTeams.{
    Memberships,
    Observability,
    Orgs,
    ProjectComposioConnections,
    ProjectIMConnects,
    Projects,
    UserOnboardings
  }

  @steps ~w(capabilities profile integrations)
  @contact_limit 4

  # Display order. Labels live in the React app; the keys are the contract.
  @capability_groups [
    {"inbox",
     ~w(inbox.label_new_mail inbox.archive_unimportant inbox.assist_scheduling inbox.draft_replies inbox.decline_cold_outreach)},
    {"informed", ~w(informed.competitive_intel informed.github_reports)},
    {"meetings", ~w(meetings.meeting_briefing meetings.contact_dossier)},
    {"calendar", ~w(calendar.schedule_optimizer)},
    {"notifications", ~w(notifications.im_updates)},
    {"memory", ~w(memory.semantic_profile)}
  ]

  @capability_keys Enum.flat_map(@capability_groups, &elem(&1, 1))

  # Opt-out posture: everything on except auto-archiving.
  @default_capabilities Map.new(@capability_keys, &{&1, &1 != "inbox.archive_unimportant"})

  @doc "The capability keys the wizard offers, in display order."
  def capability_keys, do: @capability_keys

  # ---- Reads ----

  @doc """
  The wizard: status, the step to resume on, the capability grants, and the
  identity and teammates the profile step shows.
  """
  def show(user) do
    with {:ok, onboarding} <- ensure(user) do
      org = Orgs.first_org_for_user(user.id)
      if org && onboarding.status == "in_progress", do: ensure_default_swarm(org, user)
      {:ok, payload(onboarding, user, org)}
    end
  end

  @doc """
  The integrations step: the user's swarm, Composio toolkits with their state,
  messaging, and the connected providers the profile plans depend on. A
  Salix failure degrades the step, not the call.
  """
  def integrations(user) do
    org = Orgs.first_org_for_user(user.id)
    {:ok, integrations_payload(org, user)}
  end

  # ---- Writes ----

  @doc """
  Save the capability grants and move on to the profile step. Keys the
  request leaves out keep their current value; an unknown key or a value that
  is not a boolean is refused.
  """
  def save_capabilities(user, params) do
    with {:ok, changes} <- capability_changes(params["capabilities"]),
         {:ok, onboarding} <- ensure(user),
         {:ok, onboarding} <-
           write(
             UserOnboardings.put_capabilities(
               onboarding,
               onboarding.capabilities
               |> Map.merge(capabilities(onboarding))
               |> Map.merge(changes)
             )
           ),
         {:ok, onboarding} <- write(UserOnboardings.advance(onboarding, "profile")) do
      {:ok, payload(onboarding, user, Orgs.first_org_for_user(user.id))}
    end
  end

  @doc """
  Capture the profile the step showed (built from real data here, not taken
  from the request) and move on to the integrations step.
  """
  def save_profile(user) do
    with {:ok, onboarding} <- ensure(user) do
      org = Orgs.first_org_for_user(user.id)
      project = org && Projects.default_project_for_user(org.id, user.id)

      with {:ok, onboarding} <-
             write(UserOnboardings.put_profile(onboarding, profile(user, org, project))),
           {:ok, onboarding} <- write(UserOnboardings.advance(onboarding, "integrations")) do
        {:ok, payload(onboarding, user, org)}
      end
    end
  end

  @doc """
  Start connecting a Composio toolkit for the user's swarm. Answers the
  Connect Link; Composio returns the browser to the integrations step.
  """
  def connect(user, params, base_url) do
    toolkit = params["toolkit"]
    org = Orgs.first_org_for_user(user.id)
    project = org && Projects.default_project_for_user(org.id, user.id)

    cond do
      toolkit not in ProjectComposioConnections.toolkits() ->
        {:error, 422, "unsupported_toolkit", gettext("That account type is not offered here."),
         %{}}

      is_nil(project) ->
        {:error, 409, "no_swarm", gettext("Create an Agent Swarm first to connect accounts."),
         %{}}

      not can_connect?(user, project) ->
        record_denied(org, user, project, toolkit)

        {:error, 403, "forbidden", gettext("Only this swarm's owners can connect accounts."), %{}}

      true ->
        org.id
        |> ProjectComposioConnections.start_connection(
          project.id,
          toolkit,
          %{"callback_url" => base_url <> "/onboarding/integrations"},
          actor_user_id: user.id,
          actor_label: actor_label(user)
        )
        |> started()
    end
  end

  @doc "Finish onboarding. Answers where to go and the notice to show there."
  def complete(user) do
    finish(user, &UserOnboardings.complete/1, gettext("You're all set."))
  end

  @doc "Skip onboarding; it counts as finished. Answers where to go."
  def skip(user), do: finish(user, &UserOnboardings.skip/1, nil)

  defp finish(user, write, notice) do
    with {:ok, onboarding} <- ensure(user),
         {:ok, _finished} <- write(write.(onboarding)) do
      {:ok, %{"redirect" => home(user), "notice" => notice}}
    end
  end

  # ---- Payloads ----

  defp payload(onboarding, user, org) do
    role = org && org_role(org, user)

    %{
      "status" => onboarding.status,
      "step" => resume_step(onboarding.current_step),
      "capability_groups" =>
        Enum.map(@capability_groups, fn {key, keys} ->
          %{"key" => key, "capabilities" => keys}
        end),
      "capabilities" => capabilities(onboarding),
      "user" => %{"name" => user.name, "email" => user.email},
      "org" => org && %{"slug" => org.slug, "name" => org.name, "role" => role},
      "teammates" => teammates(org, user)
    }
  end

  # A record stored on the retired fourth step ("tasks") had already passed
  # integrations, so it resumes there.
  defp resume_step(step) when step in @steps, do: step
  defp resume_step("tasks"), do: "integrations"
  defp resume_step(_step), do: "capabilities"

  defp capabilities(onboarding) do
    stored = Map.take(onboarding.capabilities || %{}, @capability_keys)
    stored = for {key, value} <- stored, is_boolean(value), into: %{}, do: {key, value}
    Map.merge(@default_capabilities, stored)
  end

  defp teammates(nil, _user), do: %{"total" => 0, "sample" => []}

  defp teammates(org, user) do
    %{
      "total" => max(Memberships.count_org_members(org.id) - 1, 0),
      "sample" =>
        org.id
        |> Memberships.sample_org_members(user.id, @contact_limit)
        |> Enum.map(&contact/1)
    }
  end

  defp contact(member),
    do: %{"name" => member.user.name, "email" => member.user.email, "role" => member.role}

  defp integrations_payload(org, user) do
    project = org && Projects.default_project_for_user(org.id, user.id)

    if is_nil(project) do
      %{
        "project" => nil,
        "can_connect" => false,
        "org_admin" => false,
        "composio" => %{"status" => "ok", "configured" => false},
        "toolkits" => [],
        "messaging" => [],
        "connected_providers" => []
      }
    else
      can_connect = can_connect?(user, project)
      {configured, connections, status} = composio(org, project)

      %{
        "project" => %{"id" => project.id, "name" => project.name},
        "can_connect" => can_connect,
        "org_admin" => org_role(org, user) in ~w(owner admin),
        "composio" => %{"status" => status, "configured" => configured},
        "toolkits" =>
          Enum.map(ProjectComposioConnections.toolkits(), fn toolkit ->
            %{
              "toolkit" => toolkit,
              "state" => toolkit_state(connections, toolkit, configured, can_connect)
            }
          end),
        "messaging" => messaging(org, project),
        "connected_providers" => connections |> connected_providers() |> Enum.sort()
      }
    end
  end

  # Composio readiness is org-wide (one API key), not per toolkit.
  defp composio(org, project) do
    if ProjectComposioConnections.configured?(org.id) do
      case ProjectComposioConnections.list_connections(org.id, project.id) do
        {:ok, connections} -> {true, connections, "ok"}
        {:error, :not_configured} -> {false, [], "ok"}
        {:error, _reason} -> {true, [], "unavailable"}
      end
    else
      {false, [], "ok"}
    end
  end

  defp toolkit_state(connections, toolkit, configured, can_connect) do
    cond do
      Enum.any?(connections, &active_toolkit?(&1, toolkit)) -> "connected"
      configured and can_connect -> "connectable"
      configured -> "ask_admin"
      true -> "unconfigured"
    end
  end

  defp active_toolkit?(account, toolkit) do
    ProjectComposioConnections.connection_toolkit(account) == toolkit and
      ProjectComposioConnections.connection_active?(account)
  end

  defp messaging(org, project) do
    connects =
      case ProjectIMConnects.list_project_connects(org.id, project.id) do
        {:ok, connects} -> connects
        {:error, _reason} -> []
      end

    for provider <- ProjectIMConnects.providers() do
      %{
        "provider" => provider,
        "connected" =>
          Enum.any?(connects, fn connect ->
            connect["provider"] == provider and
              connect["status"] in ["active", "enabled", nil]
          end)
      }
    end
  end

  # Connected platforms in the profile's provider vocabulary: Composio's
  # Google toolkits all count as "google".
  defp connected_providers(connections) do
    connections
    |> Enum.filter(&ProjectComposioConnections.connection_active?/1)
    |> Enum.map(&provider(ProjectComposioConnections.connection_toolkit(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp provider(slug) when slug in ["gmail", "googlecalendar", "googledrive"], do: "google"
  defp provider(slug), do: slug

  defp profile(user, org, project) do
    connected =
      if org && project do
        {_configured, connections, _status} = composio(org, project)
        "google" in connected_providers(connections)
      else
        false
      end

    plan = %{"status" => if(connected, do: "learning", else: "planned"), "source" => "google"}

    %{
      "identity" => %{
        "name" => user.name,
        "email" => user.email,
        "role" => org && org_role(org, user),
        "org" => org && org.name
      },
      "key_contacts" =>
        if(org,
          do:
            org.id
            |> Memberships.sample_org_members(user.id, @contact_limit)
            |> Enum.map(&contact/1),
          else: []
        ),
      "work_patterns" => plan,
      "communication_style" => plan,
      "writing_style" => plan,
      "captured_at" => DateTime.to_iso8601(SystemsClock.utc_now())
    }
  end

  # ---- Helpers ----

  defp ensure(user) do
    case UserOnboardings.ensure_onboarding(user.id) do
      {:ok, onboarding} -> {:ok, onboarding}
      {:error, _reason} -> save_failed()
    end
  end

  defp write({:ok, onboarding}), do: {:ok, onboarding}
  defp write({:error, _reason}), do: save_failed()

  defp save_failed,
    do: {:error, 503, "write_failed", gettext("Could not save. Please try again."), %{}}

  defp capability_changes(changes) when is_map(changes) do
    if Enum.all?(changes, fn {key, value} -> key in @capability_keys and is_boolean(value) end),
      do: {:ok, changes},
      else: invalid_capabilities()
  end

  defp capability_changes(_changes), do: invalid_capabilities()

  defp invalid_capabilities,
    do:
      {:error, 422, "invalid_capabilities",
       gettext("Choose on or off for the listed capabilities."), %{}}

  # A user entering onboarding gets a swarm of their own when they own none.
  # Idempotent, and best effort: a failed create leaves the integrations step
  # without a swarm rather than blocking onboarding.
  defp ensure_default_swarm(org, user) do
    case Projects.ensure_owned_project(org.id, user.id, default_swarm_name(user)) do
      {:ok, _project} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "onboarding_default_swarm_failed org_id=#{org.id} user_id=#{user.id} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp default_swarm_name(%{name: name}) when is_binary(name) and name != "",
    do: gettext("%{name}'s Swarm", name: name)

  defp default_swarm_name(_user), do: gettext("My Swarm")

  defp org_role(org, user) do
    case Memberships.org_role(org.id, user.id) do
      {:ok, role} -> role
      _other -> nil
    end
  end

  # `Memberships.project_role/2` merges the explicit grant with the admin
  # role org owners and admins hold on every swarm.
  defp can_connect?(user, project),
    do: match?({:ok, "admin"}, Memberships.project_role(project.id, user.id))

  # Where `/` takes the user: their first organization, or the no-organization page.
  defp home(user) do
    case Orgs.first_org_for_user(user.id) do
      nil -> "/"
      org -> "/orgs/#{URI.encode(org.slug, &URI.char_unreserved?/1)}"
    end
  end

  defp started({:ok, %{"redirect_url" => url}}) when is_binary(url) and url != "",
    do: {:ok, %{"redirect_url" => url}}

  defp started({:ok, _payload}),
    do:
      {:error, 503, "write_failed", gettext("Could not connect the account. Please try again."),
       %{}}

  defp started({:error, :group_not_ready}),
    do:
      {:error, 409, "group_not_ready", gettext("The runtime is not ready yet. Retry shortly."),
       %{}}

  defp started({:error, :not_configured}),
    do:
      {:error, 422, "composio_not_configured",
       gettext("Composio isn't configured for your organization yet."), %{}}

  defp started({:error, {:bad_request, _detail}}),
    do:
      {:error, 422, "connection_rejected",
       gettext("The platform rejected the connection request."), %{}}

  defp started({:error, reason}) when reason in [:unavailable, :timeout],
    do:
      {:error, 503, "runtime_unavailable",
       gettext("Salix is unavailable right now. Retry shortly."), %{}}

  defp started({:error, _reason}),
    do:
      {:error, 503, "write_failed", gettext("Could not connect the account. Please try again."),
       %{}}

  defp record_denied(org, user, project, toolkit) do
    Observability.record_write_attempt(%{
      org_id: org.id,
      actor_user_id: user.id,
      actor_label: actor_label(user),
      action: "project_composio_connection.authorization_started",
      resource_type: "composio_connection",
      resource_label: project.name,
      result: "denied",
      reason: :forbidden,
      request_id: SystemsRuntime.Proc.uuid(),
      surface: "onboarding",
      metadata: %{
        "project_id" => project.id,
        "salix_group_id" => project.salix_group_id,
        "surface" => "onboarding",
        "toolkit" => toolkit
      }
    })
  end

  defp actor_label(user), do: user.email || user.name || user.id
end
