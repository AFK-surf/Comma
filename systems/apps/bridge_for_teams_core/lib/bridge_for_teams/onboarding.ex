defmodule BridgeForTeams.Onboarding do
  @moduledoc """
  First-run onboarding for the dashboard: the welcome modal, the floating
  quick-setup checklist, and the guided tour.

  The flow has three steps — create an Agent Swarm, configure an org OAuth
  client, connect a third-party account. Org owners/admins get all three;
  ordinary members get two (OAuth config is admin-only, so for them it appears
  only as a "waiting for an admin" blocker on the connect step).

  Step completion is **derived from real data**, never stored:

    * `swarm`   — the user can see at least one Agent Swarm in the org
      (`Projects.list_projects_for_user/2`), i.e. they created one or were
      granted access to one.
    * `oauth`   — the org has at least one OAuth provider app ready for
      authorization (`ProjectOAuthConnections.list_available_providers/1`
      returns supported providers with readiness). The answer comes from the
      Salix runtime, so it is cached briefly; writers call
      `invalidate_oauth_cache/1`.
    * `connect` — cached in `connected_at` on the state row the first time a
      connected account is observed for the user (see
      `Schema.MemberOnboardingState`).

  A step the user explicitly skipped (`skipped_steps`) also counts as done —
  skipping is waiving the step, not postponing it. Likewise, dismissing the
  checklist ends onboarding for good; there is no resume entry point.

  Everything else on the row is UI state (seen/dismissed/collapsed/celebrated,
  the tour's active step, and the member→admin OAuth reminder).
  """
  import Ecto.Query

  alias BridgeForTeams.{Cache, Projects, Repo}
  alias BridgeForTeams.ProjectOAuthConnections
  alias BridgeForTeams.Schema.MemberOnboardingState
  alias BridgeForTeams.Schema.User

  @admin_steps ~w(swarm oauth connect)
  @member_steps ~w(swarm connect)
  @oauth_cache_ttl_ms 60_000

  @doc "The ordered checklist steps for an org role."
  @spec steps_for_role(String.t() | nil) :: [String.t()]
  def steps_for_role(role) when role in ["owner", "admin"], do: @admin_steps
  def steps_for_role("member"), do: @member_steps
  def steps_for_role(_), do: []

  @doc "Fetch the stored UI state, or a default (unsaved) state."
  @spec get_state(Ecto.UUID.t(), Ecto.UUID.t()) :: MemberOnboardingState.t()
  def get_state(org_id, user_id) do
    Repo.get_by(MemberOnboardingState, org_id: org_id, user_id: user_id) ||
      %MemberOnboardingState{org_id: org_id, user_id: user_id}
  end

  @doc """
  Derive the full onboarding picture for a user in an org.

  Returns a map with the stored `:state`, the role's `:steps`, a `:done` map
  keyed by step, the effective `:active_step` (the stored one, advanced past
  steps that are already done), progress counts, and `:first_project` (the
  user's own Agent Swarm when they created one, else the first one they can
  see) for tour navigation.

  Options: `:refresh_oauth` — drop the cached OAuth-configured answer first;
  `:state` — reuse an already-fetched state row.
  """
  @spec snapshot(struct(), Ecto.UUID.t(), String.t() | nil, keyword()) :: map()
  def snapshot(org, user_id, role, opts \\ []) do
    state = Keyword.get(opts, :state) || get_state(org.id, user_id)
    steps = steps_for_role(role)

    if Keyword.get(opts, :refresh_oauth, false), do: invalidate_oauth_cache(org.id)

    projects = Projects.list_projects_for_user(org.id, user_id)
    oauth_configured = oauth_configured?(org.id)
    skipped = state.skipped_steps || []

    done = %{
      "swarm" => projects != [] or "swarm" in skipped,
      "oauth" => oauth_configured or "oauth" in skipped,
      "connect" => not is_nil(state.connected_at) or "connect" in skipped
    }

    done_count = Enum.count(steps, &done[&1])

    %{
      state: state,
      steps: steps,
      done: done,
      oauth_configured: oauth_configured,
      active_step: effective_active_step(state.active_step, steps, done),
      first_project: first_project(projects, user_id),
      done_count: done_count,
      total: length(steps),
      all_done?: steps != [] and done_count == length(steps)
    }
  end

  # The stored active step may point at a step that has since been completed
  # (completion is derived, not evented) — advance to the next undone step so
  # the tour flows through the checklist without extra writes.
  defp effective_active_step(nil, _steps, _done), do: nil

  defp effective_active_step(step, steps, done) do
    if step in steps and not done[step] do
      step
    else
      steps
      |> Enum.drop_while(&(&1 != step))
      |> Enum.concat(steps)
      |> Enum.reject(&done[&1])
      |> List.first()
    end
  end

  defp first_project(projects, user_id) do
    Enum.find(projects, &(&1.created_by_user_id == user_id)) || List.first(projects)
  end

  @doc "The first undone step for a role, given a snapshot-style done map."
  @spec first_undone([String.t()], map()) :: String.t() | nil
  def first_undone(steps, done), do: Enum.find(steps, &(!done[&1]))

  # ---- UI state writes ----

  @doc "Record that the welcome modal was answered. `active_step` starts the tour."
  @spec mark_welcome_seen(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def mark_welcome_seen(org_id, user_id, opts \\ []) do
    upsert(org_id, user_id, %{
      welcome_seen_at: now(),
      collapsed: Keyword.get(opts, :collapsed, false),
      active_step: Keyword.get(opts, :active_step)
    })
  end

  @doc "Skip the whole checklist for good — onboarding is over and never shows again."
  @spec dismiss(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def dismiss(org_id, user_id) do
    upsert(org_id, user_id, %{dismissed_at: now(), active_step: nil})
  end

  @doc """
  Mark a step as explicitly skipped — it counts as done from then on.
  Idempotent.
  """
  @spec skip_step(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def skip_step(org_id, user_id, step) do
    state = get_state(org_id, user_id)
    upsert(org_id, user_id, %{skipped_steps: Enum.uniq([step | state.skipped_steps || []])})
  end

  @doc "Expand the checklist again, pointing the tour at `active_step`."
  @spec resume(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def resume(org_id, user_id, active_step) do
    upsert(org_id, user_id, %{dismissed_at: nil, collapsed: false, active_step: active_step})
  end

  @doc "Collapse/expand the floating checklist."
  @spec set_collapsed(Ecto.UUID.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def set_collapsed(org_id, user_id, collapsed) when is_boolean(collapsed) do
    upsert(org_id, user_id, %{collapsed: collapsed})
  end

  @doc "Point the guided tour at a step (nil exits the tour)."
  @spec set_active_step(Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def set_active_step(org_id, user_id, step) do
    upsert(org_id, user_id, %{active_step: step})
  end

  @doc "Acknowledge the all-done card; the checklist never shows again."
  @spec celebrate(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def celebrate(org_id, user_id) do
    upsert(org_id, user_id, %{celebrated_at: now(), active_step: nil})
  end

  @doc "Cache that the user has a connected account (connect step done)."
  @spec mark_connected(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def mark_connected(org_id, user_id) do
    upsert(org_id, user_id, %{connected_at: now()})
  end

  @doc """
  Record the connect step as done the first time a non-empty connections list
  is observed for the user. Idempotent; no-op once set.
  """
  @spec observe_connected(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def observe_connected(org_id, user_id) do
    case get_state(org_id, user_id) do
      %{connected_at: %DateTime{}} ->
        :ok

      _ ->
        _ = mark_connected(org_id, user_id)
        :ok
    end
  end

  @doc "Member asks org admins to configure OAuth clients. Idempotent."
  @spec remind_admins(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def remind_admins(org_id, user_id) do
    case get_state(org_id, user_id) do
      %{oauth_reminded_at: %DateTime{}} = state -> {:ok, state}
      _ -> upsert(org_id, user_id, %{oauth_reminded_at: now()})
    end
  end

  @doc """
  Members who asked for OAuth configuration, oldest first. Surfaced to org
  admins on Settings → OAuth apps while no client is configured yet.
  """
  @spec pending_oauth_reminders(Ecto.UUID.t()) :: [%{user: User.t(), reminded_at: DateTime.t()}]
  def pending_oauth_reminders(org_id) do
    from(s in MemberOnboardingState,
      join: u in User,
      on: u.id == s.user_id,
      where: s.org_id == ^org_id and not is_nil(s.oauth_reminded_at),
      order_by: [asc: s.oauth_reminded_at],
      select: %{user: u, reminded_at: s.oauth_reminded_at}
    )
    |> Repo.all()
  end

  @doc "Drop the cached OAuth-configured answer (call after saving/removing an OAuth app)."
  @spec invalidate_oauth_cache(Ecto.UUID.t()) :: :ok
  def invalidate_oauth_cache(org_id), do: Cache.delete(oauth_cache_key(org_id))

  @doc """
  Whether the org has any OAuth provider app configured. The source of truth
  lives in the Salix runtime, so the answer is cached briefly; a runtime error
  degrades to `false` without caching, so the next check retries. Also feeds
  the dashboard's global "members are waiting for OAuth" admin alert.
  """
  @spec oauth_configured?(Ecto.UUID.t()) :: boolean()
  def oauth_configured?(org_id) do
    key = oauth_cache_key(org_id)

    case Cache.get(key) do
      {:ok, value} ->
        value

      :error ->
        case safe_list_providers(org_id) do
          {:ok, providers} ->
            configured =
              Enum.any?(providers, &ProjectOAuthConnections.provider_authorization_ready?/1)

            Cache.put(key, configured, ttl: @oauth_cache_ttl_ms)
            configured

          {:error, _reason} ->
            false
        end
    end
  end

  # The onboarding checklist rides along on every dashboard page, so a broken
  # or partially-stubbed Salix runtime must degrade to "not configured yet"
  # rather than take the page down.
  defp safe_list_providers(org_id) do
    ProjectOAuthConnections.list_available_providers(org_id)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp oauth_cache_key(org_id), do: {:onboarding_oauth_configured, org_id}

  defp upsert(org_id, user_id, changes) do
    case Repo.get_by(MemberOnboardingState, org_id: org_id, user_id: user_id) do
      nil ->
        %MemberOnboardingState{}
        |> MemberOnboardingState.changeset(
          Map.merge(%{org_id: org_id, user_id: user_id}, changes)
        )
        |> Repo.insert(
          on_conflict: {:replace, Map.keys(changes) ++ [:updated_at]},
          conflict_target: [:org_id, :user_id],
          returning: true
        )

      state ->
        state
        |> MemberOnboardingState.changeset(changes)
        |> Repo.update()
    end
  end

  defp now, do: DateTime.utc_now()
end
