defmodule BridgeForTeams.DashboardProjection do
  @moduledoc """
  Local dashboard projection API for My Space.

  Page reads use snapshots through this module. Salix fan-out is limited to
  explicit refresh/rebuild calls and the reconciler worker.
  """

  import Ecto.Query

  alias BridgeForTeams.{
    Agents,
    Conversations,
    Memberships,
    ProjectOAuthConnections,
    Projects,
    Repo,
    WorkspaceItems
  }

  alias BridgeForTeams.Salix.Client
  alias BridgeForTeams.Schema.{Organization, Project, ProjectDashboardSnapshot}

  @conversation_limit 100
  @stale_after_seconds 300
  @call_timeout_ms 5_000
  @billing_timeout_ms 1_000
  @workspace_categories WorkspaceItems.categories()

  def topic(project_id), do: "bft:dashboard_projection:#{project_id}"

  def subscribe(project_id) do
    pubsub = Module.concat(Phoenix, PubSub)

    with true <- Code.ensure_loaded?(pubsub),
         pid when is_pid(pid) <- Process.whereis(BridgeForTeamsWeb.PubSub) do
      apply(pubsub, :subscribe, [BridgeForTeamsWeb.PubSub, topic(project_id)])
    else
      _ -> :ok
    end
  end

  def broadcast_refreshed(project_id) do
    pubsub = Module.concat(Phoenix, PubSub)

    with true <- Code.ensure_loaded?(pubsub),
         pid when is_pid(pid) <- Process.whereis(BridgeForTeamsWeb.PubSub) do
      apply(pubsub, :broadcast, [
        BridgeForTeamsWeb.PubSub,
        topic(project_id),
        {:dashboard_projection_refreshed, project_id}
      ])
    else
      _ -> :ok
    end
  end

  def enqueue_refresh(%Project{} = project), do: enqueue_refresh(project.id)
  def enqueue_refresh(nil), do: :ok

  def enqueue_refresh(project_id) when is_binary(project_id) do
    if Application.get_env(:bridge_for_teams_core, :dashboard_projection_auto_refresh, true) do
      BridgeForTeams.DashboardProjection.Reconciler.enqueue(project_id)
    else
      :ok
    end
  end

  def stale_or_missing?(%Project{} = project), do: stale_or_missing?(project.id)
  def stale_or_missing?(nil), do: false

  def stale_or_missing?(project_id) when is_binary(project_id) do
    case Repo.get(ProjectDashboardSnapshot, project_id) do
      nil -> true
      %ProjectDashboardSnapshot{stale_at: %DateTime{}} -> true
      %ProjectDashboardSnapshot{refreshed_at: nil} -> true
      %ProjectDashboardSnapshot{refreshed_at: refreshed_at} -> stale_datetime?(refreshed_at)
    end
  end

  def snapshot_for_project(project_id) when is_binary(project_id) do
    Repo.get(ProjectDashboardSnapshot, project_id)
  end

  def snapshots_for_projects(project_ids) when is_list(project_ids) do
    ProjectDashboardSnapshot
    |> where([s], s.project_id in ^project_ids)
    |> Repo.all()
    |> Map.new(&{&1.project_id, &1})
  end

  def mark_stale(%Project{} = project), do: mark_stale(project.id)

  def mark_stale(project_id) when is_binary(project_id) do
    now = DateTime.utc_now()

    case Repo.get(ProjectDashboardSnapshot, project_id) do
      nil ->
        with {:ok, %Project{} = project} <- Projects.get_project(project_id) do
          upsert_snapshot(project, %{stale_at: now})
        end

      %ProjectDashboardSnapshot{} = snapshot ->
        snapshot
        |> ProjectDashboardSnapshot.changeset(%{stale_at: now})
        |> Repo.update()
    end
  end

  def refresh_project(project_or_id, opts \\ [])

  def refresh_project(%Project{} = project, opts) do
    org = Repo.get(Organization, project.org_id)

    if not Keyword.get(opts, :durable_claim, false) do
      _ =
        update_snapshot_state(project, %{
          refreshing_at: DateTime.utc_now(),
          refresh_error: nil
        })
    end

    metadata = %{project_id: project.id, org_id: project.org_id}
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:bridge_for_teams, :dashboard_projection, :refresh, :start],
      %{},
      metadata
    )

    try do
      conversations = fetch_conversations(project)
      meetings = fetch_meetings(project)
      providers = fetch_providers(project)
      token_usage = fetch_token_usage(org, project)

      snapshot_attrs =
        conversations
        |> snapshot_attrs_from_sources(meetings, providers, token_usage)
        |> Map.merge(%{
          refresh_generation: Keyword.get(opts, :refresh_generation, 0),
          refreshed_at: DateTime.utc_now(),
          stale_at: nil,
          refreshing_at: nil,
          refresh_error: nil
        })

      {:ok, snapshot} =
        Repo.transaction(fn ->
          case Keyword.get(opts, :commit_guard, fn -> :ok end).() do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
            other -> Repo.rollback({:invalid_commit_guard_result, other})
          end

          {:ok, snapshot} = upsert_snapshot(project, snapshot_attrs)

          if Keyword.get(opts, :project_workspace_items, true) do
            case project_workspace_items(project, conversations, meetings, snapshot_attrs) do
              {:ok, _items} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          case Keyword.get(opts, :commit_ack, fn -> :ok end).() do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
            other -> Repo.rollback({:invalid_commit_ack_result, other})
          end

          snapshot
        end)

      broadcast_refreshed(project.id)
      emit_refresh_stop(start_time, metadata, :ok)
      {:ok, snapshot}
    rescue
      error ->
        reason = Exception.message(error)

        if not Keyword.get(opts, :durable_claim, false) do
          _ = update_snapshot_state(project, %{refreshing_at: nil, refresh_error: reason})
        end

        broadcast_refreshed(project.id)
        emit_refresh_stop(start_time, metadata, :error)
        {:error, reason}
    catch
      kind, reason ->
        message = Exception.format_banner(kind, reason)

        if not Keyword.get(opts, :durable_claim, false) do
          _ = update_snapshot_state(project, %{refreshing_at: nil, refresh_error: message})
        end

        broadcast_refreshed(project.id)
        emit_refresh_stop(start_time, metadata, :error)
        {:error, reason}
    end
  end

  def refresh_project(project_id, opts) when is_binary(project_id) do
    with {:ok, %Project{} = project} <- Projects.get_project(project_id) do
      refresh_project(project, opts)
    end
  end

  def project_conversations(%Project{} = project, conversations) when is_list(conversations) do
    rows =
      conversations
      |> Enum.filter(&workspace_conversation?/1)
      |> Enum.map(&workspace_item_from_conversation/1)

    project_workspace_item_rows(project, rows)
  end

  def rebuild_projects(projects, opts \\ []) when is_list(projects) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    max_concurrency = opts |> Keyword.get(:concurrency, 2) |> positive_integer(2)
    timeout = opts |> Keyword.get(:timeout, 30_000) |> positive_integer(30_000)

    projects
    |> Task.async_stream(
      fn project ->
        if dry_run? do
          {:dry_run, project.id, stale_or_missing?(project)}
        else
          {project.id, refresh_project(project, opts)}
        end
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Stream.zip(projects)
    |> Enum.map(fn
      {{:ok, result}, _project} ->
        result

      {{:exit, reason}, %Project{} = project} ->
        _ =
          update_snapshot_state(project, %{
            refreshing_at: nil,
            refresh_error: rebuild_exit_message(reason, timeout)
          })

        {project.id, {:error, {:task_exit, reason}}}
    end)
  end

  def upsert_snapshot(%Project{} = project, attrs) do
    attrs =
      attrs
      |> Map.put(:project_id, project.id)
      |> Map.put(:org_id, project.org_id)
      |> normalize_snapshot_attrs()

    %ProjectDashboardSnapshot{}
    |> ProjectDashboardSnapshot.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:project_id, :created_at]},
      conflict_target: [:project_id]
    )
  end

  defp update_snapshot_state(%Project{} = project, attrs) do
    case Repo.get(ProjectDashboardSnapshot, project.id) do
      nil ->
        upsert_snapshot(project, attrs)

      %ProjectDashboardSnapshot{} = snapshot ->
        snapshot
        |> ProjectDashboardSnapshot.changeset(attrs)
        |> Repo.update()
    end
  end

  defp fetch_conversations(%Project{} = project) do
    case call_with_retry(fn ->
           Conversations.list_project_conversations(project, limit: @conversation_limit)
         end) do
      {:ok, conversations} when is_list(conversations) -> conversations
      {:error, reason} -> raise "conversation refresh failed: #{inspect(reason)}"
      nil -> raise "conversation refresh timed out"
      other -> raise "conversation refresh returned invalid result: #{inspect(other)}"
    end
  end

  defp fetch_meetings(%Project{} = project) do
    client = Client.impl()

    if Code.ensure_loaded?(client) and function_exported?(client, :list_group_meetings, 1) do
      case call_with_retry(fn -> client.list_group_meetings(project.salix_group_id) end) do
        {:ok, meetings} when is_list(meetings) -> Enum.filter(meetings, &is_map/1)
        meetings when is_list(meetings) -> Enum.filter(meetings, &is_map/1)
        {:error, {:exception, _message}} -> []
        {:error, reason} -> raise "meeting refresh failed: #{inspect(reason)}"
        nil -> raise "meeting refresh timed out"
        other -> raise "meeting refresh returned invalid result: #{inspect(other)}"
      end
    else
      []
    end
  end

  defp fetch_providers(%Project{} = project) do
    client = Client.impl()

    if Code.ensure_loaded?(client) and function_exported?(client, :list_group_oauth_bindings, 1) do
      case call_with_retry(fn ->
             ProjectOAuthConnections.list_connections(project.org_id, project.id)
           end) do
        {:ok, connections} when is_list(connections) ->
          connections
          |> Enum.map(&provider_name/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {:error, {:exception, _message}} ->
          []

        {:error, reason} ->
          raise "provider refresh failed: #{inspect(reason)}"

        nil ->
          raise "provider refresh timed out"

        other ->
          raise "provider refresh returned invalid result: #{inspect(other)}"
      end
    else
      []
    end
  end

  defp fetch_token_usage(%Organization{salix_tenant_id: tenant_id}, %Project{} = project)
       when is_binary(tenant_id) and tenant_id != "" do
    project.id
    |> Agents.list_agents()
    |> Enum.map(fn agent -> billing_history(agent.salix_agent_id, tenant_id) end)
    |> Enum.reduce(empty_usage(), &merge_usage(&2, &1))
  end

  defp fetch_token_usage(_org, _project), do: empty_usage()

  defp billing_history(agent_id, tenant_id)
       when is_binary(agent_id) and agent_id != "" and is_binary(tenant_id) and tenant_id != "" do
    case call_with_retry(
           fn -> Client.impl().billing_history(agent_id, tenant_id, limit: 500) end,
           1,
           @billing_timeout_ms
         ) do
      {:ok, %{"data" => entries}} when is_list(entries) -> usage_from_entries(entries)
      {:ok, entries} when is_list(entries) -> usage_from_entries(entries)
      {:error, reason} -> raise "billing refresh failed: #{inspect(reason)}"
      nil -> empty_usage()
      other -> raise "billing refresh returned invalid result: #{inspect(other)}"
    end
  end

  defp billing_history(_agent_id, _tenant_id), do: empty_usage()

  defp snapshot_attrs_from_sources(conversations, meetings, providers, usage) do
    %{
      conversation_count: length(conversations),
      recent_conversations: Enum.take(Enum.map(conversations, &recent_conversation/1), 10),
      token_input: usage.input,
      token_output: usage.output,
      token_cache_read: usage.cache_read,
      token_cache_write: usage.cache_write,
      token_total: usage.total,
      connected_providers: providers,
      meeting_count: length(meetings),
      latest_meeting_at: latest_meeting_at(meetings)
    }
  end

  defp project_workspace_items(%Project{} = project, conversations, meetings, snapshot_attrs) do
    rows =
      conversations
      |> Enum.filter(&workspace_conversation?/1)
      |> Enum.map(&workspace_item_from_conversation/1)
      |> Kernel.++(
        Enum.map(meetings, &workspace_item_from_meeting/1) ++
          Enum.map(meetings, &workspace_item_from_meeting_recap/1) ++
          meeting_action_items(meetings) ++
          [
            workspace_item_from_metrics(snapshot_attrs),
            workspace_item_from_team_activity(snapshot_attrs)
          ]
      )

    project_workspace_item_rows(project, rows)
  end

  defp project_workspace_item_rows(%Project{} = project, rows) do
    visible_project_user_ids(project)
    |> Enum.reduce_while({:ok, []}, fn user_id, {:ok, acc} ->
      user_rows = reject_mock_owned_rows(rows, user_id, project.id)

      case WorkspaceItems.upsert_projected_items(project, user_id, user_rows) do
        {:ok, items} -> {:cont, {:ok, acc ++ items}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The projection's own builder rows: the metrics/team-activity singletons
  # plus the meeting mirrors. Rows projected from real Salix conversations are
  # NOT in this set.
  @builder_external_sources ~w(dashboard_projection salix_meeting salix_meeting_recap salix_meeting_action)

  # A user's live mock-import cards (`BridgeForTeams.WorkspaceImports`) own
  # their categories: skip writing builder rows there so a refresh never
  # stacks a live widget next to (or interleaves live rows into) an imported
  # demo category. Mock rows use `external_source: "mock_import"`, so upsert
  # identity can never overwrite them — without this skip the failure mode is
  # duplication, not clobbering. Self-healing: once the mock cards are
  # archived, the next refresh recreates the builder rows.
  defp reject_mock_owned_rows(rows, user_id, project_id) do
    owned = WorkspaceItems.mock_import_categories(user_id, project_id)

    if MapSet.size(owned) == 0 do
      rows
    else
      Enum.reject(rows, fn row ->
        row["external_source"] in @builder_external_sources and
          MapSet.member?(owned, row["category"])
      end)
    end
  end

  defp visible_project_user_ids(%Project{} = project) do
    org_admin_ids =
      project.org_id
      |> Memberships.list_org_members()
      |> Enum.filter(&(&1.role in ["owner", "admin"]))
      |> Enum.map(& &1.user_id)

    project_member_ids =
      project.id
      |> Memberships.list_project_members()
      |> Enum.map(& &1.user_id)

    [project.created_by_user_id | org_admin_ids ++ project_member_ids]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp workspace_item_from_conversation(conversation) do
    metadata = conversation["metadata"] |> map_value() |> Map.delete("workflow_summary")
    metadata = maybe_put(metadata, "owner_user_id", conversation["owner_user_id"])
    source_refs = map_value(conversation["source_refs"])
    payload = map_value(metadata["payload"])
    kind = conversation["kind"] || "work_item"
    category = workspace_category(kind, metadata)

    %{
      "title" => conversation["title"] || "Untitled",
      "kind" => kind,
      "category" => category,
      "status" => workspace_item_status(kind, conversation["status"]),
      "activity_status" => conversation["activity_status"],
      "source" => metadata["source"] || "projection",
      "platform" => metadata["platform"] || "comma",
      "description" => metadata["description"],
      "payload" => payload,
      "metadata" => metadata,
      "source_refs" => source_refs,
      "labels" => conversation["labels"] || [],
      "latest_artifact" => conversation["latest_artifact"],
      "artifact_manifest" => conversation["artifact_manifest"],
      "archived_at" => archive_timestamp(conversation, metadata),
      "external_source" => metadata["external_source"],
      "external_id" => metadata["external_id"],
      "salix_conversation_id" => conversation["conversation_id"],
      "salix_agent_id" => source_refs["agent_id"] || conversation_agent_id(conversation),
      "salix_schedule_id" => source_refs["schedule_id"],
      "vfs_path" => payload["vfs_path"],
      "synced_at" => DateTime.utc_now()
    }
  end

  defp workspace_category("agent_task", metadata) do
    case metadata["workspace_category"] do
      category when category in @workspace_categories -> category
      _missing_or_invalid -> "general"
    end
  end

  defp workspace_category(kind, _metadata), do: WorkspaceItems.category_for_kind(kind)

  defp workspace_conversation?(%{"kind" => kind}) when is_binary(kind),
    do: kind in WorkspaceItems.kinds()

  defp workspace_conversation?(_conversation), do: false

  defp workspace_item_status("agent_task", "active"), do: "in_progress"
  defp workspace_item_status("agent_task", "completed"), do: "done"

  defp workspace_item_status("agent_task", status)
       when status in ~w(failed cancelled escalated),
       do: status

  defp workspace_item_status(_kind, status)
       when status in ~w(suggested accepted in_progress ready_for_review done archived),
       do: status

  defp workspace_item_status("agent_task", _status), do: "in_progress"
  defp workspace_item_status(_kind, _status), do: "accepted"

  defp workspace_item_from_meeting(meeting) do
    %{
      "title" => meeting["title"] || meeting[:title] || "Meeting",
      "kind" => "meeting",
      "category" => "meetings",
      "status" => "accepted",
      "source" => "projection",
      "platform" => "comma",
      "payload" => map_value(meeting),
      "external_source" => "salix_meeting",
      "external_id" =>
        meeting["meeting_id"] || meeting[:meeting_id] || meeting["id"] || meeting[:id],
      "synced_at" => DateTime.utc_now()
    }
  end

  defp workspace_item_from_meeting_recap(meeting) do
    summary = map_value(meeting["summary"] || meeting[:summary])
    meeting_id = meeting["meeting_id"] || meeting[:meeting_id] || meeting["id"] || meeting[:id]
    title = summary["title"] || meeting["title"] || meeting[:title] || "Meeting"

    %{
      "title" => "#{title} — recap",
      "kind" => "meeting_recap",
      "category" => "meeting_recaps",
      "status" => "ready_for_review",
      "source" => "projection",
      "platform" => provider_name(meeting) || "comma",
      "payload" => %{
        "meeting_id" => meeting_id,
        "bullets" => List.wrap(summary["key_points"]),
        "date" => Date.utc_today() |> Date.to_iso8601()
      },
      "external_source" => "salix_meeting_recap",
      "external_id" => meeting_id,
      "synced_at" => DateTime.utc_now()
    }
  end

  defp meeting_action_items(meetings) do
    meetings
    |> Enum.flat_map(fn meeting ->
      summary = map_value(meeting["summary"] || meeting[:summary])
      meeting_id = meeting["meeting_id"] || meeting[:meeting_id] || meeting["id"] || meeting[:id]
      title = summary["title"] || meeting["title"] || meeting[:title] || "Meeting"

      summary
      |> Map.get("action_items", [])
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        item = map_value(item)

        %{
          "title" => item["description"] || item["title"] || "Follow up",
          "kind" => "work_item",
          "category" => "general",
          "status" => "accepted",
          "source" => "projection",
          "platform" => provider_name(meeting) || "comma",
          "payload" => %{
            "origin" => "meeting:#{meeting_id}:#{index}",
            "origin_title" => title,
            "owner" => item["owner"],
            "deadline" => item["deadline"]
          },
          "external_source" => "salix_meeting_action",
          "external_id" => "#{meeting_id}:#{index}",
          "synced_at" => DateTime.utc_now()
        }
      end)
    end)
  end

  defp workspace_item_from_metrics(attrs) do
    %{
      "title" => "Workspace metrics",
      "kind" => "metrics_snapshot",
      "category" => "metrics",
      "status" => "ready_for_review",
      "source" => "projection",
      "platform" => "comma",
      "payload" => %{
        "summary" => "Live from your workspace projection.",
        "hero" => %{
          "type" => "kpis",
          "items" => [
            %{"label" => "Conversations", "value" => to_string(attrs.conversation_count || 0)},
            %{"label" => "Meetings", "value" => to_string(attrs.meeting_count || 0)},
            %{"label" => "Tokens used", "value" => to_string(attrs.token_total || 0)}
          ]
        }
      },
      "external_source" => "dashboard_projection",
      "external_id" => "metrics",
      "synced_at" => DateTime.utc_now()
    }
  end

  defp workspace_item_from_team_activity(attrs) do
    recent = attrs.recent_conversations || []

    %{
      "title" => "Team activity",
      "kind" => "team_activity",
      "category" => "team_activity",
      "status" => "ready_for_review",
      "source" => "projection",
      "platform" => "comma",
      "payload" => %{
        "summary" => "#{length(recent)} workspace conversations updated.",
        "hero" => %{
          "type" => "entities",
          "items" =>
            Enum.map(recent, fn item ->
              %{"name" => item["title"] || "Untitled", "detail" => item["status"] || ""}
            end)
        }
      },
      "external_source" => "dashboard_projection",
      "external_id" => "team_activity",
      "synced_at" => DateTime.utc_now()
    }
  end

  defp call_with_retry(fun), do: call_with_retry(fun, 2, @call_timeout_ms)

  defp call_with_retry(fun, attempts_left, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          {:ok, fun.()}
        rescue
          error -> {:error, {:exception, Exception.message(error)}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        result

      {:ok, {:error, _reason}} when attempts_left > 1 ->
        call_with_retry(fun, attempts_left - 1, timeout_ms)

      {:ok, {:error, reason}} ->
        {:error, reason}

      _ when attempts_left > 1 ->
        call_with_retry(fun, attempts_left - 1, timeout_ms)

      _ ->
        nil
    end
  end

  defp emit_refresh_stop(start_time, metadata, status) do
    duration = System.monotonic_time() - start_time

    BridgeForTeams.Telemetry.emit_operation(
      :projection_refresh,
      if(status in [:ok, "ok"], do: :ok, else: :error),
      duration
    )

    :telemetry.execute(
      [:bridge_for_teams, :dashboard_projection, :refresh, :stop],
      %{duration: duration},
      Map.put(metadata, :status, status)
    )
  end

  defp rebuild_exit_message(:timeout, timeout), do: "rebuild refresh timed out after #{timeout}ms"
  defp rebuild_exit_message(reason, _timeout), do: "rebuild refresh exited: #{inspect(reason)}"

  defp recent_conversation(conversation) do
    %{
      "conversation_id" => conversation["conversation_id"],
      "title" => conversation["title"],
      "kind" => conversation["kind"],
      "status" => conversation["status"],
      "updated_at" => conversation["updated_at"] || conversation["created_at"]
    }
  end

  defp latest_meeting_at(meetings) do
    meetings
    |> Enum.map(
      &timestamp(&1["started_at"] || &1[:started_at] || &1["created_at"] || &1[:created_at])
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(DateTime)
    |> List.last()
  end

  defp provider_name(%{"provider" => provider}) when is_binary(provider), do: provider
  defp provider_name(%{provider: provider}) when is_binary(provider), do: provider
  defp provider_name(%{"toolkit" => toolkit}) when is_binary(toolkit), do: toolkit
  defp provider_name(%{toolkit: toolkit}) when is_binary(toolkit), do: toolkit
  defp provider_name(_), do: nil

  defp conversation_agent_id(%{"participants" => participants}) when is_list(participants) do
    participants
    |> Enum.find(&(&1["actor_type"] == "agent"))
    |> case do
      %{"agent_id" => agent_id} -> agent_id
      _ -> nil
    end
  end

  defp conversation_agent_id(_conversation), do: nil

  defp normalize_snapshot_attrs(attrs) do
    usage_total =
      attrs[:token_total] || attrs["token_total"] ||
        int(attrs[:token_input]) + int(attrs[:token_output]) + int(attrs[:token_cache_read]) +
          int(attrs[:token_cache_write])

    attrs
    |> Map.put_new(:conversation_count, 0)
    |> Map.put_new(:recent_conversations, [])
    |> Map.put_new(:token_input, 0)
    |> Map.put_new(:token_output, 0)
    |> Map.put_new(:token_cache_read, 0)
    |> Map.put_new(:token_cache_write, 0)
    |> Map.put(:token_total, usage_total)
    |> Map.put_new(:connected_providers, [])
    |> Map.put_new(:meeting_count, 0)
  end

  defp usage_from_entries(entries) do
    entries
    |> Enum.map(&usage_from_map/1)
    |> Enum.reduce(empty_usage(), &merge_usage(&2, &1))
  end

  defp usage_from_map(usage) when is_map(usage) do
    input = int(usage["prompt_tokens"] || usage[:prompt_tokens] || usage["input_tokens"])

    output =
      int(usage["completion_tokens"] || usage[:completion_tokens] || usage["output_tokens"])

    cache_read = int(usage["cache_read_input_tokens"] || usage[:cache_read_input_tokens])
    cache_write = int(usage["cache_write_input_tokens"] || usage[:cache_write_input_tokens])
    total = int(usage["total_tokens"] || usage[:total_tokens])
    total = if total > 0, do: total, else: input + output + cache_read + cache_write

    %{
      input: input,
      output: output,
      cache_read: cache_read,
      cache_write: cache_write,
      total: total
    }
  end

  defp usage_from_map(_), do: empty_usage()

  defp merge_usage(left, right) do
    %{
      input: left.input + right.input,
      output: left.output + right.output,
      cache_read: left.cache_read + right.cache_read,
      cache_write: left.cache_write + right.cache_write,
      total: left.total + right.total
    }
  end

  defp empty_usage, do: %{input: 0, output: 0, cache_read: 0, cache_write: 0, total: 0}

  defp int(value) when is_integer(value) and value >= 0, do: value
  defp int(value) when is_integer(value), do: 0

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp int(_), do: 0

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp map_value(value) when is_map(value), do: value
  defp map_value(_), do: %{}

  # Task archive time is owned by the Conversation; older non-Task projections
  # keep their existing metadata representation.
  defp archive_timestamp(%{"kind" => "agent_task", "archived_at" => value}, _metadata)
       when is_integer(value), do: DateTime.from_unix!(value, :millisecond)

  defp archive_timestamp(_conversation, metadata), do: metadata["archived_at"]

  defp timestamp(%DateTime{} = datetime), do: datetime

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_), do: nil

  defp stale_datetime?(%DateTime{} = refreshed_at) do
    DateTime.diff(DateTime.utc_now(), refreshed_at) > @stale_after_seconds
  end
end
