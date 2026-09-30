defmodule BridgeForTeams.RoutineSchedules do
  @moduledoc """
  Materialize time-shaped onboarding capability grants into real Salix
  schedules, and manage them for the New Home "Routines" widget.

  A handful of onboarding capabilities are recurring by nature — a morning
  briefing, a weekly newsletter digest, an end-of-day wrap-up. When the user
  grants one, `reconcile/4` creates a real `SalixCluster.Schedules` definition
  (through the `BridgeForTeams.Schedules` seam) owned by the project's first
  agent and records the created `schedule_id` back into the onboarding
  `capabilities` map under the reserved `"_schedules"` key, nested one level
  under the project id (`%{"_schedules" => %{project_id => %{capability =>
  schedule_id}}}`) so the same user's routines in different swarms never
  collide. That map is the grant → materialization audit for one swarm: a
  capability that is later toggled off has its schedule deleted and its audit
  entry removed, so the two never drift.
  Post-onboarding, the widget's actions keep flowing through here —
  `delete_routine/4` revokes the backing grant (and reconciles) instead of
  deleting the Salix object behind the audit's back.

  Salix schedule definitions carry no enabled/paused flag, so pause/resume is
  delete + recreate: `pause_routine/4` snapshots the definition into the
  reserved `"_paused"` capabilities key and deletes the schedule;
  `resume_routine/4` recreates it from the snapshot (capability-backed routines
  are regenerated from `capability_definitions/0`, so the fresh prompt embeds
  the fresh schedule id) and re-points the audit.

  `list_project_routines/1` lists the project's schedules and decorates each
  with a `"health"` summary derived from its `last_run` anchor and any recent
  Salix schedule-fire diagnostics (`BridgeForTeams.Observability`), so the
  widget can show whether a routine is running cleanly, has never fired, or is
  failing. `paused_routines/2` returns the user's paused snapshots in one swarm
  for the same widget.

  Schedule prompts travel to the agent as-is (this app deliberately has no
  translation dependency; the reporting contract is machine-facing English).
  Each prompt embeds its own schedule id in the artifact frontmatter. The
  artifact indexer projects the immutable file onto the board; the ordinary
  notification Message carries no workspace command.
  """

  require Logger

  alias BridgeForTeams.{
    Artifacts,
    AssistantChats,
    Observability,
    Reports,
    Schedules,
    UserOnboardings,
    WorkspaceItems
  }

  alias BridgeForTeams.Schema.{Project, UserOnboarding}
  alias SalixStore.Ids

  # Reserved keys inside `user_onboardings.capabilities`: the capability-key →
  # materialized `schedule_id` audit, and the paused-schedule snapshots keyed
  # by the deleted schedule's id. Both are nested one level under the project
  # id, so the same user's routines in different swarms never collide —
  # `%{"_schedules" => %{project_id => %{capability => schedule_id}}}` and
  # `%{"_paused" => %{project_id => %{schedule_id => entry}}}`. Kept distinct
  # from the boolean grant keys (which are all `"group.capability"` strings) so
  # the onboarding UI's grant toggles never touch them.
  @audit_key "_schedules"
  @paused_key "_paused"

  # Definition fields snapshotted on pause, mirroring the writable set in
  # `BridgeForTeams.Schedules`.
  @definition_fields ~w(prompt cron interval_minutes timezone session_id)

  @doc """
  The time-shaped capabilities that materialize into schedules, with their
  default cadence, timezone, produced-work category, and the routine the agent
  runs each fire. Only capabilities in this list are ever materialized.

  Every routine's runs are immutable Markdown files in the agent's VFS, so
  every definition must be personalized per user with `definition_for_user/2`
  before a prompt is generated (the run directory is user-namespaced). Report
  series (`category: "reports"`) additionally carry the series base name
  (`:series`) and run `:kind`; they are not part of the onboarding catalog's
  default grants — the board's report offers opt into them.
  """
  @spec capability_definitions() :: [map()]
  def capability_definitions do
    [
      %{
        key: "informed.morning_briefing",
        cron: "0 8 * * 1-5",
        timezone: "UTC",
        category: "informed",
        title: "Morning briefing",
        description: "compile a morning briefing of the user's mail, meetings, and news"
      },
      %{
        key: "informed.newsletter_digest",
        cron: "0 8 * * 1",
        timezone: "UTC",
        category: "informed",
        title: "Newsletter digest",
        description: "compile a digest of the user's newsletters from the past week"
      },
      %{
        key: "routines.scheduled",
        cron: "0 18 * * 1-5",
        timezone: "UTC",
        category: "routines",
        title: "Daily wrap-up",
        description: "compile an end-of-day wrap-up of everything that moved today"
      },
      %{
        key: "reports.daily_briefing",
        cron: "0 8 * * 1-5",
        timezone: "UTC",
        category: "reports",
        title: "Daily Briefing",
        series: "daily-briefing",
        kind: "daily",
        description: "compile a daily briefing of what needs the user's attention"
      },
      %{
        key: "reports.weekly_portfolio",
        cron: "0 9 * * 1",
        timezone: "UTC",
        category: "reports",
        title: "Weekly Portfolio Report",
        series: "weekly-portfolio",
        kind: "weekly",
        description: "compile a report of the week across the user's portfolio"
      }
    ]
  end

  @doc """
  Personalize a capability definition for the materializing user. A report
  definition gains `:series_slug` — its series base name namespaced per user by
  `BridgeForTeams.Reports.series_slug/2`, mirroring how report sites are
  namespaced — which the reports `routine_prompt/3` variant requires (report
  runs from different users of one swarm land in different series
  directories). Every other definition gains `:artifact_slug` — its title
  namespaced per user by `BridgeForTeams.Artifacts.slug/2` — which the
  artifact `routine_prompt/3` variant requires for the same reason.
  `reconcile/4` and resume apply this automatically; callers materializing a
  definition directly (e.g. the board's offer flow) must apply it first.
  """
  @spec definition_for_user(map(), String.t()) :: map()
  def definition_for_user(%{category: "reports"} = definition, user_id)
      when is_binary(user_id) do
    base = Map.get(definition, :series) || definition.title
    Map.put(definition, :series_slug, Reports.series_slug(base, user_id))
  end

  def definition_for_user(definition, user_id) when is_binary(user_id) do
    Map.put(definition, :artifact_slug, Artifacts.slug(definition.title, user_id))
  end

  @doc "The capability keys this module materializes into schedules."
  @spec materializable_keys() :: [String.t()]
  def materializable_keys, do: Enum.map(capability_definitions(), & &1.key)

  @doc """
  Reconcile the project's time-shaped schedules against `capabilities` (the
  effective grant map — the boolean keys the user landed on) and persist the
  updated audit back into `onboarding.capabilities`.

  For each materializable capability: a fresh grant (`true` with no recorded
  schedule) creates a schedule and records its id; a revoked grant (`false`
  with a recorded schedule) deletes the schedule and drops the record (any
  paused snapshot for it is dropped too); an unchanged grant is left alone
  (idempotent, so re-running never duplicates).

  Best-effort per capability — a create/delete that Salix rejects is logged and
  skipped, never blocking onboarding. Returns `{:ok, onboarding}` with the
  merged capabilities (audit under `"_schedules"`), or the persistence error.
  """
  @spec reconcile(Project.t(), UserOnboarding.t(), map(), keyword()) ::
          {:ok, UserOnboarding.t()} | {:error, term()}
  def reconcile(%Project{} = project, %UserOnboarding{} = onboarding, capabilities, opts \\ [])
      when is_map(capabilities) do
    audit = project_audit(capabilities, project.id)
    conversation_id = resolve_conversation_id(project, onboarding)

    new_audit =
      Enum.reduce(capability_definitions(), audit, fn definition, audit ->
        definition = definition_for_user(definition, onboarding.user_id)
        reconcile_one(project, definition, conversation_id, capabilities, audit, opts)
      end)

    updated =
      capabilities
      |> put_project_audit(project.id, new_audit)
      |> prune_revoked_paused(project.id)

    UserOnboardings.put_capabilities(onboarding, updated)
  end

  @doc """
  List the project's schedules, each decorated with a string-keyed `"health"`
  summary: `%{"status" => "healthy" | "pending" | "failing", "last_run" =>
  unix_ms | nil, "reason" => reason_class | nil}`.

  `"pending"` = created but never fired; `"failing"` = the most recent Salix
  diagnostic for it is a failure newer than its last successful run. Returns the
  underlying `BridgeForTeams.Schedules.list_project_schedules/1` error (e.g.
  `{:error, :unavailable}`) unchanged when Salix can't be reached.
  """
  @spec list_project_routines(Project.t()) :: {:ok, [map()]} | {:error, term()}
  def list_project_routines(%Project{} = project) do
    case Schedules.list_project_schedules(project) do
      {:ok, schedules} -> {:ok, Enum.map(schedules, &decorate_health(&1, project))}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The user's paused routine snapshots in one swarm, shaped for the widget:
  cadence fields from the stored definition plus `"id"` (the paused token — the
  schedule id it had when paused) and `"paused" => true`. Reads only the given
  project's slice, so a swarm's widget never shows another swarm's paused
  routines. Returns `[]` when there is no onboarding or no board project.
  """
  @spec paused_routines(UserOnboarding.t() | nil, Project.t() | nil) :: [map()]
  def paused_routines(onboarding, project \\ nil)

  def paused_routines(nil, _project), do: []
  def paused_routines(_onboarding, nil), do: []

  def paused_routines(%UserOnboarding{} = onboarding, %Project{} = project) do
    onboarding.capabilities
    |> project_paused(project.id)
    |> Enum.map(fn {paused_id, entry} ->
      (entry["definition"] || %{})
      |> Map.take(["cron", "interval_minutes", "timezone"])
      |> Map.merge(%{
        "id" => paused_id,
        "agent_name" => entry["agent_name"],
        "capability" => entry["capability"],
        "paused" => true
      })
    end)
    |> Enum.sort_by(& &1["id"])
  end

  @doc """
  Pause a live routine: snapshot its definition under `"_paused"` (keyed by its
  schedule id) and delete the Salix schedule — the only pause Salix supports,
  since definitions carry no enabled flag. A capability-backed routine keeps
  its grant and its audit entry (still pointing at the paused token), so
  `reconcile/4` stays idempotent while it sleeps.

  Returns `{:ok, onboarding}` with the persisted snapshot, `{:error,
  :not_found}` for an unknown/foreign schedule id, or the Salix/persistence
  error (in which case nothing was recorded).
  """
  @spec pause_routine(Project.t(), UserOnboarding.t(), String.t(), keyword()) ::
          {:ok, UserOnboarding.t()} | {:error, term()}
  def pause_routine(%Project{} = project, %UserOnboarding{} = onboarding, schedule_id, opts \\ [])
      when is_binary(schedule_id) do
    with {:ok, schedule} <- find_schedule(project, schedule_id),
         :ok <- Schedules.delete_project_schedule(project, schedule_id, opts) do
      capabilities = onboarding.capabilities

      entry = %{
        "definition" => Map.take(schedule, @definition_fields),
        "agent_id" => schedule["agent_id"],
        "agent_name" => schedule["agent_name"],
        "capability" => capability_for(capabilities, project.id, schedule_id),
        "paused_at" => System.system_time(:millisecond)
      }

      paused = capabilities |> project_paused(project.id) |> Map.put(schedule_id, entry)

      UserOnboardings.put_capabilities(
        onboarding,
        put_project_paused(capabilities, project.id, paused)
      )
    end
  end

  @doc """
  Resume a paused routine: recreate the schedule from its snapshot and drop the
  snapshot. A capability-backed routine is regenerated from
  `capability_definitions/0` (fresh prompt embedding the fresh schedule id) and
  its audit entry is re-pointed at the new id; anything else is recreated with
  its stored definition verbatim.

  Returns `{:ok, onboarding}`, `{:error, :not_found}` for an unknown paused id,
  or the Salix/persistence error (the snapshot is kept so resume can retry).
  """
  @spec resume_routine(Project.t(), UserOnboarding.t(), String.t(), keyword()) ::
          {:ok, UserOnboarding.t()} | {:error, term()}
  def resume_routine(%Project{} = project, %UserOnboarding{} = onboarding, paused_id, opts \\ [])
      when is_binary(paused_id) do
    capabilities = onboarding.capabilities
    paused = project_paused(capabilities, project.id)

    with %{} = entry <- Map.get(paused, paused_id) || {:error, :not_found},
         {:ok, schedule} <-
           recreate(
             project,
             entry,
             resolve_conversation_id(project, onboarding),
             onboarding.user_id,
             opts
           ) do
      capabilities =
        capabilities
        |> put_project_paused(project.id, Map.delete(paused, paused_id))
        |> repoint_audit(project.id, entry["capability"], schedule["id"])

      UserOnboardings.put_capabilities(onboarding, capabilities)
    end
  end

  @doc """
  Delete a routine from the widget — the post-onboarding revocation surface.

  A capability-backed routine (live or paused) has its grant flipped off and is
  reconciled, so the Salix schedule, the audit entry, and any paused snapshot
  all go together (nothing is deleted behind the audit's back). A paused
  non-capability routine just drops its snapshot (the schedule is already
  gone); a live non-capability schedule is deleted directly.
  """
  @spec delete_routine(Project.t(), UserOnboarding.t(), String.t(), keyword()) ::
          {:ok, UserOnboarding.t()} | {:error, term()}
  def delete_routine(
        %Project{} = project,
        %UserOnboarding{} = onboarding,
        schedule_id,
        opts \\ []
      )
      when is_binary(schedule_id) do
    capabilities = onboarding.capabilities
    paused = project_paused(capabilities, project.id)

    cond do
      capability = capability_for(capabilities, project.id, schedule_id) ->
        reconcile(project, onboarding, Map.put(capabilities, capability, false), opts)

      Map.has_key?(paused, schedule_id) ->
        UserOnboardings.put_capabilities(
          onboarding,
          put_project_paused(capabilities, project.id, Map.delete(paused, schedule_id))
        )

      true ->
        case Schedules.delete_project_schedule(project, schedule_id, opts) do
          ok when ok in [:ok, {:error, :not_found}] -> {:ok, onboarding}
          {:error, _reason} = error -> error
        end
    end
  end

  @doc """
  Materialize one capability definition into a live schedule for `user_id`,
  outside the onboarding grant audit. This is the board's report-offer seam:
  running a report offer creates the matching recurring series schedule
  directly and records the id on the offer row itself, so no `"_schedules"`
  audit entry is written here (the caller owns the idempotency record). The
  definition is personalized first (`definition_for_user/2` — every prompt
  requires its user-namespaced `:series_slug` / `:artifact_slug`), the prompt
  reports into
  `conversation_id` (the acting user's New Home assistant chat), and the
  created schedule's own id is stamped into its prompt exactly as
  `reconcile/4` does.

  Returns `{:ok, schedule}` (the map `BridgeForTeams.Schedules.
  create_project_schedule/3` returns, `"id"` included) or that seam's error.
  """
  @spec materialize_definition(Project.t(), map(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def materialize_definition(
        %Project{} = project,
        definition,
        user_id,
        conversation_id,
        opts \\ []
      )
      when is_binary(user_id) and is_binary(conversation_id) do
    materialize(project, definition_for_user(definition, user_id), conversation_id, opts)
  end

  @doc """
  The prompt a routine's schedule fires into its agent's inbox: what to
  produce, where to persist the immutable artifact, and where to send an
  ordinary visible notification. A schedule fire wakes the session directly —
  there is no source conversation — so the prompt names the exact
  `conversation_id` of the materializing user's per-swarm New Home assistant
  chat (resolved at stamp time via `AssistantChats.ensure_chat`). Naming the
  concrete conversation keeps each user's notification in that user's own chat
  thread. The artifact frontmatter carries schedule provenance, and the
  artifact indexer creates the board card without parsing any Message.

  Every routine is file-first: the run itself is an immutable Markdown file
  with flat frontmatter, and the Message is only a visible notification. Report definitions
  (`category: "reports"`) write under the user's series directory
  (`/.salix/reports/<series-slug>/`, slug from the personalized definition's
  `:series_slug` — see `definition_for_user/2`) with the reports frontmatter
  contract (period/kind). Every other definition writes an artifact document
  under the user's artifact directory (`/.salix/artifacts/<artifact-slug>/`,
  slug from the personalized `:artifact_slug`), embedding data-shaped content
  as fenced `bft:block` JSON segments.
  """
  @spec routine_prompt(map(), String.t(), String.t() | nil) :: String.t()
  def routine_prompt(definition, conversation_id, schedule_id \\ nil)

  def routine_prompt(%{category: "reports"} = definition, conversation_id, schedule_id)
      when is_binary(conversation_id) do
    series_slug = Map.fetch!(definition, :series_slug)
    series_dir = "/.salix/reports/#{series_slug}"
    kind = Map.get(definition, :kind, "adhoc")

    """
    You are running a recurring report for the user's New Home dashboard: #{definition.description}.

    Use your tools to gather what's needed and produce the report now.

    Step 1 — write the report file. The file is the report; nothing else stores it. Write the full report as Markdown to exactly one NEW file in your workspace:

    - Path: #{series_dir}/<YYYY-MM-DD>.md (today's date, UTC). If a file for that date already exists, never rewrite it — append the current time before the extension instead: #{series_dir}/<YYYY-MM-DD>-<HHMM>.md.
    - Begin the file with a frontmatter block delimited by `---` lines: flat `key: value` pairs, one per line, single-line plain-text values only (no nested structures). Then the full report body as plain Markdown:

    ---
    title: #{definition.title}
    kind: #{kind}
    period: <the period this run covers, e.g. 2026-07-06 or 2026-W28>
    summary: <one-line plain-text summary of this run>
    generated_at: <ISO8601 UTC timestamp>#{schedule_id_frontmatter(schedule_id)}
    ---

    - If you also publish an HTML companion site under /.salix/websites/, add a `site: <site name>` line to the frontmatter.

    Step 2 — notify the user. Post one ordinary visible summary into the user's New Home assistant conversation (conversation_id "#{conversation_id}") with your call_im_provider_api tool:

    {"provider": "internal", "connect_id": "internal", "api": "internal.send_message", "conversation_id": "#{conversation_id}", "content": [{"type": "text", "text": "<the one-line summary and the exact artifact path>"}]}

    Plain assistant text reaches nobody — always report via that tool call.

    Rules:
    - The file is the artifact and the artifact indexer creates the board card from its frontmatter. The Message is only a notification; never put lifecycle, workspace, or artifact-index commands in internal.send_message.#{schedule_id_rule(schedule_id)}
    """
    |> String.trim()
  end

  # Non-report routines are artifact-first: each run is an immutable Markdown
  # document (flat frontmatter, data-shaped content as fenced bft:block JSON)
  # under the user's artifact directory; the Message is only a notification.
  def routine_prompt(definition, conversation_id, schedule_id)
      when is_binary(conversation_id) do
    artifact_dir = definition |> Map.fetch!(:artifact_slug) |> Artifacts.dir()

    """
    You are running a recurring routine for the user's New Home dashboard: #{definition.description}.

    Use your tools to gather what's needed and produce the result now.

    Step 1 — write the artifact file. The file is the artifact; nothing else stores it. Write the full result as Markdown to exactly one NEW file in your workspace:

    - Path: #{artifact_dir}/<YYYY-MM-DD>.md (today's date, UTC). If a file for that date already exists, never rewrite it — append the current time before the extension instead: #{artifact_dir}/<YYYY-MM-DD>-<HHMM>.md.
    - Begin the file with a frontmatter block delimited by `---` lines: flat `key: value` pairs, one per line, single-line plain-text values only (no nested structures). Then the full body as plain Markdown:

    ---
    title: #{definition.title}
    category: #{routine_artifact_category(definition)}
    kind: <report|brief|recap|draft|dataset|note>
    summary: <one-line plain-text summary of this run>
    generated_at: <ISO8601 UTC timestamp>#{schedule_id_frontmatter(schedule_id)}
    ---

    - Wherever the content is data-shaped, emit it in the body as a fenced block instead of prose:

    ```bft:block
    {"type": "kpis", "items": [{"label": "…", "value": "…"}]}
    ```

    Block vocabulary — one JSON object per fence, always "type" plus "items" (the block key is "type", NOT "kind" — "kind" belongs to the frontmatter; an optional "title" captions the block): kpis (items of label/value with optional delta/note), table ("columns", not "headers", plus rows), list (optional style plain|risks|actions|watch, string items), links (title/url), timeline (date/event), entities (name with optional detail).

    Step 2 — notify the user. Post one ordinary visible summary into the user's New Home assistant conversation (conversation_id "#{conversation_id}") with your call_im_provider_api tool:

    {"provider": "internal", "connect_id": "internal", "api": "internal.send_message", "conversation_id": "#{conversation_id}", "content": [{"type": "text", "text": "<the one-line summary and the exact artifact path>"}]}

    Plain assistant text reaches nobody — always report via that tool call.

    Rules:
    - The file is the artifact and the artifact indexer creates the board card from its frontmatter. The Message is only a notification; never put lifecycle, workspace, or artifact-index commands in internal.send_message.#{schedule_id_rule(schedule_id)}
    """
    |> String.trim()
  end

  defp routine_artifact_category(%{category: category}) when is_binary(category) do
    if category != "reports" and category in WorkspaceItems.categories(),
      do: category,
      else: "general"
  end

  defp routine_artifact_category(_definition), do: "general"

  defp schedule_id_frontmatter(schedule_id) do
    case canonical_schedule_id(schedule_id) do
      nil -> ""
      schedule_id -> "\nschedule_id: #{schedule_id}"
    end
  end

  defp schedule_id_rule(schedule_id) do
    if canonical_schedule_id(schedule_id) do
      "\n- Keep the schedule_id frontmatter line exactly as given; it links the indexed artifact back to this routine."
    else
      ""
    end
  end

  defp canonical_schedule_id(schedule_id) when is_binary(schedule_id) do
    schedule_id = String.trim(schedule_id)
    if Ids.valid_schedule_id?(schedule_id), do: schedule_id
  end

  defp canonical_schedule_id(_schedule_id), do: nil

  # ---- internal: reconciliation ----

  defp reconcile_one(project, definition, conversation_id, capabilities, audit, opts) do
    granted? = capabilities[definition.key] == true
    existing = Map.get(audit, definition.key)

    cond do
      granted? and not is_binary(existing) ->
        create(project, definition, conversation_id, audit, opts)

      not granted? and is_binary(existing) ->
        delete(project, definition, existing, audit, opts)

      true ->
        audit
    end
  end

  # No resolved conversation (the user's assistant chat could not be created or
  # bound) means the routine would have nowhere to report — skip the create and
  # leave the audit untouched so a later reconcile with a live chat materializes
  # it. Deletes are unaffected: they never need a conversation.
  defp create(_project, definition, nil, audit, _opts) do
    Logger.warning("routine_schedule_create_skipped_no_conversation capability=#{definition.key}")
    audit
  end

  defp create(project, definition, conversation_id, audit, opts)
       when is_binary(conversation_id) do
    case materialize(project, definition, conversation_id, opts) do
      {:ok, schedule} ->
        Map.put(audit, definition.key, schedule["id"])

      {:error, reason} ->
        Logger.warning(
          "routine_schedule_create_failed capability=#{definition.key} project_id=#{project.id} reason=#{inspect(reason)}"
        )

        audit
    end
  end

  # Create the capability's schedule, then stamp its own id into the prompt's
  # reporting contract (two-phase: Salix assigns the id at create time). A
  # failed stamp is logged, not fatal — the routine still runs, its cards just
  # lack the schedule-id provenance until the prompt is next updated.
  defp materialize(project, definition, conversation_id, opts, extra_attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          "prompt" => routine_prompt(definition, conversation_id),
          "cron" => definition.cron,
          "timezone" => definition.timezone
        },
        extra_attrs
      )

    with {:ok, schedule} <- Schedules.create_project_schedule(project, attrs, opts) do
      stamp_prompt(project, definition, conversation_id, schedule["id"], opts)
      {:ok, schedule}
    end
  end

  defp stamp_prompt(project, definition, conversation_id, schedule_id, opts) do
    case Schedules.update_project_schedule(
           project,
           schedule_id,
           %{"prompt" => routine_prompt(definition, conversation_id, schedule_id)},
           opts
         ) do
      {:ok, _schedule} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "routine_schedule_prompt_stamp_failed schedule_id=#{schedule_id} project_id=#{project.id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp delete(project, definition, schedule_id, audit, opts) do
    case Schedules.delete_project_schedule(project, schedule_id, opts) do
      :ok ->
        Map.delete(audit, definition.key)

      # The schedule is already gone (paused, deleted directly, or never
      # landed) — drop the stale audit entry so a later re-grant materializes a
      # fresh one.
      {:error, :not_found} ->
        Map.delete(audit, definition.key)

      {:error, reason} ->
        Logger.warning(
          "routine_schedule_delete_failed capability=#{definition.key} project_id=#{project.id} reason=#{inspect(reason)}"
        )

        audit
    end
  end

  # ---- internal: pause/resume ----

  defp find_schedule(project, schedule_id) do
    with {:ok, schedules} <- Schedules.list_project_schedules(project) do
      case Enum.find(schedules, &(&1["id"] == schedule_id)) do
        nil -> {:error, :not_found}
        schedule -> {:ok, schedule}
      end
    end
  end

  defp recreate(project, entry, conversation_id, user_id, opts) do
    case definition_for_capability(entry["capability"]) do
      # Capability-backed routines are regenerated from the catalog
      # (re-personalized for the resuming user, so the fresh prompt keeps the
      # same user-namespaced series/artifact slug), and the fresh prompt must
      # re-embed the user's assistant-chat conversation id; without one there
      # is nowhere to report, so resume is deferred.
      %{} = definition when is_binary(conversation_id) ->
        materialize(
          project,
          definition_for_user(definition, user_id),
          conversation_id,
          opts,
          %{"agent_id" => entry["agent_id"]}
        )

      %{} ->
        {:error, :no_conversation}

      # A non-capability routine is recreated from its stored definition
      # verbatim — the snapshot already carries the prompt it was paused with.
      nil ->
        attrs =
          (entry["definition"] || %{})
          |> Map.take(@definition_fields)
          |> Map.put("agent_id", entry["agent_id"])

        Schedules.create_project_schedule(project, attrs, opts)
    end
  end

  # The materializing user's per-swarm New Home assistant chat conversation id,
  # created on first use. Every routine this user materializes in `project`
  # reports into that one conversation, so N users of a swarm keep separate
  # threads. Best-effort: an unresolved chat (no agent, Salix outage) yields
  # `nil`, which defers create/resume rather than blocking the reconcile.
  defp resolve_conversation_id(%Project{} = project, %UserOnboarding{user_id: user_id}) do
    case AssistantChats.ensure_chat(user_id, project.org_id, project) do
      {:ok, %{binding: %{conversation_id: conversation_id}}}
      when is_binary(conversation_id) ->
        conversation_id

      other ->
        Logger.warning(
          "routine_conversation_resolve_failed user_id=#{user_id} project_id=#{project.id} reason=#{inspect(other)}"
        )

        nil
    end
  end

  defp definition_for_capability(nil), do: nil

  defp definition_for_capability(capability),
    do: Enum.find(capability_definitions(), &(&1.key == capability))

  defp repoint_audit(capabilities, _project_id, nil, _schedule_id), do: capabilities

  defp repoint_audit(capabilities, project_id, capability, schedule_id) do
    audit = capabilities |> project_audit(project_id) |> Map.put(capability, schedule_id)
    put_project_audit(capabilities, project_id, audit)
  end

  defp capability_for(capabilities, project_id, schedule_id) do
    capabilities
    |> project_audit(project_id)
    |> Enum.find_value(fn {key, id} -> id == schedule_id && key end)
  end

  # A revoked capability takes its paused snapshot with it, so a later re-grant
  # starts from the catalog default instead of a stale sleeping copy. Scoped to
  # the project's own paused slice.
  defp prune_revoked_paused(capabilities, project_id) do
    paused =
      capabilities
      |> project_paused(project_id)
      |> Enum.reject(fn {_id, entry} ->
        is_binary(entry["capability"]) and capabilities[entry["capability"]] != true
      end)
      |> Map.new()

    put_project_paused(capabilities, project_id, paused)
  end

  # ---- internal: per-project audit/paused slices ----

  # The `%{capability => schedule_id}` audit for one project (empty when the
  # user has never materialized a routine in that swarm).
  defp project_audit(capabilities, project_id),
    do: project_slice(capabilities, @audit_key, project_id)

  # The `%{schedule_id => entry}` paused snapshots for one project.
  defp project_paused(capabilities, project_id),
    do: project_slice(capabilities, @paused_key, project_id)

  defp project_slice(capabilities, key, project_id) do
    with outer when is_map(outer) <- Map.get(capabilities, key),
         inner when is_map(inner) <- Map.get(outer, project_id) do
      inner
    else
      _ -> %{}
    end
  end

  defp put_project_audit(capabilities, project_id, audit),
    do: put_project_slice(capabilities, @audit_key, project_id, audit)

  defp put_project_paused(capabilities, project_id, paused),
    do: put_project_slice(capabilities, @paused_key, project_id, paused)

  defp put_project_slice(capabilities, key, project_id, slice) do
    outer =
      case Map.get(capabilities, key) do
        outer when is_map(outer) -> outer
        _ -> %{}
      end

    Map.put(capabilities, key, Map.put(outer, project_id, slice))
  end

  # ---- internal: health ----

  defp decorate_health(schedule, %Project{} = project) do
    events =
      Observability.list_events(project.org_id,
        domain: "schedule",
        resource_type: "project_schedule",
        resource_id: schedule["id"],
        limit: 5
      )

    last_run = schedule["last_run"]
    latest_failure = Enum.find(events, &(&1.status == "failed"))

    status =
      cond do
        failure_after_last_run?(latest_failure, last_run) -> "failing"
        is_integer(last_run) -> "healthy"
        true -> "pending"
      end

    Map.put(schedule, "health", %{
      "status" => status,
      "last_run" => last_run,
      "reason" => latest_failure && latest_failure.reason_class
    })
  end

  defp failure_after_last_run?(nil, _last_run), do: false
  defp failure_after_last_run?(_event, nil), do: true

  defp failure_after_last_run?(event, last_run) when is_integer(last_run) do
    DateTime.to_unix(event.occurred_at, :millisecond) > last_run
  end
end
