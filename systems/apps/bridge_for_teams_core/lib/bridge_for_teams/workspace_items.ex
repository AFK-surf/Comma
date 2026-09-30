defmodule BridgeForTeams.WorkspaceItems do
  @moduledoc """
  Bridge-owned local My Space workspace items.

  The board reads and writes `workspace_items` in Bridge Postgres. Salix ids are
  stored only as provenance for background projection or runtime follow-up.
  """

  import Ecto.Query

  alias BridgeForTeams.{Memberships, Projects, Repo}
  alias BridgeForTeams.Schema.{Project, WorkspaceItem}

  defmodule Item do
    @moduledoc "Presentation projection of a local workspace item for My Space."

    defstruct [
      :id,
      :title,
      :description,
      :category,
      :kind,
      :platform,
      :status,
      :activity_status,
      :source,
      :payload,
      :metadata,
      :source_refs,
      :labels,
      :latest_artifact,
      :artifact_manifest,
      :archived_at,
      :external_source,
      :external_id,
      :salix_conversation_id,
      :salix_agent_id,
      :salix_schedule_id,
      :vfs_path,
      :row_user_id,
      :user_id,
      :org_id,
      :project_id,
      :created_at,
      :updated_at
    ]
  end

  @categories ~w(reports email_drafts meeting_recaps portfolio team_activity engineering metrics inbox informed meetings general calendar routines issues suggestions custom)
  @platforms ~w(gmail google_calendar github linear notion slack feishu comma)
  @statuses ~w(suggested accepted in_progress ready_for_review failed cancelled escalated done archived)
  @seed_source "workspace_seed"
  @mock_import_source "mock_import"

  @category_to_kind %{
    "reports" => "report",
    "email_drafts" => "email_draft",
    "meeting_recaps" => "meeting_recap",
    "portfolio" => "portfolio_update",
    "team_activity" => "team_activity",
    "engineering" => "engineering_report",
    "metrics" => "metrics_snapshot",
    "inbox" => "inbox_item",
    "informed" => "informed_update",
    "meetings" => "meeting",
    "general" => "work_item",
    "calendar" => "calendar_item",
    "routines" => "routine_run",
    "issues" => "issue",
    "suggestions" => "suggestion",
    "custom" => "custom_work"
  }

  @kind_to_category Map.new(@category_to_kind, fn {category, kind} -> {kind, category} end)
                    |> Map.put("agent_task", "general")
  @workspace_kinds @kind_to_category |> Map.keys() |> Enum.uniq()

  def categories, do: @categories
  def kinds, do: @workspace_kinds
  def category_for_kind(kind), do: kind_to_category(kind)
  def kind_for_category(category), do: category_to_kind(normalize_category(category))
  def platforms, do: @platforms
  def statuses, do: @statuses

  @doc "`source_refs[\"source\"]` stamped on onboarding seed items."
  def seed_source, do: @seed_source

  @doc """
  `external_source` (and `source_refs["source"]`) stamped on My Space
  data-import items — see `BridgeForTeams.WorkspaceImports`.
  """
  def mock_import_source, do: @mock_import_source

  @doc """
  The categories in which this user's board is owned by live (non-archived)
  mock-import cards. Onboarding seeds and the dashboard projection's builder
  rows (metrics/team activity/meetings) skip these categories so imported
  demo data never sits next to a duplicate live widget.
  """
  def mock_import_categories(user_id, project_id) do
    WorkspaceItem
    |> where([i], i.user_id == ^user_id and i.project_id == ^project_id)
    |> where([i], i.external_source == ^@mock_import_source)
    |> where([i], i.status != "archived" and is_nil(i.archived_at))
    |> select([i], i.category)
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  def artifact_path(conversation_id, version_id, filename \\ "artifact.md") do
    safe_conversation = path_segment(conversation_id)
    safe_version = path_segment(version_id)
    safe_filename = filename |> to_string() |> Path.basename()

    "/.salix/conversations/#{safe_conversation}/artifacts/#{safe_version}/#{safe_filename}"
  end

  def create_tasks(user_id, org_id, project_id, attrs_list) when is_list(attrs_list) do
    with {:ok, %Project{} = project} <- visible_project(user_id, project_id),
         true <- project.org_id == org_id do
      Repo.transaction(fn ->
        Enum.map(attrs_list, fn attrs ->
          attrs
          |> item_attrs(user_id, org_id, project_id)
          |> create_item()
          |> case do
            {:ok, item} -> to_item(item)
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  def list_tasks(user_id, opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    start_time = System.monotonic_time()

    result =
      case visible_project(user_id, project_id) do
        {:ok, %Project{} = project} ->
          WorkspaceItem
          |> where([i], i.user_id == ^user_id and i.project_id == ^project.id)
          |> maybe_where(:org_id, Keyword.get(opts, :org_id))
          |> maybe_where(:status, Keyword.get(opts, :status))
          |> maybe_where(:source, Keyword.get(opts, :source))
          |> maybe_where(:category, Keyword.get(opts, :category))
          |> maybe_exclude_archived_query(Keyword.get(opts, :include_archived))
          |> order_by([i], desc: i.updated_at, desc: i.created_at)
          |> limit(^Keyword.get(opts, :limit, 200))
          |> Repo.all()
          |> Enum.map(&to_item/1)

        {:error, :not_found} ->
          []
      end

    :telemetry.execute(
      [:bridge_for_teams, :workspace_items, :list_tasks],
      %{duration: System.monotonic_time() - start_time, count: length(result)},
      %{project_id: project_id, user_id: user_id}
    )

    result
  end

  def tasks_by_category(user_id, opts) do
    grouped = user_id |> list_tasks(opts) |> Enum.group_by(& &1.category)

    @categories
    |> Enum.flat_map(fn category ->
      case grouped[category] do
        nil -> []
        tasks -> [{category, tasks}]
      end
    end)
  end

  def get_task(user_id, item_id, opts \\ []) when is_binary(item_id) do
    project_id = Keyword.get(opts, :project_id)

    query =
      WorkspaceItem
      |> where([i], i.user_id == ^user_id)
      |> item_identity_where(item_id)

    query =
      if is_binary(project_id), do: where(query, [i], i.project_id == ^project_id), else: query

    case query
         |> order_by([i], desc: i.updated_at, desc: i.created_at)
         |> limit(1)
         |> Repo.one() do
      %WorkspaceItem{} = row ->
        if project_visible?(user_id, row.project_id),
          do: {:ok, to_item(row)},
          else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  defp item_identity_where(query, item_id) do
    case Ecto.UUID.cast(item_id) do
      {:ok, uuid} ->
        where(
          query,
          [i],
          i.id == ^uuid or i.salix_conversation_id == ^item_id or
            (i.vfs_path == ^item_id and
               fragment("NULLIF(?->>'vfs_path', '') = ?", i.payload, i.vfs_path))
        )

      :error ->
        where(
          query,
          [i],
          i.salix_conversation_id == ^item_id or
            (i.vfs_path == ^item_id and
               fragment("NULLIF(?->>'vfs_path', '') = ?", i.payload, i.vfs_path))
        )
    end
  end

  def update_task(%Item{} = item, attrs) when is_map(attrs) do
    with %WorkspaceItem{} = row <- get_item_row(item) do
      row
      |> WorkspaceItem.changeset(update_attrs(item, attrs))
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, to_item(updated)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :not_found}
    end
  end

  def archive_task(%Item{} = item) do
    update_task(item, %{
      "status" => "archived",
      "archived_at" => DateTime.utc_now()
    })
  end

  def seeded?(user_id, project_id) do
    WorkspaceItem
    |> where([i], i.user_id == ^user_id and i.project_id == ^project_id)
    |> where([i], fragment("?->>? = ?", i.source_refs, "source", ^@seed_source))
    |> Repo.exists?()
  end

  def ensure_seeded(user_id, org_id, project_id, seed_list) when is_list(seed_list) do
    if seeded?(user_id, project_id) do
      {:ok, :already_seeded}
    else
      # A category already occupied by a live mock-import card (My Space data
      # import) keeps that card: planting the seed container next to it would
      # show the widget twice. Other categories seed as usual.
      mock_categories = mock_import_categories(user_id, project_id)

      seeds =
        seed_list
        |> Enum.map(&stringify/1)
        |> Enum.reject(&(normalize_category(&1["category"]) in mock_categories))
        |> Enum.map(fn attrs ->
          attrs
          |> Map.put("source", "onboarding")
          |> Map.put("source_refs", %{"source" => @seed_source})
        end)

      if seeds == [] do
        {:ok, :seeded}
      else
        case create_tasks(user_id, org_id, project_id, seeds) do
          {:ok, _items} -> {:ok, :seeded}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  def upsert_projected_items(project, user_id, rows) when is_list(rows) do
    Repo.transaction(fn ->
      Enum.map(rows, fn attrs ->
        attrs = item_attrs(attrs, user_id, project.org_id, project.id)

        attrs
        |> projected_item_query()
        |> Repo.one()
        |> case do
          %WorkspaceItem{} = existing -> existing
          nil -> %WorkspaceItem{}
        end
        |> WorkspaceItem.changeset(attrs)
        |> Repo.insert_or_update()
        |> case do
          {:ok, item} -> to_item(item)
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  defp projected_item_query(%{
         project_id: project_id,
         user_id: user_id,
         salix_conversation_id: conversation_id
       })
       when is_binary(conversation_id) do
    from(i in WorkspaceItem,
      where:
        i.project_id == ^project_id and i.user_id == ^user_id and
          i.salix_conversation_id == ^conversation_id
    )
  end

  defp projected_item_query(%{project_id: project_id, user_id: user_id, vfs_path: vfs_path})
       when is_binary(vfs_path) do
    from(i in WorkspaceItem,
      where:
        i.project_id == ^project_id and i.user_id == ^user_id and i.vfs_path == ^vfs_path and
          fragment("NULLIF(?->>'vfs_path', '') = ?", i.payload, i.vfs_path),
      order_by: [desc: i.updated_at, desc: i.created_at],
      limit: 1
    )
  end

  defp projected_item_query(%{
         project_id: project_id,
         user_id: user_id,
         external_source: source,
         external_id: external_id
       })
       when is_binary(source) and is_binary(external_id) do
    from(i in WorkspaceItem,
      where:
        i.project_id == ^project_id and i.user_id == ^user_id and i.external_source == ^source and
          i.external_id == ^external_id
    )
  end

  defp projected_item_query(_attrs), do: from(i in WorkspaceItem, where: false)

  # Non-raising insert for `create_tasks`: an `{:error, changeset}` (e.g. the
  # unique salix_conversation_id / vfs_path index) flows back so the caller can
  # roll the transaction back instead of crashing the calling process.
  defp create_item(attrs) do
    %WorkspaceItem{}
    |> WorkspaceItem.changeset(attrs)
    |> Repo.insert()
  end

  defp item_attrs(attrs, user_id, org_id, project_id) do
    attrs = stringify(attrs)
    category = normalize_category(attrs["category"])
    payload = map_value(attrs["payload"])

    latest_artifact =
      map_value(attrs["latest_artifact"], nil) || latest_artifact_from_payload(payload)

    vfs_path = attrs["vfs_path"] || payload["vfs_path"]

    source_refs =
      map_value(attrs["source_refs"])
      |> maybe_put("conversation_id", attrs["salix_conversation_id"])
      |> maybe_put("agent_id", attrs["salix_agent_id"])
      |> maybe_put("schedule_id", attrs["salix_schedule_id"])

    %{
      user_id: user_id,
      org_id: org_id,
      project_id: project_id,
      title: nonblank(attrs["title"]) || "Untitled",
      description: nonblank(attrs["description"]),
      category: category,
      kind: nonblank(attrs["kind"]) || category_to_kind(category),
      platform: normalize_platform(attrs["platform"]),
      status: normalize_status(attrs["status"]),
      activity_status: attrs["activity_status"] || "idle",
      source: nonblank(attrs["source"]) || "user",
      payload: payload,
      metadata: map_value(attrs["metadata"]),
      source_refs: strip_empty_values(source_refs),
      labels: labels(attrs["labels"]),
      latest_artifact: latest_artifact,
      artifact_manifest: map_value(attrs["artifact_manifest"], nil),
      archived_at: timestamp(attrs["archived_at"]),
      external_source: nonblank(attrs["external_source"]),
      external_id: nonblank(attrs["external_id"]),
      salix_conversation_id: nonblank(attrs["salix_conversation_id"]),
      salix_agent_id: nonblank(attrs["salix_agent_id"]),
      salix_schedule_id: nonblank(attrs["salix_schedule_id"]),
      vfs_path: nonblank(vfs_path),
      synced_at: timestamp(attrs["synced_at"])
    }
  end

  defp update_attrs(%Item{} = item, attrs) do
    attrs = stringify(attrs)
    payload = map_value(Map.get(attrs, "payload"), item.payload || %{})

    latest_artifact =
      map_value(attrs["latest_artifact"], nil) || latest_artifact_from_payload(payload)

    vfs_path = attrs["vfs_path"] || payload["vfs_path"]

    source_refs =
      (item.source_refs || %{})
      |> maybe_put("schedule_id", attrs["salix_schedule_id"])
      |> maybe_put("agent_id", attrs["salix_agent_id"])
      |> maybe_put("conversation_id", attrs["salix_conversation_id"])

    %{}
    |> maybe_put(:title, nonblank(attrs["title"]))
    |> maybe_put(:description, nonblank(attrs["description"]))
    |> maybe_put_present(attrs, "category", :category, &normalize_category/1)
    |> maybe_put_present(attrs, "kind", :kind, &nonblank/1)
    |> maybe_put_kind_from_category(attrs)
    |> maybe_put_present(attrs, "platform", :platform, &normalize_platform/1)
    |> maybe_put_present(attrs, "status", :status, &normalize_status/1)
    |> maybe_put(:activity_status, attrs["activity_status"])
    |> maybe_put(:source, nonblank(attrs["source"]))
    |> Map.put(:payload, payload)
    |> maybe_put_metadata(item, attrs)
    |> maybe_put(:source_refs, strip_empty_values(source_refs))
    |> maybe_put_labels(attrs)
    |> maybe_put(:latest_artifact, latest_artifact)
    |> maybe_put(:artifact_manifest, map_value(attrs["artifact_manifest"], nil))
    |> maybe_put(:archived_at, timestamp(attrs["archived_at"]))
    |> maybe_put(:salix_conversation_id, nonblank(attrs["salix_conversation_id"]))
    |> maybe_put(:salix_agent_id, nonblank(attrs["salix_agent_id"]))
    |> maybe_put(:salix_schedule_id, nonblank(attrs["salix_schedule_id"]))
    |> maybe_put_vfs_path(attrs, vfs_path)
  end

  defp maybe_put_vfs_path(changes, attrs, vfs_path) do
    if Map.has_key?(attrs, "vfs_path") or Map.has_key?(attrs, "payload") do
      Map.put(changes, :vfs_path, nonblank(vfs_path))
    else
      changes
    end
  end

  defp maybe_put_present(map, attrs, key, field, normalizer) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> maybe_put(map, field, normalizer.(value))
      :error -> map
    end
  end

  defp maybe_put_kind_from_category(map, attrs) do
    if Map.has_key?(map, :kind) or not Map.has_key?(attrs, "category") do
      map
    else
      maybe_put(map, :kind, attrs["category"] |> normalize_category() |> category_to_kind())
    end
  end

  defp maybe_put_metadata(map, item, attrs) do
    case Map.fetch(attrs, "metadata") do
      {:ok, value} -> maybe_put(map, :metadata, Map.merge(item.metadata || %{}, map_value(value)))
      :error -> map
    end
  end

  defp maybe_put_labels(map, attrs) do
    case Map.fetch(attrs, "labels") do
      {:ok, value} -> maybe_put(map, :labels, labels(value))
      :error -> map
    end
  end

  defp to_item(%WorkspaceItem{} = row) do
    %Item{
      id: row.id,
      title: row.title,
      description: row.description,
      category: row.category,
      kind: row.kind,
      platform: row.platform,
      status: row.status,
      activity_status: row.activity_status,
      source: row.source,
      payload: row.payload || %{},
      metadata: row.metadata || %{},
      source_refs: row.source_refs || %{},
      labels: row.labels || [],
      latest_artifact: row.latest_artifact,
      artifact_manifest: row.artifact_manifest,
      archived_at: row.archived_at,
      external_source: row.external_source,
      external_id: row.external_id,
      salix_conversation_id: row.salix_conversation_id,
      salix_agent_id: row.salix_agent_id,
      salix_schedule_id: row.salix_schedule_id,
      vfs_path: row.vfs_path,
      row_user_id: row.user_id,
      user_id: presentation_user_id(row),
      org_id: row.org_id,
      project_id: row.project_id,
      created_at: row.created_at,
      updated_at: row.updated_at
    }
  end

  defp get_item_row(%Item{} = item) do
    user_id = item.row_user_id || item.user_id

    WorkspaceItem
    |> maybe_where(:project_id, item.project_id)
    |> maybe_where(:user_id, user_id)
    |> item_identity_where(item.id)
    |> order_by([i], desc: i.updated_at, desc: i.created_at)
    |> limit(1)
    |> Repo.one()
  end

  defp presentation_user_id(%WorkspaceItem{source: "projection", metadata: metadata}) do
    case metadata || %{} do
      %{"owner_user_id" => owner_user_id} when is_binary(owner_user_id) and owner_user_id != "" ->
        owner_user_id

      _ ->
        nil
    end
  end

  defp presentation_user_id(%WorkspaceItem{} = row), do: row.user_id

  defp maybe_where(query, _field, nil), do: query
  defp maybe_where(query, field, value), do: where(query, [i], field(i, ^field) == ^value)

  defp maybe_exclude_archived_query(query, true), do: query

  defp maybe_exclude_archived_query(query, _include) do
    where(query, [i], i.status != "archived" and is_nil(i.archived_at))
  end

  defp visible_project(user_id, project_id) do
    with {:ok, %Project{} = project} <- Projects.get_project(project_id),
         true <- project_visible?(user_id, project.id) do
      {:ok, project}
    else
      _ -> {:error, :not_found}
    end
  end

  defp project_visible?(user_id, project_id) do
    match?(:ok, Memberships.authorize(user_id, :read, %{project_id: project_id}))
  end

  defp category_to_kind(category), do: Map.get(@category_to_kind, category, "work_item")

  defp kind_to_category(kind),
    do: Map.get(@kind_to_category, kind, if(kind in @categories, do: kind, else: "general"))

  defp normalize_category(category) when category in @categories, do: category
  defp normalize_category(_category), do: "general"

  defp normalize_platform(platform) when platform in @platforms, do: platform
  defp normalize_platform(_platform), do: "comma"

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(_status), do: "accepted"

  defp latest_artifact_from_payload(%{"vfs_path" => path}) when is_binary(path) and path != "" do
    %{"type" => "vfs", "path" => path}
  end

  defp latest_artifact_from_payload(_payload), do: nil

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp map_value(value, default \\ %{})
  defp map_value(value, _default) when is_map(value), do: value
  defp map_value(_value, default), do: default

  defp labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp labels(_labels), do: []

  defp timestamp(%DateTime{} = datetime), do: datetime

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp strip_empty_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> v in [nil, "", %{}, []] end)
    |> Map.new()
  end

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nonblank(_value), do: nil

  defp path_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "item"
      segment -> segment
    end
  end
end
