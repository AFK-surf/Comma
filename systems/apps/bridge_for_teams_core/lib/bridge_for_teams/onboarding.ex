defmodule BridgeForTeams.Onboarding do
  @moduledoc """
  First-run onboarding for the dashboard: the quick-setup checklist on the
  React Overview.

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

  Everything else on the row is UI state (dismissed/celebrated and the
  member→admin OAuth reminder).
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
  keyed by step, progress counts, and `:first_project` (the user's own Agent
  Swarm when they created one, else the first one they can see).

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
      first_project: first_project(projects, user_id),
      done_count: done_count,
      total: length(steps),
      all_done?: steps != [] and done_count == length(steps)
    }
  end

  defp first_project(projects, user_id) do
    Enum.find(projects, &(&1.created_by_user_id == user_id)) || List.first(projects)
  end

  # ---- UI state writes ----

  @doc "Skip the whole checklist for good — onboarding is over and never shows again."
  @spec dismiss(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def dismiss(org_id, user_id) do
    upsert(org_id, user_id, %{dismissed_at: now()})
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

  @doc "Acknowledge the all-done card; the checklist never shows again."
  @spec celebrate(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, MemberOnboardingState.t()} | {:error, Ecto.Changeset.t()}
  def celebrate(org_id, user_id) do
    upsert(org_id, user_id, %{celebrated_at: now()})
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
  admins on Settings → Integrations while no client is configured yet.
  `:limit` caps the number of rows.
  """
  @spec pending_oauth_reminders(Ecto.UUID.t(), keyword()) :: [
          %{user: User.t(), reminded_at: DateTime.t()}
        ]
  def pending_oauth_reminders(org_id, opts \\ []) do
    query =
      from(s in MemberOnboardingState,
        join: u in User,
        on: u.id == s.user_id,
        where: s.org_id == ^org_id and not is_nil(s.oauth_reminded_at),
        order_by: [asc: s.oauth_reminded_at, asc: s.user_id],
        select: %{user: u, reminded_at: s.oauth_reminded_at}
      )

    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) and limit > 0 -> query |> limit(^limit) |> Repo.all()
      _ -> Repo.all(query)
    end
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

  defp now, do: SystemsClock.utc_now()
end
