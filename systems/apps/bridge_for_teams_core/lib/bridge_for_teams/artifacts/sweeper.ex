defmodule BridgeForTeams.Artifacts.Sweeper do
  @moduledoc """
  Bounded indexer for immutable VFS artifact documents.

  Agents write documents under `#{BridgeForTeams.Reports.root()}/<series-slug>/`
  (report runs) or `#{BridgeForTeams.Artifacts.root()}/<slug>/` (general
  artifacts). Conversation-backed work may already have a canonical workspace
  projection for the same file; scheduled work instead carries its workspace
  category and canonical schedule id in flat document frontmatter. This
  sweeper creates only the missing local index rows and never interprets
  Messages as workspace commands.

  Each pass claims one shared Postgres cursor and walks a bounded agent page.
  Per-agent directory and file cursors cap Salix fan-out without starving later
  paths. The worker lists both roots and diffs the document files it finds
  against local workspace item artifact pointers. Only an unindexed document
  costs anything more: the file is read (short workspace timeout), a bounded
  frontmatter prefix is parsed, and a `source: "agent"` workspace item is
  created for the owning user via `WorkspaceItems.create_tasks/4`. Report-root
  files project as `"reports"`; artifact-root files accept a valid non-report
  workspace category and otherwise fall back to `"general"`.

  The owning user is resolved from the slug itself: report series slugs and
  artifact slugs are per-user-namespaced with
  `BridgeForTeams.Artifacts.user_suffix/1`, so the slug's suffix is matched
  through an indexed suffix lookup constrained to eligible project members
  (explicit ACL grants first, then org owners/admins, who reach every swarm
  without a project ACL row). Shared visibility fans out through a durable
  per-document member cursor, so each pass reads and writes only a fixed-size
  member page. A slug no member matches is skipped with a `Logger` line and
  retried next sweep.

  Freshly written documents without a canonical `schedule_id` are left alone
  for a grace window (default 10 minutes — one sweep interval), allowing an
  in-flight Conversation projection to claim the file first. Scheduled files
  are the normal indexing path and bypass that delay. An entry without a usable
  `modified_at` counts as old.

  Salix being unreachable (`:unavailable` / `:timeout`) silently costs the
  affected reads, not the process; a later full cursor cycle retries them. Any
  other surprise is rescued and logged. An expiring database lease recovers a
  pass after process death, and the payload-owner artifact identity unique
  index makes replay safe.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2, limit: 2, order_by: 3, where: 3]

  alias BridgeForTeams.Artifacts
  alias BridgeForTeams.Artifacts.Frontmatter
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Reports
  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Agent, ArtifactSweepScan, Project, WorkspaceItem}
  alias BridgeForTeams.Telemetry
  alias BridgeForTeams.WorkspaceItems
  alias SalixStore.Ids

  @scan_id "bridge-artifact-sweep"
  @default_sweep_interval_ms 600_000
  @default_grace_ms 600_000
  @default_agent_batch_size 10
  @default_directory_batch_size 25
  @default_file_batch_size 100
  @default_member_batch_size 100
  @default_lease_ttl_ms 300_000
  @frontmatter_max_bytes 16_384
  @transient [:unavailable, :timeout]

  # ---- client API -----------------------------------------------------------

  @doc """
  Start the sweeper. Options (all optional):

    * `:name` — registered name (default `#{inspect(__MODULE__)}`)
    * `:sweep_interval_ms` — periodic sweep cadence (default #{@default_sweep_interval_ms})
    * `:grace_ms` — how young (by `modified_at`) a document may be and still
      be skipped as likely in-flight (default #{@default_grace_ms})
    * `:agent_batch_size` — maximum agents visited per pass
    * `:directory_batch_size` — maximum document directories visited per agent/pass
    * `:file_batch_size` — maximum document files visited per directory/pass
    * `:member_batch_size` — maximum eligible users visited for one document/pass
    * `:lease_ttl_ms` — shared claim expiry for crash recovery
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Run one sweep synchronously (returns how many index rows were created). Test seam."
  @spec sweep_once(GenServer.server()) :: non_neg_integer()
  def sweep_once(server \\ __MODULE__) do
    GenServer.call(server, :sweep, 60_000)
  end

  # ---- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    grace = Keyword.get(opts, :grace_ms, @default_grace_ms)

    # Jittered first sweep: nodes booted together spread their Salix fan-outs
    # across the whole interval instead of sweeping in lockstep.
    schedule_sweep(:rand.uniform(interval))

    {:ok,
     %{
       interval_ms: interval,
       grace_ms: grace,
       agent_batch_size: positive(opts[:agent_batch_size], @default_agent_batch_size),
       directory_batch_size: positive(opts[:directory_batch_size], @default_directory_batch_size),
       file_batch_size: positive(opts[:file_batch_size], @default_file_batch_size),
       member_batch_size: positive(opts[:member_batch_size], @default_member_batch_size),
       lease_ttl_ms: positive(opts[:lease_ttl_ms], @default_lease_ttl_ms)
     }}
  end

  @impl true
  def handle_call(:sweep, _from, state) do
    {:reply, sweep(state), state}
  end

  @impl true
  def handle_info(:sweep, state) do
    _created = sweep(state)
    schedule_sweep(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---- sweep ------------------------------------------------------------------

  defp sweep(state) do
    started = System.monotonic_time()
    now_ms = System.system_time(:millisecond)
    cutoff = div(now_ms, 1000) - div(state.grace_ms, 1000)

    case claim_scan(now_ms, state.lease_ttl_ms) do
      {:ok, claim} ->
        try do
          {created, progress} = sweep_claimed(claim, state, cutoff)
          :ok = acknowledge_scan(claim, progress)

          Telemetry.emit_operation(:artifact_sweep, "ok", System.monotonic_time() - started)

          created
        rescue
          _exception ->
            _ = release_scan(claim)
            Telemetry.emit_operation(:artifact_sweep, "error", System.monotonic_time() - started)
            Logger.warning("artifacts_sweep_failed", error_class: "internal")
            0
        end

      :busy ->
        0
    end
  end

  defp sweep_claimed(claim, state, cutoff) do
    rows = agent_page(claim, state.agent_batch_size)

    Enum.reduce_while(
      rows,
      {0,
       %{
         cursor_agent_id: claim.cursor_agent_id,
         active_agent_id: claim.active_agent_id,
         directory_cursor: claim.directory_cursor,
         file_cursor: claim.file_cursor,
         active_document_path: claim.active_document_path,
         member_cursor_user_id: claim.member_cursor_user_id
       }},
      fn {project, agent}, {created, progress} ->
        {directory_cursor, file_cursor, active_document_path, member_cursor_user_id} =
          if progress.active_agent_id == agent.id do
            {
              progress.directory_cursor,
              progress.file_cursor,
              progress.active_document_path,
              progress.member_cursor_user_id
            }
          else
            {nil, nil, nil, nil}
          end

        case sweep_agent(
               project,
               agent,
               cutoff,
               directory_cursor,
               file_cursor,
               active_document_path,
               member_cursor_user_id,
               state
             ) do
          {:complete, count} ->
            {:cont,
             {created + count,
              %{
                cursor_agent_id: agent.id,
                active_agent_id: nil,
                directory_cursor: nil,
                file_cursor: nil,
                active_document_path: nil,
                member_cursor_user_id: nil
              }}}

          {:partial, count, next_directory_cursor, next_file_cursor, document_path,
           next_member_cursor} ->
            {:halt,
             {created + count,
              %{
                cursor_agent_id: claim.cursor_agent_id,
                active_agent_id: agent.id,
                directory_cursor: next_directory_cursor,
                file_cursor: next_file_cursor,
                active_document_path: document_path,
                member_cursor_user_id: next_member_cursor
              }}}
        end
      end
    )
  end

  defp agent_page(
         %ArtifactSweepScan{
           active_agent_id: active_agent_id,
           cursor_agent_id: cursor_agent_id
         },
         limit
       )
       when is_binary(active_agent_id) do
    case agent_query()
         |> where([agent, _project], agent.id == ^active_agent_id)
         |> Repo.all() do
      [] ->
        agent_page(
          %ArtifactSweepScan{cursor_agent_id: cursor_agent_id, active_agent_id: nil},
          limit
        )

      rows ->
        rows
    end
  end

  defp agent_page(%ArtifactSweepScan{cursor_agent_id: cursor}, limit) do
    query = agent_query() |> order_by([agent, _project], asc: agent.id) |> limit(^limit)

    rows =
      if is_binary(cursor) do
        query
        |> where([agent, _project], agent.id > ^cursor)
        |> Repo.all()
      else
        Repo.all(query)
      end

    if rows == [] and is_binary(cursor), do: Repo.all(query), else: rows
  end

  defp agent_query do
    from(a in Agent,
      join: p in Project,
      on: p.id == a.project_id,
      where: not is_nil(a.salix_agent_id) and is_nil(p.archived_at),
      select: {p, a}
    )
  end

  defp sweep_agent(
         project,
         agent,
         cutoff,
         directory_cursor,
         file_cursor,
         active_document_path,
         member_cursor_user_id,
         state
       ) do
    case BridgeForTeams.Agents.resolve_agent(agent) do
      {:ok, resolved} ->
        if BridgeForTeams.Schema.Agent.active?(resolved) do
          sweep_resolved_agent(
            project,
            resolved,
            cutoff,
            directory_cursor,
            file_cursor,
            active_document_path,
            member_cursor_user_id,
            state
          )
        else
          {:complete, 0}
        end

      {:error, :not_found} ->
        {:complete, 0}

      {:error, reason} ->
        raise "Agent authority unavailable: #{inspect(reason)}"
    end
  end

  defp sweep_resolved_agent(
         project,
         agent,
         cutoff,
         directory_cursor,
         file_cursor,
         active_document_path,
         member_cursor_user_id,
         state
       ) do
    directories =
      agent
      |> document_directories()
      |> Enum.sort_by(& &1.path)
      |> Enum.filter(&after_cursor?(&1.path, directory_cursor))

    selected = Enum.take(directories, state.directory_batch_size)

    case sweep_directories(
           project,
           selected,
           cutoff,
           directory_cursor,
           file_cursor,
           active_document_path,
           member_cursor_user_id,
           state.file_batch_size,
           state.member_batch_size
         ) do
      {:partial, created, next_directory_cursor, next_file_cursor, document_path,
       next_member_cursor} ->
        {:partial, created, next_directory_cursor, next_file_cursor, document_path,
         next_member_cursor}

      {:complete, created, next_directory_cursor} ->
        if length(directories) > length(selected) do
          {:partial, created, next_directory_cursor, nil, nil, nil}
        else
          {:complete, created}
        end
    end
  end

  # A document younger than the grace window gets one bounded frontmatter
  # probe. A canonical schedule id makes it normal scheduled output and indexes
  # it immediately; otherwise an in-flight Conversation projection gets the
  # grace period to claim the file first. `modified_at` is epoch seconds
  # (`SalixAgent.Workspace`); an entry without a usable timestamp counts as old.
  defp young_document?(%{entry: %{"modified_at" => modified_at}}, cutoff)
       when is_integer(modified_at),
       do: modified_at > cutoff

  defp young_document?(_doc, _cutoff), do: false

  defp sweep_directories(
         project,
         directories,
         cutoff,
         directory_cursor,
         file_cursor,
         active_document_path,
         member_cursor_user_id,
         file_batch_size,
         member_batch_size
       ) do
    Enum.reduce_while(
      directories,
      {:complete, 0, directory_cursor, file_cursor, active_document_path, member_cursor_user_id},
      fn directory,
         {:complete, created, completed_directory, resume_file_cursor, resume_document_path,
          resume_member_cursor} ->
        documents =
          directory
          |> directory_documents()
          |> Enum.sort_by(& &1.entry["path"])
          |> Enum.filter(&after_cursor?(&1.entry["path"], resume_file_cursor))

        selected = Enum.take(documents, file_batch_size)

        case sweep_documents(
               project,
               selected,
               cutoff,
               resume_file_cursor,
               resume_document_path,
               resume_member_cursor,
               member_batch_size
             ) do
          {:partial, count, completed_file, document_path, next_member_cursor} ->
            {:halt,
             {:partial, created + count, completed_directory, completed_file, document_path,
              next_member_cursor}}

          {:complete, count, completed_file} ->
            if length(documents) > length(selected) do
              {:halt, {:partial, created + count, completed_directory, completed_file, nil, nil}}
            else
              {:cont, {:complete, created + count, directory.path, nil, nil, nil}}
            end
        end
      end
    )
    |> case do
      {:complete, created, completed_directory, nil, nil, nil} ->
        {:complete, created, completed_directory}

      other ->
        other
    end
  end

  defp sweep_documents(
         project,
         documents,
         cutoff,
         file_cursor,
         active_document_path,
         member_cursor_user_id,
         member_batch_size
       ) do
    Enum.reduce_while(
      documents,
      {:complete, 0, file_cursor},
      fn doc, {:complete, created, completed_file} ->
        path = doc.entry["path"]
        resume_member_cursor = if active_document_path == path, do: member_cursor_user_id

        case document_sweep_action(doc, cutoff, active_document_path == path) do
          :defer ->
            {:cont, {:complete, created, path}}

          {:index, frontmatter} ->
            case index_document_batch(
                   project,
                   doc,
                   resume_member_cursor,
                   member_batch_size,
                   frontmatter
                 ) do
              {:complete, created?} ->
                {:cont, {:complete, created + if(created?, do: 1, else: 0), path}}

              {:partial, created?, next_member_cursor} ->
                {:halt,
                 {:partial, created + if(created?, do: 1, else: 0), completed_file, path,
                  next_member_cursor}}
            end
        end
      end
    )
  end

  defp document_sweep_action(_doc, _cutoff, true), do: {:index, nil}

  defp document_sweep_action(doc, cutoff, false) do
    if young_document?(doc, cutoff) do
      case read_document_frontmatter(doc) do
        {:ok, frontmatter} ->
          if canonical_schedule_id(frontmatter),
            do: {:index, frontmatter},
            else: :defer

        {:error, _reason} ->
          :defer
      end
    else
      {:index, nil}
    end
  end

  defp document_directories(%Agent{} = agent) do
    root_directories(agent, Reports.root(), "reports", &Reports.parse_run_path/1) ++
      root_directories(agent, Artifacts.root(), "general", &Artifacts.parse_path/1)
  end

  defp root_directories(%Agent{} = agent, root, category, parse) do
    case Client.impl().list_agent_files(agent.salix_agent_id, root) do
      {:ok, entries} when is_list(entries) ->
        entries
        |> Enum.filter(&(&1["kind"] == "dir"))
        |> Enum.map(fn entry ->
          %{
            agent: agent,
            category: category,
            parse: parse,
            path: String.trim_trailing(entry["path"], "/")
          }
        end)

      _absent_file_or_error ->
        []
    end
  end

  defp directory_documents(%{agent: agent, category: category, parse: parse, path: path}) do
    case Client.impl().list_agent_files(agent.salix_agent_id, path) do
      {:ok, entries} when is_list(entries) ->
        Enum.flat_map(entries, fn entry ->
          with "file" <- entry["kind"],
               {:ok, parsed} <- parse.(entry["path"]) do
            [
              %{
                category: category,
                agent: agent,
                entry: entry,
                slug: slug_of(parsed),
                date: parsed.date
              }
            ]
          else
            _not_a_document -> []
          end
        end)

      _absent_file_or_error ->
        []
    end
  end

  defp after_cursor?(_value, nil), do: true
  defp after_cursor?(value, cursor), do: value > cursor

  # `Reports.parse_run_path/1` names the slug `:series`; `Artifacts.parse_path/1`
  # names it `:slug`. Both are the same user-suffixed directory name.
  defp slug_of(%{series: series}), do: series
  defp slug_of(%{slug: slug}), do: slug

  # Every document file already indexed for the project/user — any category
  # counts (a Conversation projection keeps the task's own category, e.g.
  # "metrics", so a category filter here would re-index its file), and archived
  # rows still count (archiving a document must not resurrect it).
  defp users_missing_document_path(%Project{} = project, user_ids, path) do
    indexed_user_ids =
      from(i in WorkspaceItem,
        where:
          i.project_id == ^project.id and i.user_id in ^user_ids and i.vfs_path == ^path and
            fragment("NULLIF(?->>'vfs_path', '') = ?", i.payload, i.vfs_path),
        select: i.user_id
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(user_ids, &MapSet.member?(indexed_user_ids, &1))
  end

  defp index_document_batch(
         project,
         doc,
         member_cursor_user_id,
         member_batch_size,
         frontmatter
       ) do
    case owner_for_slug(project, doc.slug) do
      nil ->
        Logger.info(
          "artifacts_sweeper_unmatched_slug project_id=#{project.id} " <>
            "category=#{doc.category} slug=#{doc.slug}"
        )

        {:complete, false}

      slug_base ->
        create_document_rows(
          project,
          slug_base,
          doc,
          member_cursor_user_id,
          member_batch_size,
          frontmatter
        )
    end
  end

  # The suffix expression is backed by `users_artifact_suffix_idx`; eligibility
  # is checked through membership indexes and the query returns at most one row.
  defp owner_for_slug(%Project{} = project, slug) do
    with [_, slug_base, suffix] <- Regex.run(~r/\A(.+)-([0-9a-f]{8})\z/, slug),
         [[_user_id]] <-
           Repo.query!(
             """
             SELECT candidate.user_id::text
             FROM (
               SELECT u.id AS user_id, 0 AS priority
               FROM users u
               WHERE left(u.id::text, 8) = $3
                 AND EXISTS (
                   SELECT 1 FROM project_memberships pm
                   WHERE pm.project_id = $1::text::uuid AND pm.user_id = u.id
                 )
               UNION ALL
               SELECT u.id AS user_id, 1 AS priority
               FROM users u
               WHERE left(u.id::text, 8) = $3
                 AND EXISTS (
                   SELECT 1 FROM org_memberships om
                   WHERE om.org_id = $2::text::uuid
                     AND om.user_id = u.id
                     AND om.role IN ('owner', 'admin')
                 )
             ) candidate
             ORDER BY candidate.priority, candidate.user_id
             LIMIT 1
             """,
             [project.id, project.org_id, suffix]
           ).rows do
      slug_base
    else
      _ -> nil
    end
  end

  defp create_document_rows(
         project,
         slug_base,
         doc,
         member_cursor_user_id,
         member_batch_size,
         frontmatter
       ) do
    path = doc.entry["path"]
    {user_ids, has_more?} = eligible_user_page(project, member_cursor_user_id, member_batch_size)

    case users_missing_document_path(project, user_ids, path) do
      [] ->
        finish_member_page(user_ids, has_more?, false)

      missing_user_ids ->
        case frontmatter_result(doc, frontmatter) do
          {:ok, frontmatter} ->
            attrs = document_attrs(doc, slug_base, frontmatter)

            {created?, failed?} =
              project
              |> users_missing_document_path(missing_user_ids, path)
              |> Enum.reduce({false, false}, fn user_id, {created?, failed?} ->
                case WorkspaceItems.create_tasks(user_id, project.org_id, project.id, [attrs]) do
                  {:ok, _tasks} ->
                    {true, failed?}

                  {:error, reason} ->
                    Logger.warning(
                      "artifacts_sweeper_index_failed project_id=#{project.id} " <>
                        "path=#{path} user_id=#{user_id} reason=#{reason_class(reason)}"
                    )

                    {created?, true}
                end
              end)

            if failed? do
              {:partial, created?, member_cursor_user_id}
            else
              finish_member_page(user_ids, has_more?, created?)
            end

          {:error, reason} when reason in @transient ->
            # Salix hiccup: the file stays unindexed and next sweep retries.
            {:partial, false, member_cursor_user_id}

          {:error, reason} ->
            Logger.warning(
              "artifacts_sweeper_read_failed project_id=#{project.id} " <>
                "path=#{path} reason=#{reason_class(reason)}"
            )

            {:partial, false, member_cursor_user_id}
        end
    end
  end

  defp frontmatter_result(_doc, %{} = frontmatter), do: {:ok, frontmatter}
  defp frontmatter_result(doc, nil), do: read_document_frontmatter(doc)

  defp read_document_frontmatter(doc) do
    case Client.impl().read_agent_file(doc.agent.salix_agent_id, doc.entry["path"]) do
      {:ok, body} -> {:ok, bounded_frontmatter(body)}
      {:error, _reason} = error -> error
    end
  end

  defp bounded_frontmatter(body) when is_binary(body) do
    probe = bounded_frontmatter_probe(body)

    if String.valid?(probe) do
      {frontmatter, _body} = Frontmatter.parse(probe)
      frontmatter
    else
      %{}
    end
  end

  defp bounded_frontmatter_probe(body) when byte_size(body) <= @frontmatter_max_bytes, do: body

  defp bounded_frontmatter_probe(body) do
    prefix = binary_part(body, 0, @frontmatter_max_bytes)

    case List.last(:binary.matches(prefix, "\n")) do
      {offset, length} -> binary_part(prefix, 0, offset + length)
      nil -> ""
    end
  end

  defp reason_class({:exception, _detail}), do: "exception"
  defp reason_class({:error, reason}), do: reason_class(reason)
  defp reason_class({reason, _detail}) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(reason) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(%{__struct__: module}) when is_atom(module), do: safe_atom(module)
  defp reason_class(_reason), do: "external_error"

  defp safe_atom(atom), do: atom |> Atom.to_string() |> String.slice(0, 128)

  defp eligible_user_page(%Project{} = project, cursor, member_batch_size) do
    query_limit = member_batch_size + 1

    project_user_ids =
      Repo.query!(
        """
        SELECT pm.user_id::text
        FROM project_memberships pm
        WHERE pm.project_id = $1::text::uuid
          AND ($2::text IS NULL OR pm.user_id > $2::text::uuid)
        ORDER BY pm.user_id
        LIMIT $3
        """,
        [project.id, cursor, query_limit]
      ).rows

    org_admin_user_ids =
      Repo.query!(
        """
        SELECT om.user_id::text
        FROM org_memberships om
        WHERE om.org_id = $1::text::uuid
          AND om.role IN ('owner', 'admin')
          AND ($2::text IS NULL OR om.user_id > $2::text::uuid)
        ORDER BY om.user_id
        LIMIT $3
        """,
        [project.org_id, cursor, query_limit]
      ).rows

    user_ids =
      (project_user_ids ++ org_admin_user_ids)
      |> Enum.map(fn [user_id] -> user_id end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(query_limit)

    {Enum.take(user_ids, member_batch_size), length(user_ids) > member_batch_size}
  end

  defp finish_member_page([], _has_more?, created?), do: {:complete, created?}

  defp finish_member_page(user_ids, true, created?),
    do: {:partial, created?, List.last(user_ids)}

  defp finish_member_page(_user_ids, false, created?), do: {:complete, created?}

  # Canonical denormalized index row for an immutable artifact: the document
  # path plus the frontmatter scalars the board renders from.
  # Missing frontmatter degrades to the path: the title falls back to the
  # humanized slug base and (for reports) the period to the run date.
  defp document_attrs(%{category: "reports"} = doc, slug_base, frontmatter) do
    payload =
      %{"vfs_path" => doc.entry["path"], "series" => doc.slug}
      |> put_present("kind", frontmatter["kind"])
      |> put_present("period", presence(frontmatter["period"]) || Date.to_iso8601(doc.date))
      |> put_present("summary", frontmatter["summary"])
      |> put_present("site", frontmatter["site"])

    doc
    |> base_attrs(slug_base, frontmatter, "Report", payload)
    |> put_present("salix_schedule_id", canonical_schedule_id(frontmatter))
  end

  # General artifacts index to the artifact payload shape — exactly
  # `{vfs_path, summary}`; the document body stays in the VFS file.
  defp document_attrs(%{category: "general"} = doc, slug_base, frontmatter) do
    payload =
      %{"vfs_path" => doc.entry["path"]}
      |> put_present("summary", frontmatter["summary"])

    doc
    |> Map.put(:category, artifact_category(frontmatter))
    |> base_attrs(slug_base, frontmatter, "Artifact", payload)
    |> put_present("salix_schedule_id", canonical_schedule_id(frontmatter))
  end

  defp artifact_category(frontmatter) do
    case presence(frontmatter["category"]) do
      category when category != "reports" ->
        if category in WorkspaceItems.categories(), do: category, else: "general"

      _missing_or_cross_root ->
        "general"
    end
  end

  defp canonical_schedule_id(frontmatter) do
    case presence(frontmatter["schedule_id"]) do
      nil -> nil
      schedule_id -> if Ids.valid_schedule_id?(schedule_id), do: schedule_id
    end
  end

  defp base_attrs(doc, slug_base, frontmatter, fallback_title, payload) do
    title = presence(frontmatter["title"]) || default_title(slug_base, fallback_title)

    %{
      "title" => String.slice(title, 0, 200),
      "category" => doc.category,
      "platform" => "comma",
      "status" => "ready_for_review",
      "source" => "agent",
      "payload" => payload,
      "salix_agent_id" => doc.agent.salix_agent_id
    }
  end

  defp default_title(slug_base, fallback) do
    case slug_base |> String.split("-", trim: true) |> Enum.map(&String.capitalize/1) do
      [] -> fallback
      words -> Enum.join(words, " ")
    end
  end

  defp put_present(map, key, value) do
    case presence(value) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  defp claim_scan(now_ms, lease_ttl_ms) do
    now = DateTime.from_unix!(now_ms * 1_000, :microsecond)
    lease_expires_at = DateTime.add(now, lease_ttl_ms, :millisecond)
    token = Ecto.UUID.generate()

    Repo.insert_all(
      ArtifactSweepScan,
      [
        %{
          id: @scan_id,
          generation: 1,
          created_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing
    )

    query =
      from(scan in ArtifactSweepScan,
        where:
          scan.id == @scan_id and
            (is_nil(scan.lease_token) or is_nil(scan.lease_expires_at) or
               scan.lease_expires_at <= ^now),
        update: [
          set: [
            lease_token: ^token,
            lease_expires_at: ^lease_expires_at,
            updated_at: ^now
          ]
        ],
        select: scan
      )

    case Repo.update_all(query, []) do
      {1, [scan]} -> {:ok, scan}
      {0, []} -> :busy
    end
  end

  defp acknowledge_scan(claim, progress) do
    now = DateTime.utc_now()

    {updated, _} =
      Repo.update_all(
        from(scan in ArtifactSweepScan,
          where: scan.id == @scan_id and scan.lease_token == ^claim.lease_token
        ),
        set: [
          cursor_agent_id: progress.cursor_agent_id,
          active_agent_id: progress.active_agent_id,
          directory_cursor: progress.directory_cursor,
          file_cursor: progress.file_cursor,
          active_document_path: progress.active_document_path,
          member_cursor_user_id: progress.member_cursor_user_id,
          generation: claim.generation + 1,
          lease_token: nil,
          lease_expires_at: nil,
          updated_at: now
        ]
      )

    if updated == 1, do: :ok, else: {:error, :artifact_sweep_lease_lost}
  end

  defp release_scan(claim) do
    Repo.update_all(
      from(scan in ArtifactSweepScan,
        where: scan.id == @scan_id and scan.lease_token == ^claim.lease_token
      ),
      set: [lease_token: nil, lease_expires_at: nil, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp schedule_sweep(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
