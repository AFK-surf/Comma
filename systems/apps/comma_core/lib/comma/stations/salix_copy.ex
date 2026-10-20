defmodule Comma.Stations.SalixCopy do
  @moduledoc """
  Moves Comma's station roster into the one Salix keeps
  (`SalixStore.Stations`) during one rolling release. A Workspace is its
  Salix Group, so each row goes to the Workspace's `salix_tenant_id` and
  `salix_group_id`:

    * `comma_stations` → `salix_stations`, the same id, name, version and
      times; `kind` is `cloud_vm` for a station the control plane placed
      (`enrolled_by` nil) and `device` otherwise; `enrolled_by` keeps the
      Comma user id.
    * `comma_station_signing_keys` → `salix_station_signing_keys`, the same
      kid, key material and times.
    * `comma_station_revocations` → `salix_station_revocations`, per Group.
    * for a Workspace that has a station which is not removed, the Workspace
      id as the workspace id its Group is told
      (`SalixStore.Stations.Workspaces`): those stations and their clients'
      credentials hold that id.

  Comma's tables are only read, through the repo the caller gives; Salix's
  rows are written through `SalixStore.Repo`. This module and
  `Comma.Stations.Window` are for this one release: the release after it
  removes both and every use of Comma's three tables.

  ## The three phases

  The marker `station_roster_v1` in `salix_cutover_markers` says the phase.

    * No marker: only servers of the release before run. They write Comma's
      tables and nothing reads Salix's, so a pass makes Salix's rows what
      Comma's are (`run/1`, `open_window/1`).
    * `window` (written by `open_window/1`, Comma migration 20261011100001,
      before the first server of this release starts): servers of both
      releases run. Those of the release before still write Comma's tables;
      those of this release write Salix's and never Comma's. From here every
      pass only merges (below), and this release's servers merge what they
      are about to read (`Comma.Stations.Window`).
    * `complete` (written by `finish/1`, run once the rollout has succeeded
      and no server of the release before is left; `Comma.Release`): one last
      merge, then nothing reads Comma's tables any more.

  ## Merging

  A merge never takes from Salix what a server of this release wrote:

    * a station Salix has no row of is inserted;
    * a station Comma enrolled later than Salix's row was (taken back, or
      moved, through a server of the release before) replaces Salix's row;
    * a station Comma removed after Salix's row was enrolled is removed in
      Salix;
    * a revocation is added, and one both have keeps the later `at`;
    * a signing key Salix has no row of is added: as it is when Salix has no
      key of that status, else to verify only (Salix keeps one signer).

  A name changed through a server of the release before, during the window,
  stays as Salix has it: a station's row says when it was enrolled and
  removed, not when it was renamed.

  When Comma's tables hold no row, nothing is copied and Salix is not
  started (a new installation migrates Comma before Salix has its tables);
  `finish/1` still marks `complete`.
  """

  import Ecto.Query

  alias Comma.Data.Workspace
  alias Comma.Stations.{Revocations, Station}
  alias Comma.Stations.SigningKeys.Key
  alias SalixStore.Repo, as: SalixRepo
  alias SalixStore.Stations.Revocations, as: SalixRevocations
  alias SalixStore.Stations.SigningKeys.Key, as: SalixKey
  alias SalixStore.Stations.Station, as: SalixStation
  alias SalixStore.Stations.Workspaces, as: SalixWorkspaces

  @page 500
  @marker "station_roster_v1"
  # A key Salix cannot take with its status verifies for as long as a
  # credential it signed may last, one day more.
  @verify_seconds 31 * 24 * 60 * 60

  @type phase :: :before | :window | :complete

  @doc "The phase the marker says; a marker that cannot be read is an error, not `:before`."
  @spec phase() :: {:ok, phase()} | {:error, term()}
  def phase do
    case SalixRepo.query("SELECT evidence FROM salix_cutover_markers WHERE name = $1", [@marker]) do
      {:ok, %{rows: []}} -> {:ok, :before}
      {:ok, %{rows: [[%{"phase" => "window"}]]}} -> {:ok, :window}
      {:ok, %{rows: [[%{"phase" => "complete"}]]}} -> {:ok, :complete}
      {:ok, %{rows: rows}} -> {:error, {:marker_unreadable, rows}}
      {:error, reason} -> {:error, {:marker_unreadable, reason}}
    end
  rescue
    exception -> {:error, {:marker_unreadable, exception}}
  end

  @doc """
  A pass while only servers of the release before run (Comma migration
  20261010200002). Once the window is open it merges; once the move is
  complete it does nothing.
  """
  @spec run(module()) :: {:ok, map() | :complete} | {:error, term()}
  def run(repo), do: pass(repo, false)

  @doc """
  The pass that opens the window (Comma migration 20261011100001): Salix's
  rows become Comma's, the Groups whose stations hold a Workspace id are told
  it, and the marker says `window`. Run again, it merges.
  """
  @spec open_window(module()) :: {:ok, map() | :complete} | {:error, term()}
  def open_window(repo), do: pass(repo, true)

  defp pass(repo, open?) do
    if comma_empty?(repo) do
      {:ok, %{stations: 0, signing_keys: 0, revocations: 0}}
    else
      salix!()

      case phase() do
        {:ok, :before} ->
          with {:ok, copied} <- replace(repo),
               :ok <- if(open?, do: mark("window", copied), else: :ok),
               do: {:ok, copied}

        {:ok, :window} ->
          merge(repo)

        {:ok, :complete} ->
          {:ok, :complete}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  The last merge, once no server of the release before is left, and the
  marker `complete`. Run again, it does nothing. With no row in Comma's
  tables there is nothing to merge; the marker is written all the same.
  """
  @spec finish(module()) :: {:ok, map() | :complete} | {:error, term()}
  def finish(repo) do
    case phase() do
      {:ok, :complete} ->
        {:ok, :complete}

      {:ok, _phase} ->
        with {:ok, merged} <- if(comma_empty?(repo), do: {:ok, %{}}, else: merge(repo)),
             :ok <- mark("complete", merged),
             do: {:ok, merged}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Opens the window again after `complete`: for a release rolled back, before
  servers that write Comma's tables start again. What they write is merged
  when this release's servers return.
  """
  @spec reopen() :: :ok | {:error, term()}
  def reopen, do: mark("window", %{"reopened" => true})

  defp comma_empty?(repo) do
    not (repo.exists?(Station) or repo.exists?(Key) or repo.exists?(Revocations))
  end

  # ── the marker ──────────────────────────────────────────────────────────

  defp mark(phase, evidence) do
    evidence =
      evidence
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("phase", phase)

    case SalixRepo.query(
           """
           INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ($1, $2, $3)
           ON CONFLICT (name) DO UPDATE SET completed_at = EXCLUDED.completed_at, evidence = EXCLUDED.evidence
           """,
           [@marker, SystemsClock.utc_now(), evidence]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:marker_write_failed, reason}}
    end
  end

  # ── before the window: Salix's rows become Comma's ──────────────────────

  defp replace(repo) do
    stations =
      pages(repo, stations_query(), & &1.id, fn rows ->
        SalixRepo.insert_all(SalixStation, Enum.map(rows, &station_entry/1),
          on_conflict: {:replace_all_except, [:id]},
          conflict_target: [:id]
        )
      end)

    keys = replace_signing_keys(repo)
    revocations = merge_revocations(repo, revocations_query())
    workspaces = tell_workspace_ids(repo, workspaces_with_stations())

    {:ok,
     %{stations: stations, signing_keys: keys, revocations: revocations, workspaces: workspaces}}
  end

  # Few rows; one transaction, so "one signing, one pending" holds throughout.
  defp replace_signing_keys(repo) do
    case repo.all(from(k in Key, order_by: [asc: k.kid])) do
      [] ->
        0

      keys ->
        SalixRepo.transaction(fn ->
          SalixRepo.delete_all(SalixKey)

          SalixRepo.insert_all(
            SalixKey,
            Enum.map(keys, &key_entry(&1, &1.status, &1.retire_after))
          )
        end)

        length(keys)
    end
  end

  # ── from the window on: what Comma has and Salix lacks ──────────────────

  defp merge(repo) do
    stations = pages(repo, stations_query(), & &1.id, &merge_station_rows/1)
    keys = merge_signing_keys(repo)
    revocations = merge_revocations(repo, revocations_query())
    workspaces = tell_workspace_ids(repo, workspaces_with_stations())

    {:ok,
     %{stations: stations, signing_keys: keys, revocations: revocations, workspaces: workspaces}}
  end

  @doc "Merges one station's Comma row, when Comma has one (`Comma.Stations.Window`)."
  def merge_station(repo, station_id) when is_binary(station_id) do
    rows = repo.all(from([s, _w] in stations_query(), where: s.id == ^station_id))
    merge_station_rows(rows)

    tell_workspace_ids(
      repo,
      from(w in workspaces_with_stations(), where: w.id in ^workspace_ids(rows))
    )

    :ok
  end

  @doc "Merges a Workspace's stations and revocations (`Comma.Stations.Window`)."
  def merge_workspace(repo, workspace_id) when is_binary(workspace_id) do
    # A Workspace holds at most 64 stations that are not removed; removed ones are bounded with them.
    rows =
      repo.all(
        from([s, _w] in stations_query(), where: s.workspace_id == ^workspace_id, limit: @page)
      )

    merge_station_rows(rows)
    tell_workspace_ids(repo, from(w in workspaces_with_stations(), where: w.id == ^workspace_id))

    merge_revocations(
      repo,
      from([r, _w] in revocations_query(), where: r.workspace_id == ^workspace_id)
    )

    :ok
  end

  defp workspace_ids(rows),
    do: rows |> Enum.map(fn {s, _, _} -> s.workspace_id end) |> Enum.uniq()

  # Each rule is one statement that holds whatever Salix's row is by then.
  defp merge_station_rows([]), do: :ok

  defp merge_station_rows(rows) do
    entries = Enum.map(rows, &station_entry/1)
    SalixRepo.insert_all(SalixStation, entries, on_conflict: :nothing, conflict_target: [:id])

    Enum.each(entries, fn entry ->
      # Enrolled anew through a server of the release before: Comma's row is the station now.
      SalixRepo.update_all(
        from(s in SalixStation, where: s.id == ^entry.id and s.enrolled_at < ^entry.enrolled_at),
        set: entry |> Map.drop([:id, :inserted_at]) |> Map.to_list()
      )

      # Removed there since Salix's row was enrolled.
      if entry.removed_at do
        SalixRepo.update_all(
          from(s in SalixStation,
            where:
              s.id == ^entry.id and is_nil(s.removed_at) and s.enrolled_at <= ^entry.removed_at
          ),
          set: [removed_at: entry.removed_at, updated_at: entry.removed_at]
        )
      end
    end)
  end

  @doc "Merges Comma's signing keys Salix has no row of (`Comma.Stations.Window`)."
  def merge_signing_keys(repo) do
    case repo.all(from(k in Key, order_by: [asc: k.kid])) do
      [] ->
        0

      keys ->
        have = SalixRepo.all(from(k in SalixKey, select: {k.kid, k.status}))
        kids = MapSet.new(have, &elem(&1, 0))
        statuses = MapSet.new(have, &elem(&1, 1))
        retire = DateTime.add(SystemsClock.utc_now(), @verify_seconds, :second)

        entries =
          keys
          |> Enum.reject(&MapSet.member?(kids, &1.kid))
          |> Enum.map(fn key ->
            if key.status == "verify_only" or not MapSet.member?(statuses, key.status),
              do: key_entry(key, key.status, key.retire_after),
              else: key_entry(key, "verify_only", retire)
          end)

        # Another server took the key, or the status, meanwhile: the next merge reads again.
        SalixRepo.insert_all(SalixKey, entries, on_conflict: :nothing)
        length(entries)
    end
  end

  defp merge_revocations(repo, query) do
    pages(repo, query, &{&1.workspace_id, &1.kind, &1.subject_id}, fn rows ->
      entries =
        Enum.map(rows, fn {r, tenant_id, group_id} ->
          %{
            tenant_id: tenant_id,
            group_id: group_id,
            kind: r.kind,
            subject_id: r.subject_id,
            at: r.at
          }
        end)

      SalixRepo.insert_all(SalixRevocations, entries,
        on_conflict:
          from(r in SalixRevocations,
            update: [set: [at: fragment("GREATEST(?, EXCLUDED.at)", r.at)]]
          ),
        conflict_target: [:group_id, :kind, :subject_id]
      )
    end)
  end

  # ── the workspace id a Group is told ────────────────────────────────────

  # The Workspaces that have a station which is not removed.
  defp workspaces_with_stations do
    from(w in Workspace,
      where:
        w.id in subquery(from(s in Station, where: is_nil(s.removed_at), select: s.workspace_id)),
      order_by: [asc: w.id],
      select: {w, w.salix_tenant_id, w.salix_group_id}
    )
  end

  # Their Groups are told the Workspace id their stations hold, unless Salix
  # already says what the Group is told, or a station was enrolled there
  # through a server of this release (it holds the Group id).
  defp tell_workspace_ids(repo, query) do
    pages(repo, query, & &1.id, fn rows ->
      now = SystemsClock.utc_now()

      entries =
        for {workspace, tenant_id, group_id} <- rows,
            not salix_enrolled?(repo, workspace.id, group_id) do
          %{
            tenant_id: tenant_id,
            group_id: group_id,
            workspace_id: workspace.id,
            previous_ids: [],
            inserted_at: now,
            updated_at: now
          }
        end

      SalixRepo.insert_all(SalixWorkspaces, entries, on_conflict: :nothing)
    end)
  end

  defp salix_enrolled?(repo, workspace_id, group_id) do
    in_comma = repo.all(from(s in Station, where: s.workspace_id == ^workspace_id, select: s.id))

    SalixRepo.exists?(
      from(s in SalixStation,
        where: s.group_id == ^group_id and is_nil(s.removed_at) and s.id not in ^in_comma
      )
    )
  end

  # ── reading Comma ───────────────────────────────────────────────────────

  defp stations_query do
    from(s in Station,
      join: w in Workspace,
      on: w.id == s.workspace_id,
      order_by: [asc: s.id],
      select: {s, w.salix_tenant_id, w.salix_group_id}
    )
  end

  defp revocations_query do
    from(r in Revocations,
      join: w in Workspace,
      on: w.id == r.workspace_id,
      order_by: [asc: r.workspace_id, asc: r.kind, asc: r.subject_id],
      select: {r, w.salix_tenant_id, w.salix_group_id}
    )
  end

  # Every row of `query`, in pages of at most 500 in its key order; answers how many.
  defp pages(repo, query, key, write, last \\ nil, count \\ 0) do
    page = from(q in query, limit: @page)

    case repo.all(after_key(page, last)) do
      [] ->
        count

      rows ->
        write.(rows)
        {row, _, _} = List.last(rows)
        pages(repo, query, key, write, key.(row), count + length(rows))
    end
  end

  defp after_key(query, nil), do: query

  defp after_key(query, {workspace_id, kind, subject_id}) do
    from([r, _w] in query,
      where:
        r.workspace_id > ^workspace_id or (r.workspace_id == ^workspace_id and r.kind > ^kind) or
          (r.workspace_id == ^workspace_id and r.kind == ^kind and r.subject_id > ^subject_id)
    )
  end

  defp after_key(query, id) when is_binary(id), do: from(q in query, where: q.id > ^id)

  defp station_entry({%Station{} = s, tenant_id, group_id}) do
    %{
      id: s.id,
      tenant_id: tenant_id,
      group_id: group_id,
      name: s.name,
      version: s.version,
      kind: if(is_nil(s.enrolled_by), do: "cloud_vm", else: "device"),
      enrolled_by: s.enrolled_by,
      enrolled_at: s.enrolled_at,
      removed_at: s.removed_at,
      last_seen_at: s.last_seen_at,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end

  defp key_entry(%Key{} = k, status, retire_after) do
    %{
      kid: k.kid,
      public_key: k.public_key,
      private_key_ciphertext: k.private_key_ciphertext,
      private_key_iv: k.private_key_iv,
      private_key_tag: k.private_key_tag,
      status: status,
      retire_after: retire_after,
      created_at: k.created_at,
      updated_at: k.updated_at
    }
  end

  # SalixStore.Repo is supervised by its application.
  defp salix! do
    {:ok, _} = Application.ensure_all_started(:salix_store)
    :ok
  end
end
