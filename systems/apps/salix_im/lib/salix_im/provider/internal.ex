defmodule SalixIM.Provider.Internal do
  require SystemsRuntime.Proc

  @moduledoc false

  import SalixIM.Provider.Util

  alias SalixIM.{
    ConversationAttachments,
    ConversationInput,
    ConversationParticipantActivity,
    ConversationParticipantProjection,
    Conversations,
    GroupDirectory,
    ProviderRecipientIdentity,
    TaskPlacement
  }

  alias SalixIM.Ports.{AgentWorkspace, StationHostedTasks, TaskCreate, TaskSchedule}
  alias SalixIM.Provider.Feishu.MeetingActivationAuthorization
  alias SalixIM.Triage.DelegationAuthorization
  alias SalixStore.Ids

  @delivery_filter_limit SalixIM.ConversationLimits.delivery_filter_limit()
  @inline_task_ref_limit SalixIM.ConversationLimits.inline_task_ref_limit()
  @task_list_default_limit 200
  @task_list_max_limit 1_000
  @task_dismiss_max 50
  @task_archive_max 50
  @task_list_cursor_max_length 1_024
  @task_files_default_limit 50
  @task_files_max_limit 200
  @conversation_update_string_fields ~w(kind status activity_status title owner_user_id)
  @conversation_update_map_fields ~w(metadata latest_artifact artifact_manifest source_refs)
  @title_batch_limit 20
  @send_message_params ~w(conversation_id content request_id delivery_filter mentions reply_to_message_id source_message_id)
  @router_task_apis ~w(internal.task.create internal.task.add_session internal.task.update internal.task.list internal.task.dismiss internal.task.archive internal.task.unarchive internal.list_task_files)
  @station_read_apis ~w(internal.usage.query internal.station_task.list)
  @station_read_roles ~w(router worker)
  @usage_by ~w(person model day source station task)
  @usage_sources ~w(self stillfail)
  @station_task_statuses ~w(in_progress needs_review done cancelled archived)
  @station_task_list_max 500
  @station_task_query_max 200
  @station_task_attentions ~w(need done failed)
  @router_label_apis ~w(internal.label.list internal.label.assign internal.label.propose)
  @label_propose_params ~w(op payload summary)
  @add_agent_participant_api "internal.add_agent_participant"
  @egress_archive_broker_key :egress_archive_reservation_broker
  @egress_archive_reservation_key :egress_archive_reservation
  defp label_proposal_next_action(%{"status" => "pending"}),
    do:
      "The change is pending until the user confirms it in Comma, in this chat or in Settings › Labels. Existing matching labels can already be assigned. Do not re-propose while it is pending."

  defp label_proposal_next_action(%{"application_status" => status})
       when status in ["pending", "conflict"],
       do:
         "The label change was approved, but the Task labels were not confirmed applied. Report application_error; do not claim the Task was labeled or overwrite later user choices."

  defp label_proposal_next_action(%{"status" => "approved"}),
    do:
      "The change was approved and applied under the workspace's label permission. Report the result; do not ask again."

  defp label_proposal_next_action(_proposal),
    do: "The proposal was rejected. Do not apply or re-propose it without new user direction."

  # A Task together (`SalixIM.Conversations.collaboration_task?/1`) is shared
  # with people outside its Group. Only its own Worker reads, searches or
  # changes it through these APIs; every other Agent of the Group, its host's
  # Router included, sees it only as a status and title in internal.task.list.
  @collaboration_closed "This is a Task together, private to the people in it and its own " <>
                          "Worker. Its status and title are in internal.task.list; do not read " <>
                          "or quote what is said in it."

  # The APIs that name a Conversation for another Agent to read or change.
  # `internal.send_message` is not among them: it writes only where the Agent
  # is a participant, and a Task together's delegator may not write.
  @collaboration_gated ~w(
    internal.read_conversation internal.list_conversation_participants
    internal.get_conversation_participant_status internal.update_conversation
    internal.update_conversation_titles internal.task.update internal.task.add_session internal.task.dismiss
    internal.task.archive internal.task.unarchive
    internal.list_task_files internal.label.assign internal.label.propose
    internal.add_agent_participant
  )

  def call(scope, api, params) when api in @collaboration_gated do
    case closed_collaborations(scope, collaboration_ids(params)) do
      [] -> scope |> call_api(api, params) |> hide_collaborations(scope, api)
      _closed -> {:error, @collaboration_closed}
    end
  end

  def call(scope, api, params), do: call_api(scope, api, params)

  defp collaboration_ids(params) when is_map(params) do
    ids =
      [params["conversation_id"], get_in(params, ["payload", "conversation_id"])] ++
        List.wrap(params["conversation_ids"]) ++
        Enum.map(List.wrap(params["titles"]), &(is_map(&1) && &1["conversation_id"]))

    ids
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.reject(&match?({_station, _thread}, StationHostedTasks.parse(&1)))
    |> Enum.uniq()
    |> Enum.take(200)
  end

  defp collaboration_ids(_params), do: []

  # The Tasks together among `ids` closed to this Agent (all but to their own
  # Worker), read in one query.
  defp closed_collaborations(_scope, []), do: []

  defp closed_collaborations(scope, ids) do
    agent_id = Map.get(scope, :agent_id)

    case SalixIM.ConversationPGStore.read_many(scope.group_id, ids) do
      {:ok, records} ->
        for {id, conversation} <- records,
            Conversations.collaboration_task?(conversation),
            not (is_binary(agent_id) and agent_id == conversation["task_worker_agent_id"]),
            do: id

      # Unread: closed, rather than open to every Agent.
      {:error, _} ->
        ids
    end
  end

  # The Group's files listing names the Tasks they came from: a Task
  # together's files stay with it. The page's Tasks are read in one query.
  defp hide_collaborations({:ok, %{"files" => files} = page}, scope, "internal.list_task_files")
       when is_list(files) do
    closed =
      files
      |> Enum.map(& &1["conversation_id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> then(&closed_collaborations(scope, &1))
      |> MapSet.new()

    kept = Enum.reject(files, &MapSet.member?(closed, &1["conversation_id"]))
    {:ok, %{page | "files" => kept} |> Map.put("count", length(kept))}
  end

  defp hide_collaborations(result, _scope, _api), do: result

  # ---- internal dispatch (willow callInternalProviderAPI) ----

  defp call_api(%{agent: %{"role" => "worker"}} = scope, "internal.triage.read_memory", params)
       when is_map(params),
       do: SalixIM.Triage.Investigation.read_memory(scope, params)

  defp call_api(%{agent: %{"role" => "worker"}} = scope, "internal.triage.read_context", params)
       when is_map(params) and map_size(params) == 0,
       do: SalixIM.Triage.Investigation.read_context(scope)

  defp call_api(%{agent: %{"role" => "worker"}} = scope, "internal.triage.read_source", params)
       when is_map(params) and map_size(params) == 0,
       do: SalixIM.Triage.Investigation.read_source(scope)

  defp call_api(%{agent: %{"role" => "worker"}} = scope, "internal.triage.complete", params)
       when is_map(params),
       do: SalixIM.Triage.Investigation.complete(scope, params)

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.task.create", params)
       when is_map(params),
       do: create_task(scope, params, scope.agent_id)

  # A Collaborative Task's Worker (`purpose: "collaboration_worker"`) may spawn
  # isolated sandbox sub-tasks (`runs_on: {"kind": "sandbox"}`). Its isolated
  # collaboration Group has no Router, so the Worker itself acts as delegator
  # and receives completion results (and generated files) back in its session:
  # - Repo-less, non-Mini-App sandboxes (e.g. PDF generation, scripts, file
  #   processing) are available to all active members and guests, billed to the
  #   host, with zero GitHub credentials.
  # - Sandboxes with a GitHub `repo` or `mini_app` remain strictly host-only.
  # Non-sandbox placement (`station`, `cloud_vm`, `default`) is always refused.
  defp call_api(
         %{agent: %{"role" => "worker", "purpose" => "collaboration_worker"}} = scope,
         "internal.task.create",
         params
       )
       when is_map(params) do
    with :ok <- collaboration_task_create_params(params),
         :ok <- require_collaboration_task_authority(scope, params),
         {:ok, task_id, task} <- worker_task(scope),
         :ok <- worker_task_depth(task) do
      create_task(scope, params, scope.agent_id,
        parent: task_id,
        origin: task_id
      )
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  # A Worker creates sandbox Tasks for work that needs a machine, where its
  # Group's Cloud VM is retired (`SalixIM.Sandboxes.cloud_vm_retired?/1`; until then
  # its env.exec reaches the Cloud VM): from within its own Task, and
  # only when a Router made that Task, so a Task a Worker created creates no
  # Task (one level). The Group's Router delegates the new Task: it takes the
  # result and tells the requester, as for a Task of its own. The new Task's
  # parent is the conversation the Worker's Task was made from (the Router
  # delivers results to a Task's parent), so its owner is that conversation's;
  # the Worker's Task is kept as its origin. How many a Worker creates is not
  # counted: the Group's live-sandbox limit and its credits bound it.
  defp call_api(%{agent: %{"role" => "worker"}} = scope, "internal.task.create", params)
       when is_map(params) do
    with :ok <- worker_task_create_enabled(scope.group_id),
         :ok <- worker_task_create_params(params),
         {:ok, task_id, task} <- worker_task(scope),
         :ok <- worker_task_depth(task),
         {:ok, router_agent_id} <- group_router(scope) do
      create_task(scope, params, router_agent_id,
        parent: worker_task_parent(task_id, task),
        origin: task_id
      )
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.task.add_session", params)
       when is_map(params),
       do: add_task_session(scope, params)

  defp call_api(
         %{agent: %{"role" => "router"}} = scope,
         "internal.task.update",
         %{"human_wakeup_policy" => policy} = params
       ) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id human_wakeup_policy),
             "im_api.internal.task.update"
           ),
         {:ok, id} <- required_string(params, "conversation_id"),
         true <- policy in SalixIM.TaskSessionSlots.human_wakeup_policies(),
         :ok <- authorize_task_update(scope),
         {:ok, %{"kind" => "agent_task"}} <- get_conversation(scope.group_id, id),
         :ok <- authorize_conversation_update(scope, id),
         {:ok, _updated} <-
           SalixIM.ConversationServer.update_group_conversation_metadata_key(
             scope.group_id,
             id,
             "human_wakeup_policy",
             policy
           ) do
      {:ok,
       %{
         "conversation_id" => id,
         "conversation_kind" => "agent_task",
         "human_wakeup_policy" => policy,
         "updated" => true
       }}
    else
      false ->
        {:error, "human_wakeup_policy must be \"primary_only\" or \"all_sessions\""}

      {:ok, _} ->
        {:error, "not an agent_task conversation"}

      {:error, reason} ->
        {:error, control_error(reason)}
    end
  end

  defp call_api(
         %{agent: %{"role" => "router"}} = scope,
         "internal.task.update",
         %{"github" => github} = params
       ) do
    with :ok <-
           validate_param_keys(params, ~w(conversation_id github), "im_api.internal.task.update"),
         {:ok, id} <- required_string(params, "conversation_id"),
         :ok <- authorize_task_update(scope),
         {:ok, %{"kind" => "agent_task", "runs_on" => %{"kind" => "sandbox"}}} <-
           get_conversation(scope.group_id, id),
         :ok <- authorize_conversation_update(scope, id),
         {:ok, saved} <- SalixIM.Ports.TaskStations.update_github(scope.group_id, id, github) do
      {:ok,
       %{
         "conversation_id" => id,
         "conversation_kind" => "agent_task",
         "github" => saved,
         "updated" => true,
         "next_action" =>
           "L4ES saved the complete GitHub ACL. Proxy delivery is asynchronous, and requests already in flight can finish under the previous ACL. A sandbox started without a grant needs another start to enable access."
       }}
    else
      {:ok, _} -> {:error, "The Task must run on a coding sandbox"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(
         %{agent: %{"role" => "router"}} = scope,
         "internal.task.update",
         %{"loop" => loop} = params
       )
       when is_map(loop) do
    context = SalixIM.Provider.current_tool_context()

    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id command loop),
             "im_api.internal.task.update"
           ),
         {:ok, id} <- required_string(params, "conversation_id"),
         {:ok, command} <- required_string(params, "command"),
         :ok <- authorize_task_update(scope),
         :ok <- authorize_conversation_update(scope, id),
         at when is_integer(at) <- human_turn_at(context),
         {:ok, request} <-
           SalixIM.TaskLoop.request(loop,
             now: SystemsClock.system_time(:millisecond),
             timezone: task_create_timezone(context, %{})
           ),
         :ok <- request_restarted_loop(scope, id, request, at),
         {:ok, conversation} <-
           SalixIM.ConversationServer.restart_task_loop(
             scope.group_id,
             id,
             request,
             command,
             scope.agent_id,
             context_value(context, "source_message_id"),
             at
           ) do
      {:ok,
       %{
         "conversation_id" => id,
         "conversation_kind" => "agent_task",
         "status" => conversation["status"],
         "loop" => SalixIM.TaskLoop.request_summary(request),
         "updated" => true
       }}
    else
      nil -> {:error, "A later user message must request the new Loop"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.task.update", params)
       when is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id command schedule),
             "im_api.internal.task.update"
           ),
         conversation_id when conversation_id != "" <- str(params["conversation_id"]),
         {:ok, schedule} <- task_schedule_update(params),
         :ok <- authorize_task_update(scope),
         {:ok, conversation} <-
           TaskSchedule.update_task_schedule(scope.group_id, conversation_id, schedule) do
      schedule = conversation["schedule"] || %{}

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "conversation_kind" => "agent_task",
         "schedule" => schedule,
         "scheduled" => str(schedule["schedule_id"]) != "",
         "updated" => true
       }}
    else
      "" -> {:error, "conversation_id is required"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.task.list", params)
       when is_map(params) do
    with {:ok, opts} <- task_list_options(params),
         {:ok, page} <- Conversations.list_group_conversations(scope.group_id, opts),
         {:ok, loops} <- task_list_loops(scope.group_id, page["data"]) do
      tasks =
        Enum.map(page["data"], &task_list_entry(&1, loops)) |> put_terminal_urls(scope.group_id)

      station_tasks = if opts[:cursor], do: [], else: station_task_entries(scope.group_id)

      {:ok,
       %{
         "tasks" => tasks,
         "count" => length(tasks),
         "has_more" => page["has_more"],
         "next_action" => task_list_next_action(page["has_more"], station_tasks != [])
       }
       |> maybe_put("next_cursor", page["next_cursor"])
       |> then(
         &if(station_tasks == [], do: &1, else: Map.put(&1, "station_tasks", station_tasks))
       )}
    else
      {:error, :not_found} -> {:error, "group not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.task.dismiss", params)
       when is_map(params) do
    with :ok <- validate_param_keys(params, ~w(conversation_ids), "im_api.internal.task.dismiss"),
         {:ok, ids} <- task_dismiss_ids(params["conversation_ids"]),
         :ok <- authorize_task_update(scope),
         {:ok, loops} <- task_list_loops_by_ids(scope.group_id, ids) do
      results = dismiss_tasks(scope, ids, loops)
      dismissed = Enum.count(results, &(&1["status"] == "dismissed"))

      {:ok,
       %{
         "results" => results,
         "dismissed_count" => dismissed,
         "skipped_count" => Enum.count(results, &(&1["status"] == "skipped"))
       }}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.task.archive", params)
       when is_map(params) do
    set_tasks_archived(scope, params, :archive, "im_api.internal.task.archive")
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.task.unarchive", params)
       when is_map(params) do
    set_tasks_archived(scope, params, :unarchive, "im_api.internal.task.unarchive")
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.list_task_files", params)
       when is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id query cursor limit),
             "im_api.internal.list_task_files"
           ),
         {:ok, read} <- task_files_read(params),
         {:ok, page} <- read_task_files(scope.group_id, read) do
      {:ok,
       %{"files" => page["files"], "count" => length(page["files"])}
       |> maybe_put("next_cursor", page["next_cursor"])
       |> Map.put(
         "next_action",
         "To give the person a file, read its Message with internal.read_conversation " <>
           "(conversation_id and message_id): the file is shared into your VFS at a path " <>
           "you can attach."
       )}
    else
      {:error, :indexing} ->
        {:error,
         "Task files are still being indexed after a release. Read the Task with " <>
           "internal.read_conversation meanwhile."}

      {:error, :invalid} ->
        {:error, "cursor, limit or query is invalid"}

      {:error, :unavailable} ->
        {:error, "Task files are unavailable now. Try again."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  # The Group's spending as its stations send it (`SalixStore.StationStats`),
  # the still.fail workspaces' among it: the raw facts a Router, or a Worker
  # of one of its Tasks, adds up into what each member spends and on which
  # Task. `device_id` keeps one still.fail workspace's.
  defp call_api(%{agent: %{"role" => role}} = scope, "internal.usage.query", params)
       when role in @station_read_roles and is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(from to by source person device_id),
             "im_api.internal.usage.query"
           ),
         {:ok, by} <- usage_by(params["by"]),
         {:ok, source} <- usage_source(params["source"]),
         {:ok, person} <- optional_text(params, "person"),
         {:ok, device} <- optional_text(params, "device_id"),
         {:ok, rows} <-
           SalixStore.StationStats.usage(
             scope.group_id,
             str(params["from"]),
             str(params["to"]),
             by,
             source,
             person,
             device
           ) do
      {:ok, %{"by" => Atom.to_string(by), "rows" => rows, "count" => length(rows)}}
    else
      {:error, :invalid_span} ->
        {:error, "from and to must be days YYYY-MM-DD, to not before from, at most 366 days"}

      {:error, :invalid_grouping} ->
        {:error, "by must be one of #{Enum.join(@usage_by, ", ")}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}
    end
  end

  # The Tasks the Group's stations host (`SalixStore.StationTaskIndex`), a
  # page at a time, with who created each and, for a still.fail workspace's
  # chat, the workspace's name (one read of the Group's still.fail devices a
  # page).
  defp call_api(%{agent: %{"role" => role}} = scope, "internal.station_task.list", params)
       when role in @station_read_roles and is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(source since created_by status attention waits_for device_id query limit cursor),
             "im_api.internal.station_task.list"
           ),
         {:ok, opts} <- station_task_list_options(params) do
      {rows, more?} = SalixStore.StationTaskIndex.page_group(scope.group_id, opts)
      workspaces = stillfail_workspace_names(scope.group_id, rows)

      tasks =
        Enum.map(rows, fn row ->
          %{
            "task_id" => StationHostedTasks.ref(row.station_id, row.thread),
            "title" => row.title,
            "status" => row.status,
            "created_by" => row.created_by,
            "created_at" => row.created_at,
            "last_activity_at" => row.last_activity_at,
            "hosted_on" => row.device_id,
            "runtime" => row.runtime,
            "model" => row.model,
            "labels" => row.labels || []
          }
          |> maybe_put("attention", row.attention)
          |> maybe_put("card_kind", station_card_kind(row))
          |> maybe_put("waits_for", if(row.waits_for not in [nil, []], do: row.waits_for))
          |> maybe_put("note", row.note)
          |> maybe_put("url", row.url)
          |> maybe_put("router", if(row.router, do: true))
          |> maybe_put("workspace_name", workspaces[row.device_id])
        end)

      {:ok,
       %{"tasks" => tasks, "count" => length(tasks), "has_more" => more?}
       |> maybe_put("next_cursor", if(more?, do: station_task_cursor(List.last(rows))))}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}}, api, _params) when api in @router_task_apis,
    do: {:error, "params must be a JSON object"}

  defp call_api(%{agent: %{"role" => role}}, api, _params)
       when role in @station_read_roles and api in @station_read_apis,
       do: {:error, "params must be a JSON object"}

  defp call_api(_scope, api, _params) when api in @station_read_apis,
    do: {:error, "operation is not authorized for this agent role"}

  defp call_api(_scope, api, _params) when api in @router_task_apis,
    do: {:error, "operation is not authorized for this agent role"}

  # ---- Mini Apps (router, or collaboration_worker on host command) ----

  defp call_api(
         %{agent: %{"role" => "worker", "purpose" => "collaboration_worker"}} = scope,
         "internal.apps.create",
         params
       )
       when is_map(params) do
    with :ok <- require_collaboration_host_command(scope, "create Mini Apps"),
         :ok <-
           validate_param_keys(params, ~w(name description repo), "im_api.internal.apps.create"),
         {:ok, name} <- required_string(params, "name"),
         {:ok, app_params} <- apps_create_params(params, name),
         {:ok, task_id, _task} <- worker_task(scope),
         {:ok,
          %{
            "app_id" => app_id,
            "repo" => %{"owner" => owner, "name" => repo_name},
            "url" => url
          }}
         when is_binary(url) <-
           SalixIM.MiniApps.create(
             %{
               tenant_id: scope.tenant_id,
               group_id: scope.group_id,
               agent_id: scope.agent_id,
               conversation_id: task_id,
               trusted_origin:
                 context_value(SalixIM.Provider.current_tool_context(), "trusted_origin")
             },
             app_params
           ) do
      {:ok,
       %{"app_id" => app_id, "repo" => %{"owner" => owner, "name" => repo_name}, "url" => url}}
    else
      {:ok, _other} -> {:error, "the app owner answered without app_id, repo and url"}
      {:error, reason} -> {:error, apps_create_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.apps.create", params)
       when is_map(params) do
    with :ok <-
           validate_param_keys(params, ~w(name description repo), "im_api.internal.apps.create"),
         {:ok, name} <- required_string(params, "name"),
         {:ok, app_params} <- apps_create_params(params, name),
         {:ok,
          %{
            "app_id" => app_id,
            "repo" => %{"owner" => owner, "name" => repo_name},
            "url" => url
          }}
         when is_binary(url) <-
           SalixIM.MiniApps.create(
             %{
               tenant_id: scope.tenant_id,
               group_id: scope.group_id,
               agent_id: scope.agent_id,
               trusted_origin:
                 context_value(SalixIM.Provider.current_tool_context(), "trusted_origin")
             },
             app_params
           ) do
      {:ok,
       %{"app_id" => app_id, "repo" => %{"owner" => owner, "name" => repo_name}, "url" => url}}
    else
      {:ok, _other} -> {:error, "the app owner answered without app_id, repo and url"}
      {:error, reason} -> {:error, apps_create_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}}, "internal.apps.create", _params),
    do: {:error, "params must be a JSON object"}

  defp call_api(_scope, "internal.apps.create", _params),
    do: {:error, "operation is not authorized for this agent role"}

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.apps.list", params)
       when is_map(params) do
    with :ok <- validate_param_keys(params, [], "im_api.internal.apps.list"),
         {:ok, %{"apps" => apps, "has_more" => has_more}} when is_list(apps) <-
           SalixIM.MiniApps.list(scope.group_id) do
      {:ok, %{"apps" => apps, "has_more" => has_more == true}}
    else
      {:ok, _other} -> {:error, "the app owner answered without apps"}
      {:error, reason} -> {:error, apps_read_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.apps.get", params)
       when is_map(params) do
    with :ok <- validate_param_keys(params, ~w(app_id), "im_api.internal.apps.get"),
         {:ok, app_id} <- required_string(params, "app_id"),
         {:ok, %{"app_id" => _} = app} <- SalixIM.MiniApps.get(scope.group_id, app_id) do
      {:ok, app}
    else
      {:ok, _other} -> {:error, "the app owner answered without the app"}
      {:error, reason} -> {:error, apps_read_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}}, api, _params)
       when api in ["internal.apps.list", "internal.apps.get"],
       do: {:error, "params must be a JSON object"}

  defp call_api(_scope, api, _params) when api in ["internal.apps.list", "internal.apps.get"],
    do: {:error, "operation is not authorized for this agent role"}

  defp call_api(scope, "internal.apps." <> _action = api, params),
    do: SalixIM.Provider.Apps.call(scope, api, params)

  # ---- task labels (router only; catalog writes are human-confirmed proposals) ----

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.label.list", params)
       when is_map(params) do
    with :ok <- validate_param_keys(params, [], "im_api.internal.label.list"),
         {:ok, catalog} <- SalixIM.TaskLabels.list(scope.group_id) do
      {:ok,
       %{
         "labels" => catalog["labels"],
         "approval_policy" => catalog["approval_policy"],
         "pending_proposals" => Enum.filter(catalog["proposals"], &(&1["status"] == "pending")),
         "colors" => catalog["colors"]
       }}
    else
      {:error, :not_found} -> {:error, "group not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.label.assign", params)
       when is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id label_ids),
             "im_api.internal.label.assign"
           ),
         {:ok, conversation_id} <- required_string(params, "conversation_id"),
         {:ok, conversation} <-
           SalixIM.TaskLabels.assign(scope.group_id, conversation_id, params["label_ids"]) do
      {:ok,
       Map.take(conversation, ~w(conversation_id labels label_revision))
       |> Map.put("applied", true)}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.label.propose", params)
       when is_map(params) do
    tool_context = SalixIM.Provider.current_tool_context()

    with :ok <-
           validate_param_keys(params, @label_propose_params, "im_api.internal.label.propose"),
         {:ok, _op} <- required_string(params, "op"),
         {:ok, proposal} <-
           SalixIM.TaskLabels.propose(scope.group_id, params, %{
             "agent_id" => scope.agent_id,
             "session_id" => context_value(tool_context, "session_id"),
             "tool_call_id" => Map.get(scope, :tool_call_id),
             "source_conversation_id" =>
               proposal_source_conversation_id(scope.group_id, tool_context)
           }) do
      {:ok,
       Map.merge(proposal, %{
         "proposed" => true,
         "next_action" => label_proposal_next_action(proposal)
       })}
    else
      {:error, :not_found} -> {:error, "group or conversation not found"}
      # A duplicate name is a conflict the agent should read as plain text.
      {:error, {:conflict, message}} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}}, api, _params) when api in @router_label_apis,
    do: {:error, "params must be a JSON object"}

  defp call_api(_scope, api, _params) when api in @router_label_apis,
    do: {:error, "operation is not authorized for this agent role"}

  defp call_api(%{agent: %{"role" => "router"}} = scope, @add_agent_participant_api, params)
       when is_map(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id agent_id role_label notification_filter),
             "im_api.internal.add_agent_participant"
           ),
         {:ok, conversation_id} <- required_string(params, "conversation_id"),
         {:ok, agent_id} <- required_string(params, "agent_id"),
         {:ok, agent_id} <- task_create_group_agent(scope, agent_id),
         {:ok, attrs} <- add_agent_participant_attrs(params, agent_id),
         {:ok, participant} <-
           ConversationInput.ensure_group_conversation_agent_participant(
             scope.group_id,
             conversation_id,
             attrs
           ) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participant_id" => participant["participant_id"],
         "agent_id" => agent_id,
         "role_label" => participant["role_label"],
         "notification_filter" => participant["notification_filter"],
         "state" => participant["state"]
       }}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}}, @add_agent_participant_api, _params),
    do: {:error, "params must be a JSON object"}

  defp call_api(_scope, @add_agent_participant_api, _params),
    do: {:error, "operation is not authorized for this agent role"}

  defp call_api(scope, "internal.search_conversations", params) do
    query = str(params["query"])
    limit = int_or(params["limit"], 0)
    opts = if limit > 0, do: [limit: limit], else: []

    case Conversations.search_group_conversations(scope.group_id, query, opts) do
      {:ok, results} -> {:ok, %{"results" => results}}
      {:error, :not_found} -> {:error, "group not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(scope, "internal.read_conversation", params) do
    case {scope.agent["role"], StationHostedTasks.parse(str(params["conversation_id"]))} do
      {role, {station_id, thread}} when role in @station_read_roles ->
        read_station_task(scope, station_id, thread, params)

      _conversation ->
        read_conversation(scope, params)
    end
  end

  defp call_api(scope, "internal.list_conversation_participants", params) do
    conversation_id = str(params["conversation_id"])
    limit = int_or(params["limit"], 0)
    opts = if limit > 0, do: [limit: limit], else: []

    with {:ok, participants} <-
           list_conversation_participants(scope.group_id, conversation_id, opts) do
      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => public_participants(participants)
       }}
    end
  end

  defp call_api(scope, "internal.get_conversation_participant_status", params) do
    conversation_id = str(params["conversation_id"])
    participant_id = str(params["participant_id"])

    with {:ok, participant} <-
           get_conversation_participant(scope.group_id, conversation_id, participant_id),
         {:ok, status} <- participant_status(scope.group_id, conversation_id, participant) do
      {:ok, status}
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, participant_status_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}} = scope, "internal.update_conversation", params)
       when is_map(params) do
    case update_conversation(scope, params) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}}, "internal.update_conversation", _params),
    do: {:error, "params must be a JSON object"}

  defp call_api(_scope, "internal.update_conversation", _params),
    do: {:error, "operation is not authorized for this agent role"}

  defp call_api(
         %{agent: %{"role" => "router"}} = scope,
         "internal.update_conversation_titles",
         params
       )
       when is_map(params) do
    with :ok <-
           validate_param_keys(params, ["titles"], "im_api.internal.update_conversation_titles"),
         {:ok, titles} <- validate_title_batch(params["titles"]) do
      results =
        Enum.map(titles, fn %{"conversation_id" => id, "title" => title} ->
          case update_conversation(scope, %{"conversation_id" => id, "title" => title}) do
            {:ok, updated} ->
              %{"conversation_id" => id, "updated" => true, "title" => updated["title"]}

            {:error, reason} ->
              %{"conversation_id" => id, "updated" => false, "error" => control_error(reason)}
          end
        end)

      {:ok,
       %{
         "results" => results,
         "updated_count" => Enum.count(results, & &1["updated"]),
         "failed_count" => Enum.count(results, &(not &1["updated"]))
       }}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp call_api(%{agent: %{"role" => "router"}}, "internal.update_conversation_titles", _params),
    do: {:error, "params must be a JSON object"}

  defp call_api(_scope, "internal.update_conversation_titles", _params),
    do: {:error, "operation is not authorized for this agent role"}

  defp call_api(scope, "internal.send_message", params) when is_map(params) do
    SalixIM.SendTiming.run("im_send_total", fn -> send_message(scope, params) end)
  end

  defp call_api(_scope, "internal.send_message", _params),
    do: {:error, "params must be a JSON object"}

  defp call_api(_scope, _api, _params), do: {:error, "unsupported internal provider api"}

  defp update_conversation(scope, params) do
    mutable_fields =
      @conversation_update_string_fields ++ @conversation_update_map_fields ++ ["labels"]

    with :ok <-
           validate_param_keys(
             params,
             ["conversation_id" | mutable_fields],
             "im_api.internal.update_conversation"
           ),
         {:ok, conversation_id} <- required_string(params, "conversation_id"),
         {:ok, conversation} <- get_conversation(scope.group_id, conversation_id),
         :ok <- authorize_conversation_update(scope, conversation_id),
         {:ok, update} <-
           params
           |> Map.drop(["conversation_id"])
           |> validate_conversation_update(),
         {:ok, activation_provenance} <-
           MeetingActivationAuthorization.provenance_for_tool_context(
             scope.group_id,
             SalixIM.Provider.current_tool_context()
           ),
         {:ok, destination_provenance} <-
           MeetingActivationAuthorization.provenance_for_conversation(conversation),
         {:ok, effective_provenance} <-
           MeetingActivationAuthorization.merge_provenance([
             activation_provenance,
             destination_provenance
           ]),
         :ok <- validate_activation_conversation_update(effective_provenance, update),
         {:ok, updated} <-
           SalixIM.ConversationServer.update_group_conversation(
             scope.group_id,
             conversation_id,
             update
             |> Map.put(:router_agent_id, scope.agent_id)
             |> Map.put(
               :router_human_turn_at,
               human_turn_at(SalixIM.Provider.current_tool_context())
             )
           ) do
      {:ok,
       updated
       |> Map.take(
         ~w(conversation_id kind status activity_status title owner_user_id labels metadata latest_artifact artifact_manifest source_refs updated_at)
       )
       |> Map.put("updated", true)
       |> put_updated_task_loop(scope, updated, update)}
    end
  end

  # Surface the Task's Loop state on status updates via `internal.update_conversation`
  # so the Router never mistakes an ended Loop Task reopened with `status=active`
  # for an active Automated Loop (and title-only updates skip the Loop read).
  # Best-effort read: never fail an already-committed update.
  defp put_updated_task_loop(
         result,
         scope,
         %{"kind" => "agent_task"} = updated,
         %{"status" => _status}
       ) do
    case SalixIM.TaskLoop.get(scope.group_id, updated["conversation_id"]) do
      {:ok, %{"trigger" => %{}} = view} ->
        result
        |> Map.put("loop", SalixIM.TaskLoop.summary(view))
        |> maybe_put_task_loop_notice(updated["status"], view)

      _other ->
        result
    end
  end

  defp put_updated_task_loop(result, _scope, _updated, _update), do: result

  defp maybe_put_task_loop_notice(result, "active", %{"status" => "ended"} = view) do
    reason = view["ended_reason"] || "ended"

    Map.put(
      result,
      "task_loop_notice",
      "This Task's Background Loop ended (#{reason}) and was not restarted. " <>
        "Setting status=active alone turns it into an ordinary active Task outside Automated. " <>
        "To restore automated runs after a user request, call im_api.internal.task.update with loop and command."
    )
  end

  defp maybe_put_task_loop_notice(result, status, _view)
       when status in ~w(completed cancelled failed) do
    Map.put(
      result,
      "task_loop_notice",
      "Ending this Task with status=#{status} also ended its Background Loop for good. " <>
        "Future automated runs will not fire; restoring automation later requires a new user request and im_api.internal.task.update with loop and command."
    )
  end

  defp maybe_put_task_loop_notice(result, _status, _view), do: result

  defp validate_title_batch(titles)
       when is_list(titles) and titles != [] and length(titles) <= @title_batch_limit do
    ids = Enum.map(titles, &(is_map(&1) && &1["conversation_id"]))

    cond do
      not Enum.all?(titles, &valid_title_entry?/1) ->
        {:error, "each titles entry needs a non-empty conversation_id and title string"}

      length(Enum.uniq(ids)) != length(ids) ->
        {:error, "titles must not repeat a conversation_id"}

      true ->
        {:ok, titles}
    end
  end

  defp validate_title_batch(_titles),
    do: {:error, "titles must be a list of 1 to #{@title_batch_limit} entries"}

  defp valid_title_entry?(%{"conversation_id" => id, "title" => title} = entry),
    do:
      map_size(entry) == 2 and is_binary(id) and String.trim(id) != "" and is_binary(title) and
        String.trim(title) != ""

  defp valid_title_entry?(_entry), do: false

  defp authorize_conversation_update(scope, conversation_id) do
    with {:ok, participants} <-
           ConversationParticipantProjection.list_bounded(scope.group_id, conversation_id) do
      case current_agent_participant(participants, scope.agent_id) do
        %{"state" => "active"} ->
          :ok

        %{} ->
          {:error, "current Agent participant is not active"}

        nil ->
          {:error, "current Agent is not a Conversation participant"}
      end
    end
  end

  defp create_task(scope, params, delegator_agent_id, opts \\ []) do
    with {:ok, command} <- task_create_command(scope, params),
         command = put_source_refs(command, opts[:parent], opts[:origin]) do
      case TaskCreate.create_task_conversation(
             scope.group_id,
             delegator_agent_id,
             command.target_agent_id,
             command.attrs
           ) do
        {:ok, result} ->
          attach_task_request(scope.group_id, command.attrs, result)

          with {:ok, response} <- task_create_response(result, command),
               do: {:ok, put_terminal_url(response, scope.group_id, command.attrs["runs_on"])}

        {:error, {:conflict, _} = reason} ->
          task_create_conflict(scope, command, reason)

        {:error, reason} ->
          {:error, control_error(reason)}
      end
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  # `own_work` only drops the current person as the Task's routing source
  # (`SalixAgent.Tools.TaskCard`); a source selection asks the opposite.
  defp validate_own_work(%{"own_work" => own_work} = params) do
    cond do
      not is_boolean(own_work) ->
        {:error, "own_work must be a boolean"}

      own_work and
          Enum.any?(~w(triage_delegation_ref source_message_id), &Map.has_key?(params, &1)) ->
        {:error, "own_work cannot be combined with triage_delegation_ref or source_message_id"}

      true ->
        :ok
    end
  end

  defp validate_own_work(_params), do: :ok

  defp task_create_command(scope, params) do
    tool_context = SalixIM.Provider.current_tool_context()
    content = to_string_safe(params["content"])
    title = to_string_safe(params["title"])
    schedule = params["schedule"]
    origin_metadata = task_origin_metadata(scope, tool_context)

    with :ok <-
           if(Enum.any?(~w(requester_user_id automatic_task_place), &Map.has_key?(params, &1)),
             do: {:error, "requester_user_id is not a Task parameter"},
             else: :ok
           ),
         :ok <-
           if(Map.has_key?(params, "workflow"),
             do: {:error, "Task graph creation is retired; supply agent_id and content"},
             else: :ok
           ),
         :ok <- validate_task_create_params(content, schedule),
         :ok <- validate_task_request(scope, params["task_request_id"]),
         :ok <- validate_own_work(params),
         {:ok, loop} <- task_create_loop(params, schedule, tool_context, origin_metadata),
         {:ok, target_agent_id} <- task_create_worker(scope, params),
         {:ok, labels} <-
           SalixIM.TaskLabels.validate_initial_labels(scope.group_id, params["label_ids"] || []),
         {:ok, triage} <- DelegationAuthorization.prepare(scope, tool_context, params),
         {:ok, provenance_refs} <-
           task_create_provenance(scope, tool_context, schedule || loop),
         {:ok, trusted_origin} <- task_create_trusted_origin(scope, tool_context),
         {:ok, pre_sessions} <-
           prevalidate_task_create_sessions(scope, params, loop, schedule, triage),
         {:ok, params} <- maybe_lift_primary_session_model(params, pre_sessions),
         {:ok, params} <- task_create_place(params),
         {:ok, target_agent_id, public_target} <-
           task_create_target(scope, target_agent_id),
         {:ok,
          %{
            params: params,
            runs_on: runs_on,
            repo: repo,
            mini_app: mini_app,
            session_model: session_model,
            source: place_source
          }} <-
           task_create_placement(
             Map.put(
               scope,
               :task_request_identity,
               task_create_request_id(
                 scope,
                 tool_context,
                 trusted_origin,
                 task_create_target_identity(
                   target_agent_id,
                   if(is_list(pre_sessions.sessions), do: nil, else: params["model"]),
                   nil
                 )
                 |> task_request_identity(params),
                 content,
                 title,
                 if(loop, do: %{"loop" => loop}, else: schedule)
               )
             ),
             target_agent_id,
             params,
             is_map(loop)
           ),
         {:ok, execution_refs} <-
           SalixIM.TaskExecution.prepare(scope, tool_context, params, target_agent_id),
         {:ok, multi_session} <-
           finalize_task_create_sessions(
             scope,
             pre_sessions,
             target_agent_id,
             runs_on,
             session_model
           ),
         {:ok, initial_attachments} <- task_create_initial_attachments(scope, params["files"]) do
      session_id = context_value(tool_context, "session_id")

      source_refs =
        %{}
        |> put_present("origin_agent_id", scope.agent_id)
        |> put_present(
          "parent_conversation_id",
          trusted_origin && trusted_origin["conversation_id"]
        )
        |> put_present("parent_message_id", trusted_origin && trusted_origin["message_id"])
        |> put_present("origin_session_id", session_id)
        |> Map.merge(provenance_refs)
        |> Map.merge(SalixIM.TaskReplySource.source_refs(scope, tool_context))
        |> Map.merge(task_ifc_refs(scope, tool_context))
        |> Map.merge(task_origin_chat_refs(tool_context))
        |> Map.merge(execution_refs)
        |> Map.merge(SalixIM.TaskContinuation.source_refs(scope, tool_context, params))
        |> put_present("task_request_id", params["task_request_id"])

      attrs =
        %{
          "content" => content,
          "title" => title,
          "schedule" => schedule,
          "client_request_id" =>
            task_create_request_id(
              scope,
              tool_context,
              trusted_origin,
              # A model choice and a place to run are part of the command; a
              # plain command keeps its earlier identity.
              # The Group's default place is not part of it either, as its
              # default Task model is not: a create asked again after the
              # default changed is the same Task.
              task_create_target_identity(
                target_agent_id,
                if(is_list(pre_sessions.sessions), do: nil, else: session_model),
                if(place_source in [:default, :automatic],
                  do: nil,
                  else: place_identity(runs_on, repo, mini_app)
                )
              )
              |> task_request_identity(params)
              |> task_files_identity(params["files"]),
              content,
              title,
              # A Loop request is part of the command; it never comes with a
              # schedule, so a Task without one keeps its earlier identity.
              if(loop, do: %{"loop" => loop}, else: schedule)
            ),
          "origin_session_id" => session_id,
          "source_refs" => source_refs,
          "conversation_metadata" => origin_metadata,
          "labels" => labels
        }
        |> put_present("loop", loop)
        |> put_present(
          "owner_user_id",
          get_in(execution_refs, ["task_execution", "requester_id"])
        )
        |> put_present("session_model", session_model)
        |> put_present("runs_on", runs_on)
        |> put_present("repo", repo)
        |> put_present("mini_app", mini_app)
        |> put_present("automatic_task_place", if(place_source == :automatic, do: true))
        |> put_present("sessions", multi_session.sessions)
        |> put_present("initial_wake", multi_session.initial_wake)
        |> put_present("human_wakeup_policy", multi_session.human_wakeup_policy)
        |> then(fn map ->
          if initial_attachments == [],
            do: map,
            else: Map.put(map, "initial_attachments", initial_attachments)
        end)

      attrs =
        if triage do
          attrs
          |> Map.delete("origin_session_id")
          |> Map.put("client_request_id", triage.request_id)
          # Product-owned investigations already carry stable, read-only sources.
          # Do not mix the current delivery origin into their idempotent command.
          |> Map.put(
            "source_refs",
            triage.source_refs
            |> Map.merge(task_ifc_refs(scope, tool_context))
            |> Map.merge(task_origin_chat_refs(tool_context))
          )
        else
          attrs
        end

      {:ok,
       %{
         attrs: attrs,
         public_target: public_target,
         target_agent_id: target_agent_id,
         title: title,
         triage: triage
       }}
    end
  end

  defp task_create_conflict(scope, %{triage: %{request_id: request_id}}, _reason) do
    existing =
      case SalixIM.ConversationServer.lookup_task_create_request(scope.group_id, request_id) do
        {:ok, result} -> result
        {:error, _reason} -> %{"disposition" => "unavailable"}
      end

    {:error,
     Jason.encode!(%{
       "error" => "triage_delegation_conflict",
       "message" =>
         "This handoff already reserved a different immutable Task command. Do not create a replacement; inspect or continue the existing Task when available.",
       "existing_task" => existing
     })}
  end

  defp task_create_conflict(_scope, _command, reason), do: {:error, control_error(reason)}

  # A Task made for a Task request says so in its source refs, once the product
  # knows the request: its result can report only that request.
  defp validate_task_request(_scope, nil), do: :ok

  defp validate_task_request(scope, id) when is_binary(id) do
    module = SystemsRuntime.get_env(:salix_agent, :task_request_adapter_mod)

    if module && module.request_accepted?(id, scope.group_id),
      do: :ok,
      else: {:error, "task_request_id is not an accepted request of this workspace"}
  end

  defp validate_task_request(_scope, _id), do: {:error, "task_request_id must be a string"}

  defp attach_task_request(
         group_id,
         %{"source_refs" => %{"task_request_id" => request_id}},
         %{"conversation_id" => task_id} = result
       )
       when is_binary(request_id) and is_binary(task_id) do
    module = SystemsRuntime.get_env(:salix_agent, :task_request_adapter_mod)

    if module && Code.ensure_loaded?(module) && function_exported?(module, :attach_task, 4) do
      _ = module.attach_task(request_id, group_id, task_id, result["status"])
    end

    :ok
  end

  defp attach_task_request(_group_id, _attrs, _result), do: :ok

  defp validate_task_create_params(content, schedule) do
    cond do
      content == "" ->
        {:error, "content is required"}

      not is_nil(schedule) and not is_map(schedule) ->
        {:error, "schedule must be an object"}

      is_map(schedule) and str(schedule["cron"]) != "" and
          str(schedule["timezone"]) == "" ->
        {:error,
         "schedule.timezone is required with schedule.cron; ask the user if it is unclear"}

      true ->
        :ok
    end
  end

  # A new human request after the Task's Loop ended writes the Loop it asks
  # for. A request repeated after a failed restart finds that Loop pending.
  defp request_restarted_loop(scope, id, request, human_at) do
    with {:ok, conversation} <- Conversations.get_group_conversation(scope.group_id, id),
         :ok <- SalixIM.TaskLoop.restart_allowed(conversation, scope.agent_id, human_at),
         :ok <- restart_inside_salix(scope, id, conversation),
         {:ok, view} <- SalixIM.TaskLoop.get(scope.group_id, id) do
      case view do
        %{"trigger" => %{}, "status" => "pending"} ->
          :ok

        %{"trigger" => %{}, "status" => "ended", "ended_at" => ended_at}
        when human_at > ended_at ->
          with {:ok, _view} <-
                 SalixIM.TaskLoop.request_loop(
                   scope,
                   conversation["task_worker_agent_id"],
                   id,
                   request
                 ),
               do: :ok

        %{"trigger" => %{}, "status" => "ended"} ->
          {:error, {:forbidden, "A later user message must request the new Loop"}}

        %{"trigger" => %{}} ->
          {:error, {:conflict, "End the current Loop before setting a new Loop"}}

        _none ->
          {:error, {:bad_request, "This Task has no Loop to restart"}}
      end
    end
  end

  # A Loop runs only inside Salix (`SalixIM.TaskPlacement`). A Loop Task made
  # on a station before that has a station Worker, which cannot create a new
  # Loop, so it gets none.
  defp restart_inside_salix(scope, id, conversation) do
    case SalixIM.ConversationServer.group_conversation_station_worker?(
           scope.group_id,
           id,
           conversation["task_worker_agent_id"]
         ) do
      {:ok, true} ->
        {:error, {:bad_request, TaskPlacement.message({:runs_on, :station_for_loop, :task})}}

      {:ok, false} ->
        :ok

      # No Worker: the restart refuses that itself.
      {:error, :not_found} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  # A Loop Task (`SalixIM.TaskLoop`): work that repeats or keeps watching
  # something, run by one Background Loop in the Task. A cron cadence without
  # a timezone takes the requester's device or source timezone.
  defp task_create_loop(params, schedule, tool_context, origin_metadata) do
    cond do
      is_nil(params["loop"]) ->
        {:ok, nil}

      not is_nil(schedule) ->
        {:error, "give either loop or schedule, not both; a Loop Task runs on its Loop"}

      true ->
        SalixIM.TaskLoop.request(params["loop"],
          now: SystemsClock.system_time(:millisecond),
          timezone: task_create_timezone(tool_context, origin_metadata)
        )
    end
  end

  defp task_create_timezone(tool_context, origin_metadata) do
    case get_in(origin_metadata, ["origin", "client_timezone"]) do
      zone when is_binary(zone) and zone != "" ->
        zone

      _none ->
        case context_value(tool_context, "trusted_origin") do
          origin when is_map(origin) -> str(stringify_value(origin)["source_timezone"])
          _other -> ""
        end
    end
  end

  defp task_create_provenance(scope, tool_context, schedule) do
    case MeetingActivationAuthorization.provenance_for_tool_context(
           scope.group_id,
           tool_context
         ) do
      {:ok, refs} when is_map(refs) and is_map(schedule) and map_size(refs) > 0 ->
        {:error,
         "im_api.internal.task.create schedule provenance rejected: :meeting_activation_schedule_not_authorized"}

      {:ok, refs} when is_map(refs) ->
        {:ok, refs}

      {:error, reason} ->
        {:error, "im_api.internal.task.create source provenance rejected: #{inspect(reason)}"}

      other ->
        {:error, "im_api.internal.task.create source provenance invalid: #{inspect(other)}"}
    end
  end

  # A Task's audience is decided when it is created and stored with it, as
  # server-owned `source_refs` keys the model can neither read nor set
  # (docs/verification.md):
  #
  #   * `ifc_provenance` — the join of the sources the Router declared, so a
  #     Worker's report inherits what the Task was made from;
  #   * `ifc_members` — the people it is shared with, which starts as the
  #     person who asked for it;
  #   * `ifc_requester` — the person whose Task it is, whom its sandbox's
  #     station acts for (`SalixWeb.StationTasks`). A Task a Worker or a
  #     station creates belongs to the person its parent Task belongs to.
  #
  # With the Group's check off the Task carries no audience, but still its
  # person: its sandbox's credentials are theirs, whatever the check's mode.
  defp task_ifc_refs(scope, tool_context) do
    case context_value(tool_context, "ifc_evidence") do
      %{} = evidence ->
        members =
          if evidence["requester"] == "system",
            do: [],
            else: list_of_strings(List.wrap(evidence["requester"]))

        %{}
        |> put_present("ifc_provenance", list_of_strings(evidence["sources_label"]))
        |> put_present("ifc_members", members)
        |> put_present("ifc_requester", task_requester(scope, tool_context, evidence))

      _absent ->
        requester = SalixAgent.IFC.unchecked_creator(tool_context)

        put_present(
          %{},
          "ifc_requester",
          task_requester(scope, tool_context, %{"requester" => requester})
        )
    end
  end

  # The chat a Task was asked for in, sealed from the runtime's trusted origin
  # (never from model arguments) as the protected `origin_chat` key
  # (`SalixIM.IFCSourceRefs`). Cross-Group search reads it to keep Tasks asked
  # for in a private chat out of other Groups' reach.
  defp task_origin_chat_refs(tool_context) do
    case context_value(tool_context, "trusted_origin") do
      origin when is_map(origin) ->
        case origin_chat(stringify_value(origin)) do
          chat when map_size(chat) > 0 -> %{"origin_chat" => chat}
          _none -> %{}
        end

      _absent ->
        %{}
    end
  end

  defp origin_chat(%{"provider" => "internal"} = origin) do
    %{"provider" => "internal"}
    |> put_present("conversation_kind", str(origin["conversation_kind"]))
    |> put_present("conversation_id", str(origin["conversation_id"]))
  end

  defp origin_chat(%{"provider" => provider} = origin) when is_binary(provider) do
    case str(provider) do
      "" ->
        %{}

      provider ->
        context =
          case origin["provider_context"] do
            %{} = context -> context
            _none -> %{}
          end

        %{"provider" => provider}
        |> put_present("connect_id", str(context["connect_id"]))
        |> put_present(
          "scope_id",
          first_present([context["channel_id"], context["chat_id"], context["wechat_id"]])
        )
        |> put_present(
          "chat_type",
          first_present([context["channel_type"], context["chat_type"]])
        )
    end
  end

  defp origin_chat(_origin), do: %{}

  defp first_present(values) do
    Enum.find_value(values, "", fn value ->
      case str(value) do
        "" -> nil
        text -> text
      end
    end)
  end

  defp task_requester(scope, tool_context, evidence) do
    with requester when is_binary(requester) <- evidence["requester"],
         {:ok, principal} <- SalixIFC.Codec.decode_principal(requester) do
      case person(principal) do
        nil -> parent_task_requester(scope, tool_context)
        person -> SalixIFC.Codec.encode_principal!(person)
      end
    else
      _ -> nil
    end
  end

  # A station acts for a person through the delegated-principal wrapper.
  defp person({:comma_user, _user} = person), do: person
  defp person({:provider_user, _connect, _user} = person), do: person
  defp person({:schedule, _id, inner}), do: person(inner)
  defp person(_principal), do: nil

  defp parent_task_requester(scope, tool_context) do
    with origin when is_map(origin) <- context_value(tool_context, "trusted_origin"),
         origin = stringify_value(origin),
         "agent_task" <- origin["conversation_kind"],
         {:ok, parent} <-
           Conversations.get_group_conversation_record(
             scope.group_id,
             origin["conversation_id"]
           ),
         requester when is_binary(requester) <- get_in(parent, ["source_refs", "ifc_requester"]) do
      requester
    else
      _ -> nil
    end
  end

  defp list_of_strings(values) when is_list(values) do
    case Enum.filter(values, &(is_binary(&1) and &1 != "")) do
      [] -> nil
      strings -> strings
    end
  end

  defp list_of_strings(_values), do: nil

  # When the human Message that started the current turn was sent, or nil when
  # no human Message started it. Only the runtime seals the trusted origin; a
  # model argument cannot claim one.
  defp human_turn_at(tool_context) do
    with origin when is_map(origin) <- context_value(tool_context, "trusted_origin"),
         origin = stringify_value(origin),
         source when is_binary(source) and source != "" <-
           context_value(tool_context, "source_message_id"),
         true <- origin["source_actor_type"] in ["user", "provider_user"],
         ^source <- origin["source_message_id"],
         sent_at when is_integer(sent_at) <- origin["source_sent_at_ms"] do
      sent_at
    else
      _other -> nil
    end
  end

  defp task_create_trusted_origin(scope, tool_context) do
    case context_value(tool_context, "trusted_origin") do
      nil ->
        {:ok, nil}

      origin when is_map(origin) ->
        origin = stringify_value(origin)

        if origin["provider"] == "internal" and
             origin["conversation_kind"] in ["user_chat", "agent_task"] do
          validate_task_create_origin(scope, tool_context, origin)
        else
          {:ok, nil}
        end

      _invalid ->
        {:error, "im_api.internal.task.create trusted origin rejected: expected an object"}
    end
  end

  # Where the Task was asked for. Provider inbound (Slack, Telegram, …) carries
  # its provider on the trusted origin; a Comma client request arrives as an
  # `internal` origin whose parent user Message carries the client metadata
  # the product stamped on it. Both are display facts, never authorization.
  # The requester's `client_timezone` lets Agent messages in the Task carry a
  # local timezone (see `ConversationDelivery`).
  defp task_origin_metadata(scope, tool_context) do
    origin =
      case context_value(tool_context, "trusted_origin") do
        origin when is_map(origin) -> stringify_value(origin)
        _other -> %{}
      end

    provider = str(origin["provider"])

    base =
      cond do
        provider == "" -> %{}
        provider == "internal" -> internal_origin_metadata(scope, origin)
        true -> %{"provider" => provider}
      end

    if map_size(base) == 0, do: %{}, else: %{"origin" => base}
  end

  defp internal_origin_metadata(scope, origin) do
    with conversation_id when is_binary(conversation_id) <- origin["conversation_id"],
         message_id when is_binary(message_id) <- origin["message_id"],
         {:ok, message} <-
           SalixIM.Conversations.get_group_conversation_message(
             scope.group_id,
             conversation_id,
             message_id
           ) do
      metadata = stringify_value(message["metadata"] || %{})

      %{"provider" => internal_origin_provider(origin, metadata)}
      |> put_present("client_kind", str(metadata["client_kind"]))
      |> put_present("client_platform", str(metadata["client_platform"]))
      |> put_present(
        "client_timezone",
        Enum.find([str(metadata["client_timezone"]), str(origin["source_timezone"])], &(&1 != ""))
      )
    else
      _other -> %{"provider" => "comma"}
    end
  end

  # A provider bridge that hands a person's request to the Router through a
  # user chat (Linear) appends it as that provider's user, and the Message
  # names the provider. Provider replies inside a Task (Telegram topics, Slack
  # and Linear threads) arrive in an `agent_task` and keep the Comma origin.
  defp internal_origin_provider(
         %{"conversation_kind" => "user_chat", "source_actor_type" => "provider_user"},
         metadata
       ) do
    case str(metadata["provider"]) do
      "" -> "comma"
      provider -> provider
    end
  end

  defp internal_origin_provider(_origin, _metadata), do: "comma"

  defp validate_task_create_origin(scope, tool_context, origin) do
    conversation_id = origin["conversation_id"]
    message_id = origin["message_id"]
    participant_id = origin["participant_id"]
    source_message_id = context_value(tool_context, "source_message_id")

    valid? =
      origin["agent_group_id"] == scope.group_id and
        Ids.valid_conversation_id?(conversation_id) and Ids.valid_message_id?(message_id) and
        Ids.valid_participant_id?(participant_id) and
        group_conversation_source_identity(source_message_id, conversation_id) ==
          {message_id, participant_id}

    if valid?,
      do: {:ok, origin},
      else: {:error, "im_api.internal.task.create trusted internal Conversation origin rejected"}
  end

  defp task_create_target(scope, target_agent_id) do
    case task_create_group_agent(scope, target_agent_id) do
      {:ok, target_agent_id} ->
        {:ok, target_agent_id, %{"agent_id" => target_agent_id}}

      {:error, reason} ->
        {:error, "Task requires a valid group-local agent_id: #{inspect(reason)}"}
    end
  end

  defp put_source_refs(command, nil, _origin), do: command

  defp put_source_refs(command, parent, origin) do
    update_in(command, [:attrs, "source_refs"], fn refs ->
      (refs || %{})
      |> Map.put_new("parent_conversation_id", parent)
      |> Map.put_new("origin_task_conversation_id", origin)
    end)
  end

  # The new Task's parent is the conversation the Worker's Task was made from
  # (a user's conversation, for a Router's Task); a Task with no parent of its
  # own is the parent.
  defp worker_task_parent(task_id, task) do
    case get_in(task, ["source_refs", "parent_conversation_id"]) do
      parent when is_binary(parent) and parent != "" -> parent
      _none -> task_id
    end
  end

  @worker_task_params ~w(content title runs_on repo model files)
  @collaboration_task_params ~w(content title runs_on repo mini_app model files)
  @max_task_create_files 20
  @collaboration_task_root "/task/"
  @collaboration_attachments_root "/.conversation-attachments/"

  defp require_collaboration_task_authority(scope, params) do
    cond do
      not is_nil(params["repo"]) ->
        require_collaboration_host_command(
          scope,
          "run coding tasks against a GitHub repository or open pull requests"
        )

      not is_nil(params["mini_app"]) ->
        require_collaboration_host_command(scope, "build or deploy Mini Apps")

      true ->
        :ok
    end
  end

  defp require_collaboration_host_command(scope, action) do
    ctx =
      SalixIM.Provider.current_tool_context()
      |> Map.put(:group_id, scope.group_id)

    if SalixIM.CollaborationCommand.host_command?(ctx) do
      :ok
    else
      {:error,
       "Only the host of this Collaborative Task can #{action}. " <>
         "Members may discuss and review results; ask the host to confirm in the Task."}
    end
  end

  defp collaboration_task_create_params(params) do
    case Map.keys(params) -- @collaboration_task_params do
      [] ->
        with :ok <- validate_collaboration_runs_on(params["runs_on"]),
             :ok <- validate_collaboration_task_files(params["files"]) do
          :ok
        end

      extra ->
        {:error,
         "a Collaborative Task's sub-task takes #{Enum.join(@collaboration_task_params, ", ")} only, not " <>
           Enum.join(Enum.sort(extra), ", ")}
    end
  end

  defp validate_collaboration_runs_on(%{"kind" => "sandbox"}), do: :ok

  defp validate_collaboration_runs_on(_other),
    do:
      {:error,
       ~s(a Collaborative Task's sub-task must run in a sandbox: give runs_on {"kind":"sandbox"})}

  defp validate_collaboration_task_files(nil), do: :ok

  defp validate_collaboration_task_files(files)
       when is_list(files) and length(files) <= @max_task_create_files do
    if Enum.all?(files, &safe_prefixed_path?(&1, @collaboration_task_root)) do
      :ok
    else
      {:error, "files for a Collaborative Task's sub-task must be paths under /task/"}
    end
  end

  defp validate_collaboration_task_files(_other),
    do: {:error, "files must be a list of at most #{@max_task_create_files} /task/ file paths"}

  defp task_create_initial_attachments(_scope, nil), do: {:ok, []}
  defp task_create_initial_attachments(_scope, []), do: {:ok, []}

  defp task_create_initial_attachments(scope, files)
       when is_list(files) and length(files) <= @max_task_create_files do
    if Enum.all?(files, &(is_binary(&1) and String.trim(&1) != "")) do
      blocks =
        Enum.map(files, fn path ->
          trimmed = String.trim(path)

          %{
            "type" => "file",
            "path" => trimmed,
            "file_name" => Path.basename(trimmed)
          }
        end)

      ConversationAttachments.bind_sender_files(scope.agent_id, blocks)
    else
      {:error, "files must be non-empty VFS file paths"}
    end
  end

  defp task_create_initial_attachments(_scope, _files),
    do: {:error, "files must be a list of at most #{@max_task_create_files} VFS file paths"}

  defp task_files_identity(identity, files) when is_list(files) and files != [],
    do: {identity, :files, files}

  defp task_files_identity(identity, _files), do: identity

  defp safe_prefixed_path?(path, prefix) when is_binary(path) do
    String.starts_with?(path, prefix) and not String.contains?(path, ["\\", <<0>>]) and
      not Enum.member?(String.split(path, "/"), "..")
  end

  defp safe_prefixed_path?(_path, _prefix), do: false

  defp prepare_collaboration_send_files(
         %{agent: %{"purpose" => "collaboration_worker"}} = scope,
         conversation,
         content
       )
       when is_list(content) do
    promote? = Conversations.collaboration_task?(conversation)

    with {:ok, existing_paths} <-
           load_collaboration_task_folder(scope.agent_id, promote?, content) do
      promote_collaboration_blocks(scope.agent_id, promote?, content, existing_paths)
    end
  end

  defp prepare_collaboration_send_files(_scope, _conversation, content), do: {:ok, content}

  defp load_collaboration_task_folder(agent_id, true, content) do
    if Enum.any?(content, &attachment_block?/1) do
      case AgentWorkspace.entries(agent_id, @collaboration_task_root) do
        {:ok, entries} ->
          {:ok, Map.new(entries)}

        {:error, :unsupported} ->
          {:ok, %{}}

        {:error, reason} ->
          {:error, control_error(reason)}
      end
    else
      {:ok, %{}}
    end
  end

  defp load_collaboration_task_folder(_agent_id, _promote?, _content), do: {:ok, %{}}

  defp promote_collaboration_blocks(agent_id, promote?, blocks, existing_paths) do
    Enum.reduce_while(blocks, {:ok, [], existing_paths}, fn block, {:ok, acc, paths} ->
      case prepare_collaboration_block(agent_id, promote?, block, paths) do
        {:ok, updated_block, next_paths} ->
          {:cont, {:ok, [updated_block | acc], next_paths}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc, _paths} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_collaboration_block(agent_id, promote?, block, existing_paths)
       when is_map(block) do
    case block_vfs_path(block) do
      nil ->
        {:ok, block, existing_paths}

      {kind, path} ->
        cond do
          safe_prefixed_path?(path, @collaboration_task_root) ->
            {:ok, block, existing_paths}

          safe_prefixed_path?(path, @collaboration_attachments_root) and promote? ->
            promote_attachment_to_task_folder(
              agent_id,
              block,
              kind,
              path,
              existing_paths
            )

          safe_prefixed_path?(path, @collaboration_attachments_root) ->
            {:ok, block, existing_paths}

          true ->
            {:error,
             "Collaborative Task attachments must come from /task/ or /.conversation-attachments/"}
        end
    end
  end

  defp prepare_collaboration_block(_agent_id, _promote?, block, existing_paths),
    do: {:ok, block, existing_paths}

  defp attachment_block?(block) when is_map(block) do
    case block_vfs_path(block) do
      {_kind, path} -> safe_prefixed_path?(path, @collaboration_attachments_root)
      nil -> false
    end
  end

  defp attachment_block?(_block), do: false

  defp block_vfs_path(%{"type" => type, "path" => path})
       when type in ["file", "dynamic_ui", "image"] and is_binary(path) do
    trimmed = String.trim(path)
    if trimmed == "", do: nil, else: {:path, trimmed}
  end

  defp block_vfs_path(%{
         "type" => "image",
         "file_ref" => %{"environment_id" => "vfs", "path" => path}
       })
       when is_binary(path) do
    trimmed = String.trim(path)
    if trimmed == "", do: nil, else: {:file_ref, trimmed}
  end

  defp block_vfs_path(_block), do: nil

  defp promote_attachment_to_task_folder(
         agent_id,
         block,
         kind,
         source_path,
         existing_paths
       ) do
    with {:ok, ref} <- AgentWorkspace.file_ref(agent_id, source_path),
         size = ref["size"] || ref[:size] || 0,
         {:ok, target_path, write?} <-
           resolve_task_target_path(agent_id, block, source_path, ref, existing_paths),
         :ok <- put_promoted_ref(agent_id, target_path, ref, write?) do
      updated_block = rewrite_block_vfs_path(block, kind, target_path)
      next_paths = Map.put(existing_paths, target_path, size)
      {:ok, updated_block, next_paths}
    end
  end

  defp resolve_task_target_path(agent_id, block, source_path, ref, existing_paths) do
    filename = promoted_filename(block, source_path)
    candidate = @collaboration_task_root <> filename

    case Map.has_key?(existing_paths, candidate) do
      false ->
        {:ok, candidate, true}

      true ->
        incoming_hash = ref["hash"] || ref[:hash]

        case AgentWorkspace.file_ref(agent_id, candidate) do
          {:ok, %{"hash" => ^incoming_hash}} when is_binary(incoming_hash) ->
            {:ok, candidate, false}

          {:ok, %{hash: ^incoming_hash}} when is_binary(incoming_hash) ->
            {:ok, candidate, false}

          _other ->
            suffix =
              case incoming_hash do
                hash when is_binary(hash) and byte_size(hash) >= 6 ->
                  String.slice(hash, 0, 6)

                _ ->
                  :crypto.hash(:sha256, source_path)
                  |> Base.encode16(case: :lower)
                  |> binary_part(0, 6)
              end

            ext = Path.extname(filename)
            stem = Path.basename(filename, ext)
            disambiguated = @collaboration_task_root <> "#{stem}-#{suffix}#{ext}"
            {:ok, disambiguated, true}
        end
    end
  end

  defp promoted_filename(block, source_path) do
    raw =
      case block["file_name"] do
        name when is_binary(name) and name != "" ->
          name

        _ ->
          source_path
          |> Path.basename()
          |> String.replace(~r/^\d+-/, "")
      end

    cleaned =
      raw
      |> Path.basename()
      |> String.replace(~r/[\x00-\x1f\\\/]/, "_")
      |> String.trim()

    if cleaned in ["", ".", ".."], do: "attachment", else: String.slice(cleaned, 0, 180)
  end

  defp put_promoted_ref(_agent_id, _target_path, _ref, false), do: :ok

  defp put_promoted_ref(agent_id, target_path, ref, true) do
    case AgentWorkspace.put_ref(agent_id, target_path, ref) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp rewrite_block_vfs_path(block, :path, target_path) do
    block
    |> Map.put("path", target_path)
    |> Map.put_new("file_name", Path.basename(target_path))
  end

  defp rewrite_block_vfs_path(block, :file_ref, target_path) do
    put_in(block, ["file_ref", "path"], target_path)
  end

  defp worker_task_create_enabled(group_id) do
    if SalixIM.Sandboxes.cloud_vm_retired?(group_id),
      do: :ok,
      else:
        {:error,
         "a Worker creates no Task here: the Group's Cloud VM is not retired; run machine " <>
           "work there with env.exec, or report what the work needs to the Router"}
  end

  # A Worker's Task is a sandbox Task of the plainest kind: no Loop, Schedule,
  # labels, Triage handoff, execution grant, app or Worker choice.
  defp worker_task_create_params(params) do
    case Map.keys(params) -- @worker_task_params do
      [] ->
        case params["runs_on"] do
          %{"kind" => "sandbox"} ->
            :ok

          _other ->
            {:error,
             ~s(a Worker's Task runs in a sandbox: give runs_on {"kind":"sandbox"}, with repo {owner, name} for a repository)}
        end

      extra ->
        {:error,
         "a Worker's Task takes #{Enum.join(@worker_task_params, ", ")} only, not " <>
           Enum.join(Enum.sort(extra), ", ")}
    end
  end

  # The Task the Worker is in: named by the station or Loop that calls for it
  # (`task_conversation_id`), or the Task conversation its round serves
  # (`trusted_origin`). The Worker must take part in it as its Worker.
  defp worker_task(scope) do
    tool_context = SalixIM.Provider.current_tool_context()

    id =
      case context_value(tool_context, "task_conversation_id") do
        id when is_binary(id) and id != "" ->
          id

        _none ->
          case context_value(tool_context, "trusted_origin") do
            origin when is_map(origin) ->
              origin = stringify_value(origin)

              if origin["provider"] == "internal" and
                   origin["conversation_kind"] == "agent_task",
                 do: origin["conversation_id"]

            _none ->
              nil
          end
      end

    with true <- Ids.valid_conversation_id?(id),
         {:ok, %{"kind" => "agent_task"} = task} <- get_conversation(scope.group_id, id),
         true <- worker_of?(scope, id) do
      {:ok, id, task}
    else
      _ -> {:error, "a Worker creates a Task only from within its own Task"}
    end
  end

  defp worker_of?(scope, conversation_id) do
    case Conversations.list_group_conversation_participants(scope.group_id, conversation_id) do
      {:ok, %{"participants" => participants}} ->
        Enum.any?(participants, fn participant ->
          participant["actor_type"] == "agent" and
            participant["agent_id"] == scope.agent_id and
            participant["role_label"] == "worker"
        end)

      _ ->
        false
    end
  end

  # A Task made by a Worker creates no Task: the chain is one level deep.
  defp worker_task_depth(task) do
    case get_in(task, ["source_refs", "origin_agent_id"]) do
      origin when is_binary(origin) and origin != "" ->
        case GroupDirectory.get_agent(origin) do
          {:ok, %{"role" => "worker"}} ->
            {:error,
             "task_depth: a Worker created this Task, so it creates no Task; report what the work needs to the Router instead"}

          _router_or_gone ->
            :ok
        end

      _none ->
        :ok
    end
  end

  defp group_router(scope) do
    case GroupDirectory.get_group(scope.group_id) do
      {:ok, %{"router_agent_id" => router}} when is_binary(router) and router != "" ->
        {:ok, router}

      _ ->
        {:error, "the Group has no Router to take the Task's result"}
    end
  end

  # A Router may leave the Worker out: the Group's Task agent takes the Task.
  defp task_create_worker(scope, params) do
    case params["agent_id"] do
      nil ->
        case TaskCreate.task_worker(%{tenant_id: scope.tenant_id, group_id: scope.group_id}) do
          {:ok, agent_id} when is_binary(agent_id) -> {:ok, agent_id}
          {:error, :task_worker_required} -> {:error, "agent_id is required"}
          {:error, reason} -> {:error, "no Worker can take this Task: #{inspect(reason)}"}
        end

      _given ->
        required_string(params, "agent_id")
    end
  end

  defp task_create_target_identity(target_agent_id, nil, nil), do: target_agent_id

  defp task_create_target_identity(target_agent_id, session_model, nil),
    do: {target_agent_id, session_model}

  defp task_create_target_identity(target_agent_id, session_model, runs_on),
    do: {target_agent_id, session_model, runs_on}

  # The request a Task is made for is part of the command: one Message can ask
  # for the same Task for two requests. A Task for none keeps its earlier identity.
  defp task_request_identity(identity, %{"task_request_id" => id}) when is_binary(id),
    do: {identity, :task_request, id}

  defp task_request_identity(identity, _params), do: identity

  # A coding Task's repository, and the app a build Task makes, are part of
  # where it runs; a Task without them keeps its earlier identity.
  defp place_identity(runs_on, repo, mini_app) do
    runs_on
    |> then(&if(is_nil(repo), do: &1, else: Map.put(&1, "repo", repo)))
    |> then(&if(is_nil(mini_app), do: &1, else: Map.put(&1, "mini_app", mini_app)))
  end

  # A Router names where every Task runs, so a code change is never placed by
  # omission. `{"kind": "default"}` leaves the place to the configured
  # defaults (`SalixIM.TaskPlacement`), as an omitted place did before.
  defp task_create_place(%{"runs_on" => %{"kind" => "default"} = place} = params)
       when map_size(place) == 1,
       do: {:ok, Map.delete(params, "runs_on")}

  defp task_create_place(%{"runs_on" => %{"kind" => "default"}}),
    do: {:error, ~s(runs_on {"kind":"default"} takes no other fields)}

  defp task_create_place(%{"runs_on" => %{"kind" => kind}} = params)
       when is_binary(kind),
       do: {:ok, params}

  defp task_create_place(_params),
    do:
      {:error,
       ~s(runs_on.kind is required: {"kind":"sandbox"} with repo for code changes to a GitHub repository, {"kind":"default"} for the configured defaults, or salix, cloud_vm or station)}

  # Where the Task runs and its Session's model (`SalixIM.TaskPlacement`).
  # The sources the creator declared (`ifc_sources`) decide whether the Task
  # may go to a station or the Cloud VM in a Group that enforces IFC.
  defp task_create_placement(scope, target_agent_id, params, loop?) do
    tool_context = SalixIM.Provider.current_tool_context()

    scope =
      scope
      |> Map.put(:trusted_origin, context_value(tool_context, "trusted_origin"))
      |> Map.put(
        :ifc_sources,
        (context_value(tool_context, "ifc_evidence") || %{})["sources_label"]
      )
      |> put_computer_choice(tool_context)

    case TaskPlacement.resolve(scope, target_agent_id, params, loop?) do
      {:ok, placement} -> {:ok, placement}
      {:error, {:agent, reason}} -> {:error, reason}
      {:error, refusal} -> {:error, TaskPlacement.message(refusal)}
    end
  end

  # A Router's Task from a person's Message (Comma or an external IM): the
  # person says which of their computers it runs on (`SalixIM.ComputerChoice`).
  defp put_computer_choice(%{agent: %{"role" => "router"}} = scope, tool_context) do
    case context_value(tool_context, "trusted_origin") do
      origin when is_map(origin) ->
        origin = stringify_value(origin)

        if human_choice_origin?(origin) do
          origins =
            tool_context
            |> context_value("trusted_origins")
            |> List.wrap()
            |> Enum.filter(&is_map/1)
            |> Enum.map(&stringify_value/1)

          scope
          |> Map.put(:computer_choice, origin)
          |> Map.put(:computer_choice_origins, origins)
          |> put_optional_key(
            :computer_choice_session_id,
            context_value(tool_context, "session_id")
          )
        else
          scope
        end

      _none ->
        scope
    end
  end

  defp put_computer_choice(scope, _tool_context), do: scope

  defp human_choice_origin?(%{"provider" => "internal"}), do: true

  defp human_choice_origin?(%{"provider" => provider, "source_actor_type" => "provider_user"})
       when is_binary(provider) and provider != "",
       do: true

  defp human_choice_origin?(_origin), do: false

  defp put_optional_key(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_optional_key(map, _key, _value), do: map

  defp task_create_group_agent(scope, agent_id) do
    case GroupDirectory.get_agent(agent_id) do
      {:ok, %{"group_id" => group_id, "agent_id" => ^agent_id} = agent}
      when group_id == scope.group_id ->
        if agent["status"] in ["cancelled", "failed"],
          do: {:error, :not_found},
          else: {:ok, agent_id}

      {:ok, _other_group} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp task_create_request_id(
         scope,
         _tool_context,
         %{"conversation_id" => conversation_id, "message_id" => message_id},
         target_agent_id,
         content,
         title,
         schedule
       ) do
    command_digest =
      {target_agent_id, content, title, schedule}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    Enum.join(
      ["comma-user-chat-task", scope.agent_id, conversation_id, message_id, command_digest],
      ":"
    )
  end

  defp task_create_request_id(
         scope,
         tool_context,
         nil,
         _target_agent_id,
         _content,
         _title,
         _schedule
       ) do
    case Map.get(scope, :tool_call_id) do
      id when is_binary(id) and id != "" ->
        Enum.join([scope.agent_id, context_value(tool_context, "session_id"), id], ":")

      _missing ->
        nil
    end
  end

  defp task_create_response(result, command) when is_map(result) do
    conversation_id = str(result["conversation_id"])

    if Ids.valid_conversation_id?(conversation_id) do
      response =
        %{
          "created" => true,
          "conversation_id" => conversation_id,
          "conversation_ref" => %{
            "type" => "conversation_ref",
            "conversation_id" => conversation_id,
            "kind" => "agent_task",
            "presentation" => "inline"
          },
          "conversation_kind" => "agent_task",
          "inserted" => result["inserted"] != false,
          "response_delivery" => "ordinary_conversation_message",
          "response_conversation_id" => conversation_id,
          "next_action" => task_create_next_action()
        }
        |> Map.merge(command.public_target)
        |> put_task_create_delivery(result)
        |> put_present("status", get_in(result, ["conversation", "status"]))
        |> put_present("title", command.title)

      response =
        if is_map(result["schedule"]),
          do: Map.put(response, "schedule", result["schedule"]),
          else: response

      loop =
        if is_map(command.attrs["loop"]),
          do: SalixIM.TaskLoop.request_summary(command.attrs["loop"])

      {:ok, put_present(response, "loop", loop)}
    else
      {:error, "Task projection returned an invalid conversation_id"}
    end
  end

  defp task_create_response(_result, _command),
    do: {:error, "Task projection returned an invalid result"}

  defp put_task_create_delivery(response, result) do
    response
    |> Map.put("sent", true)
    |> Map.put("delivery_status", result["delivery_status"] || "queued")
    |> put_present("message_id", result["message_id"])
  end

  defp task_create_next_action() do
    "Continue any independent work now. Work that needs the participant response resumes when a later ordinary message arrives in this Task. Use raw IDs only in structured tool parameters and content blocks, never in visible text."
  end

  defp context_value(context, key) when is_map(context),
    do: Map.get(context, key) || Map.get(context, String.to_atom(key))

  defp stringify_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)

  defp stringify_value(list) when is_list(list), do: Enum.map(list, &stringify_value/1)
  defp stringify_value(value), do: value

  defp task_schedule_update(params) do
    command? = Map.has_key?(params, "command")
    schedule? = Map.has_key?(params, "schedule")
    command = params["command"]
    schedule = params["schedule"]

    cond do
      not command? and not schedule? ->
        {:error, "provide command and/or schedule"}

      command? and (not is_binary(command) or String.trim(command) == "") ->
        {:error, "command must be complete command text"}

      schedule? and not (is_map(schedule) or is_nil(schedule)) ->
        {:error, "schedule must be an object or null"}

      schedule? and is_nil(schedule) and command? ->
        {:error, "command cannot be changed while removing schedule"}

      true ->
        schedule =
          cond do
            is_map(schedule) -> schedule
            schedule? -> nil
            true -> %{}
          end

        schedule =
          if is_map(schedule) and command?,
            do: Map.put(schedule, "command", command),
            else: schedule

        validate_task_schedule_update(schedule)
    end
  end

  defp validate_task_schedule_update(nil), do: {:ok, nil}

  defp validate_task_schedule_update(schedule) do
    cron? = str(schedule["cron"]) != ""
    interval? = is_integer(schedule["interval_minutes"]) and schedule["interval_minutes"] > 0

    cond do
      cron? and str(schedule["timezone"]) == "" ->
        {:error,
         "schedule.timezone is required with schedule.cron; ask the user if it is unclear"}

      cron? and interval? ->
        {:error, "provide exactly one of schedule.interval_minutes or schedule.cron"}

      true ->
        {:ok, schedule}
    end
  end

  defp authorize_task_update(scope) do
    case MeetingActivationAuthorization.provenance_for_tool_context(
           scope.group_id,
           SalixIM.Provider.current_tool_context()
         ) do
      {:ok, refs} when map_size(refs) == 0 -> :ok
      {:ok, _refs} -> {:error, :meeting_activation_task_update_not_authorized}
      {:error, _reason} = error -> error
    end
  end

  defp validate_param_keys(params, allowed, operation) do
    allowed_text =
      case allowed do
        [first, second] -> "#{first} and #{second}"
        _ -> Enum.join(allowed, ", ")
      end

    if Enum.all?(Map.keys(params), &(&1 in allowed)),
      do: :ok,
      else: {:error, "#{operation} accepts only #{allowed_text}"}
  end

  defp required_string(params, key) do
    case params[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, "#{key} is required"}, else: {:ok, value}

      _invalid ->
        {:error, "#{key} is required"}
    end
  end

  defp apps_create_params(params, name) do
    with {:ok, description} <- optional_text(params["description"], "description", 500),
         {:ok, repo} <- apps_create_repo(params["repo"]) do
      cond do
        String.length(name) > 60 ->
          {:error, "name is at most 60 characters"}

        true ->
          {:ok,
           %{"name" => name}
           |> put_present("description", description)
           |> put_present("repo", repo)}
      end
    end
  end

  defp optional_text(nil, _key, _max), do: {:ok, nil}

  defp optional_text(value, key, max) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) <= max,
      do: {:ok, if(value == "", do: nil, else: value)},
      else: {:error, "#{key} is at most #{max} characters"}
  end

  defp optional_text(_value, key, _max), do: {:error, "#{key} must be a string"}

  defp apps_create_repo(nil), do: {:ok, nil}

  defp apps_create_repo(%{"owner" => owner, "name" => name} = repo)
       when map_size(repo) == 2 and is_binary(owner) and is_binary(name) and owner != "" and
              name != "",
       do: {:ok, %{"owner" => String.trim(owner), "name" => String.trim(name)}}

  defp apps_create_repo(_repo), do: {:error, "repo must be {owner, name}"}

  # What a Router reads when the product did not make the app.
  defp apps_create_error(:github_not_connected),
    do:
      "the Workspace has no GitHub account connected, and an app keeps its source in GitHub. " <>
        github_request() <> " The app was not made."

  defp apps_create_error(:github_reauthorization_required),
    do:
      "the Workspace's GitHub connection needs the user to sign in again. " <>
        github_request() <> " The app was not made."

  defp apps_create_error({:repo_not_found, repo}),
    do:
      "the connected GitHub account cannot read #{repo}, or it has no comma-app.json; check " <>
        "the owner and name, or omit repo to start from the template. The app was not made."

  defp apps_create_error({:invalid, message}) when is_binary(message),
    do: "#{message}. The app was not made."

  defp apps_create_error(:mini_apps_unavailable),
    do: "apps are not set up here. The app was not made."

  defp apps_create_error(reason) when is_binary(reason), do: reason
  defp apps_create_error(reason), do: "the app was not made: #{inspect(reason)}"

  # The same binding Settings > Plugins makes (provider and alias github, its scopes), so either way connects it.
  defp github_request,
    do:
      ~s(Ask the user to connect it: call oauth.request_authorization with {"provider":"github","alias":"github",) <>
        ~s("scopes":["repo","read:org","read:user","user:email"],"reason":"..."}, the reason one sentence in the ) <>
        "user's language on why the app needs GitHub. The Comma app shows the user a card with an authorize " <>
        "button; the call returns when they connect or decline. Once it returns connected, call apps.create again."

  defp apps_read_error(:not_found),
    do: "no app of this Workspace has that app_id; read internal.apps.list"

  defp apps_read_error(:mini_apps_unavailable), do: "apps are not set up here"
  defp apps_read_error(reason) when is_binary(reason), do: reason
  defp apps_read_error(reason), do: "the apps could not be read: #{inspect(reason)}"

  defp add_agent_participant_attrs(params, agent_id) do
    role_label = params["role_label"]

    notification_filter =
      case params["notification_filter"] do
        nil -> %{"messages" => "all", "statuses" => "none"}
        filter -> filter
      end

    cond do
      not is_nil(role_label) and not is_binary(role_label) ->
        {:error, "role_label must be a string"}

      not is_map(notification_filter) ->
        {:error, "notification_filter must be an object"}

      notification_filter["statuses"] != "none" ->
        {:error, "notification_filter.statuses must be none for Agent participants"}

      true ->
        {:ok,
         %{"agent_id" => agent_id}
         |> maybe_put("role_label", role_label && String.trim(role_label))
         |> Map.put("notification_filter", notification_filter)}
    end
  end

  # The Group's station-hosted Tasks (`SalixStore.StationTaskIndex`), for
  # the first page of internal.task.list.
  defp station_task_entries(group_id) do
    group_id
    |> SalixStore.StationTaskIndex.list_group(100)
    |> Enum.map(fn row ->
      %{
        "task_id" => StationHostedTasks.ref(row.station_id, row.thread),
        "title" => row.title,
        "status" => row.status,
        "hosted_on" => row.device_id,
        "last_activity_at" => row.last_activity_at,
        "runtime" => row.runtime,
        "model" => row.model,
        "labels" => row.labels || []
      }
      |> maybe_put("card_kind", station_card_kind(row))
    end)
  end

  defp station_card_kind(row) do
    Enum.find_value(row.labels || [], fn
      "card:" <> kind when kind != "" -> kind
      _ -> nil
    end)
  end

  @station_task_page_limit 100
  @station_task_max_pages 8

  defp read_station_task(scope, station_id, thread, params) do
    tail = int_or(params["tail"], 0)
    after_seq = int_or(params["after_seq"], -1)
    limit = int_or(params["limit"], 0)

    if tail > 0 and after_seq < 0 do
      read_station_task_tail(scope, station_id, thread, tail, limit)
    else
      opts = %{
        "after" => max(after_seq, 0),
        "limit" => if(limit > 0, do: limit, else: 50)
      }

      case StationHostedTasks.read(scope, station_id, thread, opts) do
        {:ok, answer} ->
          {:ok,
           station_task_read_payload(
             station_id,
             thread,
             answer["title"],
             answer["through"],
             List.wrap(answer["messages"])
           )}

        {:error, reason} ->
          {:error, station_task_error(reason)}
      end
    end
  end

  defp read_station_task_tail(scope, station_id, thread, tail, limit) do
    effective_tail = min(tail, @station_task_page_limit)
    take_count = if limit > 0, do: min(effective_tail, limit), else: effective_tail

    with {:ok, answer} <-
           StationHostedTasks.read(scope, station_id, thread, %{
             "after" => 0,
             "limit" => @station_task_page_limit
           }),
         {:ok, messages, through} <-
           station_tail_messages(scope, station_id, thread, answer, effective_tail) do
      {:ok,
       station_task_read_payload(
         station_id,
         thread,
         answer["title"],
         through,
         Enum.take(messages, -take_count)
       )}
    else
      {:error, reason} ->
        {:error, station_task_error(reason)}
    end
  end

  defp station_tail_messages(scope, station_id, thread, answer, keep) do
    messages = List.wrap(answer["messages"])
    through = answer["through"]
    last = station_last_seq(messages)
    buffer = Enum.take(messages, -keep)

    cond do
      not is_integer(through) or messages == [] or last <= 0 or last >= through ->
        {:ok, buffer, through}

      through - last > @station_task_page_limit * 4 ->
        jump_cursor = max(through - @station_task_page_limit * 3, last)

        with {:ok, jumped, latest_through, used_pages} <-
               station_page_forward(
                 scope,
                 station_id,
                 thread,
                 jump_cursor,
                 through,
                 [],
                 keep,
                 @station_task_max_pages - 1
               ) do
          if length(jumped) >= keep do
            {:ok, jumped, latest_through}
          else
            remaining = max(@station_task_max_pages - 1 - used_pages, 1)
            back_cursor = max(jump_cursor - @station_task_page_limit * remaining, last)

            with {:ok, earlier, final_through, _} <-
                   station_page_forward(
                     scope,
                     station_id,
                     thread,
                     back_cursor,
                     jump_cursor,
                     buffer,
                     keep,
                     remaining
                   ) do
              merged =
                (earlier ++ jumped)
                |> Enum.uniq_by(&(&1["seq"] || &1))
                |> Enum.take(-keep)

              {:ok, merged, max(latest_through, final_through)}
            end
          end
        end

      true ->
        with {:ok, paged, latest_through, _used_pages} <-
               station_page_forward(
                 scope,
                 station_id,
                 thread,
                 last,
                 through,
                 buffer,
                 keep,
                 @station_task_max_pages - 1
               ) do
          {:ok, paged, latest_through}
        end
    end
  end

  defp station_page_forward(
         _scope,
         _station_id,
         _thread,
         cursor,
         through,
         buffer,
         _keep,
         remaining_pages
       )
       when remaining_pages <= 0 or cursor >= through do
    {:ok, buffer, through, 0}
  end

  defp station_page_forward(
         scope,
         station_id,
         thread,
         cursor,
         through,
         buffer,
         keep,
         remaining_pages
       ) do
    case StationHostedTasks.read(scope, station_id, thread, %{
           "after" => cursor,
           "limit" => @station_task_page_limit
         }) do
      {:ok, answer} ->
        page = List.wrap(answer["messages"])
        next_through = if is_integer(answer["through"]), do: answer["through"], else: through
        next_seq = station_last_seq(page)
        next_buffer = Enum.take(buffer ++ page, -keep)

        if page == [] or next_seq <= cursor or next_seq >= next_through do
          {:ok, next_buffer, next_through, 1}
        else
          with {:ok, final_buffer, final_through, more_pages} <-
                 station_page_forward(
                   scope,
                   station_id,
                   thread,
                   next_seq,
                   next_through,
                   next_buffer,
                   keep,
                   remaining_pages - 1
                 ) do
            {:ok, final_buffer, final_through, more_pages + 1}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp station_last_seq([]), do: 0

  defp station_last_seq(messages) do
    case List.last(messages) do
      %{"seq" => seq} when is_integer(seq) -> seq
      _ -> 0
    end
  end

  defp station_task_read_payload(station_id, thread, title, through, messages) do
    %{
      "conversation_id" => StationHostedTasks.ref(station_id, thread),
      "hosted_on_station" => true,
      "title" => title,
      "through_seq" => through,
      "messages" =>
        Enum.map(messages, fn m ->
          Map.take(m, ~w(seq author_kind author text at declared milestones card))
        end)
    }
  end

  defp say_station_task(scope, conversation_id, params) do
    content = station_task_say_text(params["content"])
    key = str(params["request_id"])

    opts =
      if(params["close_card"] == true, do: %{"close_card" => true}, else: %{})
      |> then(fn map ->
        # Never trust requester_email from LLM tool params; only forward server-trusted scope email if present.
        case scope[:requester_email] || scope["requester_email"] do
          email when is_binary(email) ->
            case String.trim(email) do
              "" -> map
              trimmed -> Map.put(map, "requester_email", trimmed)
            end

          _ ->
            map
        end
      end)

    with true <-
           scope.agent["role"] == "router" ||
             {:error, "only the Router writes in a Task a station hosts"},
         {station_id, thread} <- StationHostedTasks.parse(conversation_id),
         true <- content != "" || {:error, "content is required"},
         true <- key != "" || {:error, "request_id is required for a station-hosted Task"},
         requester = scope.agent["name"] || "Router",
         {:ok, %{"seq" => seq}} <-
           StationHostedTasks.say(scope, station_id, thread, content, key, requester, opts) do
      notify_station_task_observer(scope.group_id, conversation_id, seq)
      {:ok, %{"conversation_id" => conversation_id, "seq" => seq, "hosted_on_station" => true}}
    else
      :error -> {:error, "unknown station-hosted Task"}
      {:ok, _answer} -> {:error, "the station did not take the Message"}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, station_task_error(reason)}
    end
  end

  defp station_task_say_text(content) when is_binary(content), do: content

  defp station_task_say_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) and text != "" -> [text]
      %{type: "text", text: text} when is_binary(text) and text != "" -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp station_task_say_text(_content), do: ""

  defp notify_station_task_observer(group_id, conversation_id, seq) do
    if mod = SystemsRuntime.get_env(:salix_im, :station_task_observer) do
      _ = mod.router_replied(group_id, conversation_id, seq)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_refresh_task_conversation_for_worker_read(
         scope,
         %{"kind" => "agent_task", "task_worker_agent_id" => worker_agent_id} = conversation,
         conversation_id
       )
       when is_binary(worker_agent_id) and worker_agent_id == scope.agent_id do
    if conversation["multi_session"] == true do
      {:ok, conversation}
    else
      # Linearization with first secondary creation:
      # Writer persists multi_session=true -> secondary -> message.
      # Reader reads messages -> re-reads conversation so any message written
      # after first secondary creation (or any read by a secondary) MUST see
      # multi_session == true before auth and visibility filtering.
      get_conversation(scope.group_id, conversation_id)
    end
  end

  defp maybe_refresh_task_conversation_for_worker_read(_scope, conversation, _conversation_id),
    do: {:ok, conversation}

  defp maybe_mark_effective_multi_session(
         scope,
         %{"kind" => "agent_task", "task_worker_agent_id" => worker_agent_id} = conversation,
         participants,
         participants_has_more?
       )
       when is_binary(worker_agent_id) and worker_agent_id != "" do
    if conversation["multi_session"] == true do
      {:ok, conversation}
    else
      worker_participants =
        Enum.filter(participants, fn p ->
          p["actor_type"] == "agent" and
            p["role_label"] == "worker" and
            p["agent_id"] == worker_agent_id
        end)

      has_secondary? =
        length(worker_participants) > 1 or
          Enum.any?(worker_participants, fn p ->
            not is_nil(SalixIM.TaskSessionSlots.normalize_target_key(p["target_key"]))
          end)

      cond do
        has_secondary? ->
          {:ok, Map.put(conversation, "multi_session", true)}

        participants_has_more? and scope.agent_id == worker_agent_id ->
          case SalixIM.ConversationServer.get_group_conversation_task_worker_identities(
                 scope.group_id,
                 conversation["conversation_id"]
               ) do
            {:ok, %{"workers" => workers} = roster} when is_list(workers) ->
              owner_has_secondary? =
                roster["has_multi_session_history"] == true or
                  length(workers) > 1 or
                  Enum.any?(workers, fn w ->
                    not is_nil(SalixIM.TaskSessionSlots.normalize_target_key(w["target_key"]))
                  end)

              if owner_has_secondary?,
                do: {:ok, Map.put(conversation, "multi_session", true)},
                else: {:ok, conversation}

            {:ok, _} ->
              {:ok, conversation}

            {:error, reason} ->
              {:error, reason}
          end

        true ->
          {:ok, conversation}
      end
    end
  end

  defp maybe_mark_effective_multi_session(_scope, conversation, _participants, _has_more?),
    do: {:ok, conversation}

  defp resolve_read_conversation_participant(scope, conversation, participants) do
    multi_session_worker_caller? =
      conversation["kind"] == "agent_task" and
        conversation["multi_session"] == true and
        is_binary(conversation["task_worker_agent_id"]) and
        scope.agent_id == conversation["task_worker_agent_id"]

    if not multi_session_worker_caller? do
      {:ok,
       Enum.find(
         participants,
         &(&1["actor_type"] == "agent" and &1["agent_id"] == scope.agent_id)
       )}
    else
      conv_id = conversation["conversation_id"]
      session_id = context_value(SalixIM.Provider.current_tool_context(), "session_id")

      if is_binary(session_id) and session_id != "" do
        case SalixIM.ConversationServer.get_group_conversation_participant_by_session(
               scope.group_id,
               conv_id,
               session_id
             ) do
          {:ok,
           %{
             "actor_type" => "agent",
             "agent_id" => agent_id,
             "role_label" => "worker",
             "state" => state
           } = participant}
          when agent_id == scope.agent_id and state != "inactive" ->
            {:ok, participant}

          {:error, {:participant_state_unavailable, _reason}} = error ->
            error

          _ ->
            {:error, "session is not an active worker in this multi-session task"}
        end
      else
        {:error, "session is not an active worker in this multi-session task"}
      end
    end
  end

  defp filter_visible_messages(
         messages,
         %{"kind" => "agent_task", "multi_session" => true},
         %{"participant_id" => participant_id, "actor_type" => "agent", "role_label" => "worker"}
       )
       when is_binary(participant_id) and participant_id != "" do
    Enum.filter(messages, &SalixIM.ConversationMessage.visible_to?(participant_id, &1))
  end

  defp filter_visible_messages(messages, _conversation, _current), do: messages

  defp prevalidate_task_create_sessions(scope, params, loop, schedule, triage) do
    has_sessions? = Map.has_key?(params, "sessions") and not is_nil(params["sessions"])

    has_initial_wake? =
      Map.has_key?(params, "initial_wake") and not is_nil(params["initial_wake"])

    has_policy? =
      Map.has_key?(params, "human_wakeup_policy") and not is_nil(params["human_wakeup_policy"])

    with {:ok, initial_wake} <- validate_initial_wake(params["initial_wake"]),
         {:ok, human_wakeup_policy} <- validate_human_wakeup_policy(params["human_wakeup_policy"]) do
      if not has_sessions? do
        if (has_initial_wake? or has_policy?) and scope.agent["role"] != "router" do
          {:error,
           {:bad_request, "multi-session options are only allowed for Router task.create"}}
        else
          {:ok,
           %{
             sessions: nil,
             initial_wake: initial_wake,
             human_wakeup_policy: human_wakeup_policy
           }}
        end
      else
        with :ok <- require_router_for_multi_session(scope),
             {:ok, raw_sessions} <- validate_sessions_list(params["sessions"]),
             :ok <-
               reject_excluded_multi_session_task_pre(
                 raw_sessions,
                 loop,
                 schedule,
                 triage,
                 params
               ),
             {:ok, pre_normalized} <- prenormalize_sessions(raw_sessions) do
          {:ok,
           %{
             sessions: pre_normalized,
             initial_wake: initial_wake || "primary",
             human_wakeup_policy: human_wakeup_policy || "primary_only"
           }}
        end
      end
    end
  end

  defp maybe_lift_primary_session_model(params, %{sessions: sessions}) when is_list(sessions) do
    primary = Enum.find(sessions, &(&1["primary"] == true))
    top_model = params["model"]
    primary_model = is_map(primary) && primary["model"]

    cond do
      not is_nil(top_model) and not is_nil(primary_model) and top_model != primary_model ->
        {:error, {:bad_request, "top-level model conflicts with primary session model"}}

      is_nil(top_model) and not is_nil(primary_model) ->
        {:ok, Map.put(params, "model", primary_model)}

      true ->
        {:ok, params}
    end
  end

  defp maybe_lift_primary_session_model(params, _pre_sessions), do: {:ok, params}

  defp finalize_task_create_sessions(
         _scope,
         %{sessions: nil} = pre_sessions,
         _target,
         _runs_on,
         _primary_resolved_model
       ),
       do: {:ok, pre_sessions}

  defp finalize_task_create_sessions(
         scope,
         %{sessions: sessions} = pre_sessions,
         target_agent_id,
         runs_on,
         primary_resolved_model
       )
       when is_list(sessions) do
    with :ok <- check_multi_session_capability(scope, runs_on, length(sessions) > 1) do
      sessions
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        if entry["primary"] == true do
          # Primary model was already resolved by task_create_placement with the
          # raw placement inputs (avoiding re-resolving normalized Cloud VM runs_on).
          updated =
            entry
            |> Map.delete("model")
            |> put_present("model", primary_resolved_model)

          {:cont, {:ok, [updated | acc]}}
        else
          case resolve_session_model(scope, target_agent_id, entry["model"], runs_on) do
            {:ok, resolved_model} ->
              updated =
                entry
                |> Map.delete("model")
                |> put_present("model", resolved_model)

              {:cont, {:ok, [updated | acc]}}

            {:error, _} = err ->
              {:halt, err}
          end
        end
      end)
      |> case do
        {:ok, list} -> {:ok, %{pre_sessions | sessions: Enum.reverse(list)}}
        {:error, _} = err -> err
      end
    end
  end

  defp check_multi_session_capability(_scope, nil, _multi?), do: :ok
  defp check_multi_session_capability(_scope, _runs_on, false), do: :ok

  defp check_multi_session_capability(scope, runs_on, true) when is_map(runs_on) do
    case SalixIM.Ports.TaskStations.check_multi_session(scope.tenant_id, scope.group_id, runs_on) do
      :ok ->
        :ok

      {:error, :station_outdated} ->
        {:error, :station_outdated}

      {:error, {:station_outdated, _info}} ->
        {:error, :station_outdated}

      {:error, reason} ->
        {:error, {:bad_request, TaskPlacement.message({:runs_on, reason, :requested})}}
    end
  end

  defp require_router_for_multi_session(%{agent: %{"role" => "router"}}), do: :ok

  defp require_router_for_multi_session(_scope),
    do: {:error, {:bad_request, "multi-session tasks are only allowed for the Group Router"}}

  defp validate_initial_wake(nil), do: {:ok, nil}

  defp validate_initial_wake(value) when is_binary(value) do
    if value in SalixIM.TaskSessionSlots.initial_wakes(),
      do: {:ok, value},
      else: {:error, {:bad_request, "initial_wake must be \"primary\" or \"all\""}}
  end

  defp validate_initial_wake(_),
    do: {:error, {:bad_request, "initial_wake must be \"primary\" or \"all\""}}

  defp validate_human_wakeup_policy(nil), do: {:ok, nil}

  defp validate_human_wakeup_policy(value) when is_binary(value) do
    if value in SalixIM.TaskSessionSlots.human_wakeup_policies(),
      do: {:ok, value},
      else:
        {:error,
         {:bad_request, "human_wakeup_policy must be \"primary_only\" or \"all_sessions\""}}
  end

  defp validate_human_wakeup_policy(_),
    do:
      {:error, {:bad_request, "human_wakeup_policy must be \"primary_only\" or \"all_sessions\""}}

  defp validate_sessions_list(sessions) when is_list(sessions) do
    max = SalixIM.TaskSessionSlots.max_task_worker_sessions()

    cond do
      sessions == [] ->
        {:error, {:bad_request, "sessions must contain between 1 and #{max} entries"}}

      length(sessions) > max ->
        {:error, {:bad_request, "sessions cannot exceed #{max} worker sessions"}}

      not Enum.all?(sessions, &is_map/1) ->
        {:error, {:bad_request, "each entry in sessions must be an object"}}

      true ->
        {:ok, sessions}
    end
  end

  defp validate_sessions_list(_),
    do: {:error, {:bad_request, "sessions must be an array of session specifications"}}

  defp reject_excluded_multi_session_task_pre(sessions, loop, schedule, triage, params) do
    multi? = length(sessions) > 1

    cond do
      not multi? ->
        :ok

      is_map(loop) ->
        {:error, {:bad_request, "multi-session Tasks are not supported for Loop Tasks"}}

      is_map(params["collaboration"]) ->
        {:error, {:bad_request, "multi-session Tasks are not supported for Collaborative Tasks"}}

      not is_nil(triage) ->
        {:error,
         {:bad_request, "multi-session Tasks are not supported for Triage Investigations"}}

      is_map(schedule) and map_size(schedule) > 0 ->
        {:error, {:bad_request, "multi-session Tasks are not supported for Scheduled Tasks"}}

      true ->
        :ok
    end
  end

  defp prenormalize_sessions(raw_sessions) do
    allowed_keys = ~w(slot label model role primary wake_on_create)

    with :ok <-
           Enum.reduce_while(raw_sessions, :ok, fn entry, :ok ->
             unknown = Map.keys(entry) -- allowed_keys

             if unknown == [],
               do: {:cont, :ok},
               else:
                 {:halt,
                  {:error,
                   {:bad_request,
                    "unknown session fields: #{Enum.join(Enum.sort(unknown), ", ")}"}}}
           end) do
      primary_indices =
        raw_sessions
        |> Enum.with_index()
        |> Enum.filter(fn {entry, _idx} -> entry["primary"] == true end)
        |> Enum.map(&elem(&1, 1))

      if length(primary_indices) > 1 do
        {:error, {:bad_request, "at most one session may set primary: true"}}
      else
        primary_index = List.first(primary_indices) || 0

        raw_sessions
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {entry, idx}, {:ok, acc, seen_slots} ->
          primary? = idx == primary_index
          raw_slot = SalixIM.TaskSessionSlots.normalize_target_key(entry["slot"])
          slot = if primary?, do: raw_slot || "lead", else: raw_slot

          with :ok <- validate_session_slot(primary?, slot, seen_slots),
               {:ok, label} <- validate_optional_string(entry["label"], "label"),
               {:ok, role} <- validate_optional_string(entry["role"], "role") do
            normalized =
              %{
                "slot" => slot,
                "primary" => primary?,
                "wake_on_create" => entry["wake_on_create"] == true
              }
              |> put_present("label", label)
              |> put_present("role", role)
              |> put_present("model", entry["model"])

            {:cont, {:ok, [normalized | acc], MapSet.put(seen_slots, slot)}}
          else
            {:error, _} = err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, list, _seen} -> {:ok, Enum.reverse(list)}
          {:error, _} = err -> err
        end
      end
    end
  end

  defp validate_session_slot(true, slot, seen_slots) do
    cond do
      not SalixIM.TaskSessionSlots.valid_primary_slot?(slot) ->
        {:error, {:bad_request, "invalid primary session slot #{inspect(slot)}"}}

      MapSet.member?(seen_slots, slot) ->
        {:error, {:bad_request, "duplicate session slot #{inspect(slot)}"}}

      true ->
        :ok
    end
  end

  defp validate_session_slot(false, slot, seen_slots) do
    cond do
      not SalixIM.TaskSessionSlots.valid_secondary_slot?(slot) ->
        {:error,
         {:bad_request,
          "secondary session slot must match ^[a-z0-9][a-z0-9_-]{0,31}$ and must not be reserved (all, router, delegator, lead)"}}

      MapSet.member?(seen_slots, slot) ->
        {:error, {:bad_request, "duplicate session slot #{inspect(slot)}"}}

      true ->
        :ok
    end
  end

  defp resolve_session_model(_scope, _worker_agent_id, nil, _runs_on), do: {:ok, nil}

  defp resolve_session_model(scope, worker_agent_id, model, runs_on) when is_map(model) do
    placement_scope =
      %{
        tenant_id: scope.tenant_id,
        group_id: scope.group_id
      }
      |> put_present(:account_id, scope[:account_id])

    case TaskPlacement.resolve_session_model(placement_scope, worker_agent_id, model, runs_on) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:bad_request, TaskPlacement.message(reason)}}
    end
  end

  defp resolve_session_model(_scope, _worker_agent_id, _model, _runs_on),
    do: {:error, {:bad_request, "session model must be an object"}}

  defp validate_optional_string(nil, _field), do: {:ok, nil}

  defp validate_optional_string(value, _field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, trimmed}
    end
  end

  defp validate_optional_string(_value, field),
    do: {:error, {:bad_request, "#{field} must be a string"}}

  defp add_task_session(scope, params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(conversation_id slot label model role message),
             "im_api.internal.task.add_session"
           ),
         {:ok, conversation_id} <- required_string(params, "conversation_id"),
         {:ok, slot} <- required_string(params, "slot"),
         :ok <- validate_add_session_slot(slot),
         {:ok, label} <- validate_optional_string(params["label"], "label"),
         {:ok, role} <- validate_optional_string(params["role"], "role"),
         {:ok, message} <- validate_optional_string(params["message"], "message"),
         {:ok, group} <- GroupDirectory.get_group(scope.group_id),
         :ok <- authorize_add_session_router(scope, group),
         {:ok, task} <- get_conversation(scope.group_id, conversation_id),
         :ok <- authorize_add_session_task(scope, task),
         worker_agent_id when is_binary(worker_agent_id) and worker_agent_id != "" <-
           task["task_worker_agent_id"],
         runs_on = task["runs_on"],
         :ok <- check_multi_session_capability(scope, runs_on, true),
         {:ok, resolved_model} <-
           resolve_session_model(scope, worker_agent_id, params["model"], runs_on),
         notification_filter =
           if(is_map(runs_on),
             do: SalixIM.TaskConversationInput.station_worker_filter(),
             else: %{"messages" => "mentioned", "statuses" => "none"}
           ),
         {:ok, prepared} <-
           ConversationInput.prepare_agent_for_create(
             scope.group_id,
             task,
             %{
               "actor_type" => "agent",
               "agent_id" => worker_agent_id,
               "role_label" => "worker",
               "target_key" => slot,
               "state" => "active",
               "notification_filter" => notification_filter
             },
             session_model: resolved_model,
             session_slot: slot,
             session_label: label,
             role_instructions: role
           ),
         {:ok, create_status, participant} <-
           SalixIM.ConversationServer.ensure_group_conversation_agent_participant_with_status(
             scope.group_id,
             conversation_id,
             prepared
           ),
         :ok <-
           join_station_or_compensate(
             scope,
             task,
             worker_agent_id,
             participant,
             slot,
             resolved_model,
             create_status == :created
           ),
         {:ok, kickoff_result} <-
           maybe_send_add_session_kickoff(scope, conversation_id, participant, slot, message) do
      {:ok,
       %{
         "added" => true,
         "conversation_id" => conversation_id,
         "participant_id" => participant["participant_id"],
         "slot" => slot
       }
       |> put_present("label", label)
       |> put_present("kickoff_message_id", kickoff_result && kickoff_result["message_id"])}
    else
      {:error, reason} -> {:error, control_error(reason)}
      _ -> {:error, "Task has no worker agent"}
    end
  end

  defp validate_add_session_slot(slot) do
    if SalixIM.TaskSessionSlots.valid_secondary_slot?(slot),
      do: :ok,
      else:
        {:error,
         {:bad_request,
          "slot must match ^[a-z0-9][a-z0-9_-]{0,31}$ and must not be reserved (all, router, delegator, lead)"}}
  end

  defp authorize_add_session_router(scope, group) do
    if group["router_agent_id"] == scope.agent_id,
      do: :ok,
      else: {:error, {:forbidden, "only the Group Router may add Task sessions"}}
  end

  defp authorize_add_session_task(scope, task) do
    cond do
      task["kind"] != "agent_task" ->
        {:error, {:bad_request, "not an agent_task conversation"}}

      task["created_by_agent_id"] != scope.agent_id ->
        {:error, {:forbidden, "only the Task's creating Router may add sessions"}}

      task["status"] not in ["active", "ready_for_review"] ->
        {:error, {:bad_request, "cannot add a session to a Task in status #{task["status"]}"}}

      is_map(task["workflow"]) ->
        {:error, {:bad_request, "cannot add a session to an unmigrated legacy Task Graph"}}

      is_map(get_in(task, ["metadata", "collaboration"])) ->
        {:error, {:bad_request, "multi-session Tasks are not supported for Collaborative Tasks"}}

      is_map(get_in(task, ["source_refs", "triage_investigation"])) ->
        {:error,
         {:bad_request, "multi-session Tasks are not supported for Triage Investigations"}}

      is_binary(get_in(task, ["schedule", "schedule_id"])) and
          String.trim(get_in(task, ["schedule", "schedule_id"])) != "" ->
        {:error, {:bad_request, "multi-session Tasks are not supported for Scheduled Tasks"}}

      task_has_loop?(scope.group_id, task) ->
        {:error, {:bad_request, "multi-session Tasks are not supported for Loop Tasks"}}

      true ->
        :ok
    end
  end

  defp join_station_or_compensate(
         scope,
         task,
         worker_agent_id,
         participant,
         slot,
         resolved_model,
         created?
       ) do
    invite_id = SalixStore.Ids.new_session_id()
    expected_epoch = get_in(participant, ["payload", "activation_epoch"])
    expected_updated_at = participant["updated_at"]

    case maybe_join_station_session(
           scope,
           task,
           worker_agent_id,
           participant,
           slot,
           resolved_model,
           invite_id
         ) do
      :ok ->
        :ok

      {:error, reason} = error ->
        # Only compensate (deactivate) when:
        # 1. this call freshly created the participant,
        # 2. the join failure is a deterministic permanent refusal (`:station_outdated` /
        #    `:station_refused` / `:slot_config_conflict`).
        # Authoritative activation-epoch + device-locked DB check runs INSIDE
        # `ConversationParticipantActor` via arity-2 `verify_unbound_fun` so concurrent
        # reactivation, new pending invite B, or DB bindings are NEVER clobbered.
        if created? and permanent_join_failure?(reason) do
          verify_unbound_fun = fn stale_tok, current_participant ->
            cur_epoch =
              if is_map(current_participant),
                do: get_in(current_participant, ["payload", "activation_epoch"]),
                else: nil

            reactivated? =
              is_map(current_participant) and
                ((is_integer(expected_epoch) and cur_epoch != expected_epoch) or
                   (is_nil(expected_epoch) and is_integer(cur_epoch) and cur_epoch > 0) or
                   (is_integer(expected_updated_at) and
                      is_integer(current_participant["updated_at"]) and
                      current_participant["updated_at"] != expected_updated_at and
                      current_participant["state"] == "active"))

            if reactivated? do
              {:abort, :superseded}
            else
              slot_verify_unbound(scope.group_id, task, slot, stale_tok, invite_id)
            end
          end

          _ =
            SalixIM.ConversationServer.deactivate_unbound_task_participant(
              scope.group_id,
              task["conversation_id"],
              participant["participant_id"],
              nil,
              verify_unbound_fun
            )
        end

        error
    end
  end

  defp permanent_join_failure?(:station_outdated), do: true
  defp permanent_join_failure?(:slot_config_conflict), do: true

  defp permanent_join_failure?({:station_refused, why}) when is_binary(why),
    do: not String.contains?(why, "no_active_primary")

  defp permanent_join_failure?({:station_refused, _}), do: true
  defp permanent_join_failure?(_), do: false

  defp slot_verify_unbound(
         group_id,
         %{"conversation_id" => conv_id, "runs_on" => %{"device_id" => device_id}},
         slot,
         stale_tok,
         expected_invite_id
       )
       when is_binary(device_id) and device_id != "" do
    case SalixIM.Ports.TaskStations.verify_slot_unbound(
           group_id,
           conv_id,
           device_id,
           slot,
           stale_tok,
           expected_invite_id
         ) do
      :not_implemented ->
        fallback_slot_verify_unbound(
          group_id,
          conv_id,
          device_id,
          slot,
          stale_tok,
          expected_invite_id
        )

      verdict ->
        verdict
    end
  end

  defp slot_verify_unbound(
         group_id,
         %{"conversation_id" => conv_id},
         slot,
         stale_tok,
         _expected_invite_id
       ) do
    case SalixStore.StationTaskSessions.of_task(group_id, conv_id) do
      {:ok, rows} ->
        live =
          Enum.find(rows, fn r ->
            not SalixStore.StationTaskSessions.awaited?(r) and
              (get_in(r.start || %{}, ["slot"]) || "lead") == slot and
              (is_nil(stale_tok) or stale_tok == "" or
                 (get_in(r.start || %{}, ["binding_token"]) || r.session) != stale_tok)
          end)

        case live do
          nil -> :unbound
          r -> {:bound, get_in(r.start || %{}, ["binding_token"]) || r.session}
        end

      {:error, _} ->
        :unknown
    end
  end

  defp slot_verify_unbound(_group_id, _task, _slot, _stale_tok, _expected_invite_id), do: :unknown

  defp fallback_slot_verify_unbound(
         group_id,
         conv_id,
         device_id,
         slot,
         stale_tok,
         expected_invite_id
       ) do
    check_fun = fn ->
      case SalixStore.StationTaskSessions.of_task(group_id, conv_id) do
        {:ok, rows} ->
          live =
            Enum.find(rows, fn r ->
              not SalixStore.StationTaskSessions.awaited?(r) and r.device_id == device_id and
                (get_in(r.start || %{}, ["slot"]) || "lead") == slot and
                (is_nil(stale_tok) or stale_tok == "" or
                   (get_in(r.start || %{}, ["binding_token"]) || r.session) != stale_tok)
            end)

          cond do
            live != nil ->
              {:bound, get_in(live.start || %{}, ["binding_token"]) || live.session}

            is_binary(expected_invite_id) and expected_invite_id != "" ->
              primary_row =
                rows
                |> Enum.filter(&(&1.device_id == device_id))
                |> Enum.sort_by(fn r ->
                  is_prim =
                    case get_in(r.start || %{}, ["is_primary"]) do
                      v when is_boolean(v) -> v
                      _ -> (get_in(r.start || %{}, ["slot"]) || "lead") == "lead"
                    end

                  {if(is_prim, do: 0, else: 1), r.session}
                end)
                |> List.first()

              cur_pending =
                if primary_row do
                  primary_row.start
                  |> Map.get("pending_multi_starts", [])
                  |> List.wrap()
                  |> Enum.find(&(&1["slot"] == slot))
                else
                  nil
                end

              if is_map(cur_pending) and is_binary(cur_pending["invite_id"]) and
                   cur_pending["invite_id"] != "" and
                   cur_pending["invite_id"] != expected_invite_id do
                {:abort, :superseded}
              else
                :unbound
              end

            true ->
              :unbound
          end

        {:error, _} ->
          :unknown
      end
    end

    case SalixStore.StationTaskSessions.with_device_lock(group_id, conv_id, device_id, fn ->
           {:ok, check_fun.()}
         end) do
      {:ok, res} -> res
      {:error, _} -> :unknown
    end
  end

  defp maybe_join_station_session(
         _scope,
         %{"runs_on" => nil},
         _worker_agent_id,
         _participant,
         _slot,
         _resolved_model,
         _invite_id
       ),
       do: :ok

  defp maybe_join_station_session(
         scope,
         %{"runs_on" => %{"device_id" => device_id} = runs_on} = task,
         worker_agent_id,
         participant,
         slot,
         resolved_model,
         invite_id
       )
       when is_binary(device_id) and device_id != "" do
    conversation_id = task["conversation_id"]

    start =
      SalixIM.TaskConversationInput.station_start(
        worker_agent_id,
        resolved_model,
        SalixIM.TaskConversationInput.secondary_repo(task["repo"], conversation_id, slot),
        task["mini_app"],
        slot: slot,
        is_primary: false,
        participant_id: participant["participant_id"],
        person: SalixIM.TaskConversationInput.canonical_person(task)
      )

    SalixIM.Ports.TaskStations.add_session(%{
      tenant_id: scope.tenant_id,
      group_id: scope.group_id,
      conversation_id: conversation_id,
      device_id: device_id,
      runs_on: runs_on,
      agent_id: worker_agent_id,
      participant_id: participant["participant_id"],
      invite_id: invite_id,
      slot: slot,
      start: start
    })
  end

  defp maybe_join_station_session(
         _scope,
         _task,
         _worker_agent_id,
         _participant,
         _slot,
         _model,
         _invite_id
       ),
       do: :ok

  defp task_has_loop?(group_id, task) do
    is_map(task["loop"]) or
      case SalixIM.TaskLoop.get(group_id, task["conversation_id"]) do
        {:ok, nil} -> false
        {:ok, view} when is_map(view) -> true
        {:error, _} -> true
      end
  end

  defp maybe_send_add_session_kickoff(_scope, _conversation_id, _participant, _slot, nil),
    do: {:ok, nil}

  defp maybe_send_add_session_kickoff(scope, conversation_id, participant, slot, text)
       when is_binary(text) and text != "" do
    pid = participant["participant_id"]

    idempotency_suffix =
      case Map.get(scope, :tool_call_id) do
        id when is_binary(id) and id != "" ->
          id

        _ ->
          :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)
      end

    SalixIM.ConversationServer.append_group_conversation_message(
      scope.group_id,
      conversation_id,
      %{
        "actor_type" => "agent",
        "agent_id" => scope.agent_id,
        "content" => text,
        "client_request_id" =>
          "task-add-session:#{conversation_id}:#{slot}:#{idempotency_suffix}",
        "delivery_filter" => %{"participant_ids" => [pid]},
        "mentions" => %{"participant_ids" => [pid]}
      }
    )
  end

  defp station_task_error(:device_offline),
    do: "the station hosting this Task is offline; it can be read and written in once it is back"

  defp station_task_error(:not_found), do: "unknown station-hosted Task"

  defp station_task_error({:station_refused, why}), do: "the station refused: " <> why
  defp station_task_error(reason), do: control_error(reason)

  defp read_conversation(scope, params) do
    conversation_id = str(params["conversation_id"])
    message_id = str(params["message_id"])
    limit = int_or(params["limit"], 0)
    after_seq = int_or(params["after_seq"], -1)
    tail = int_or(params["tail"], 0)

    opts =
      []
      |> then(&if(limit > 0, do: Keyword.put(&1, :limit, limit), else: &1))
      |> then(&if(after_seq >= 0, do: Keyword.put(&1, :after_seq, after_seq), else: &1))
      |> then(&if(tail > 0, do: Keyword.put(&1, :tail, tail), else: &1))

    with {:ok, conversation} <- get_conversation(scope.group_id, conversation_id),
         {:ok, participants, participants_has_more?} <-
           list_conversation_participants_with_more(scope.group_id, conversation_id, []),
         {:ok, messages} <-
           read_conversation_messages(scope.group_id, conversation_id, message_id, opts),
         {:ok, effective_conversation} <-
           maybe_refresh_task_conversation_for_worker_read(scope, conversation, conversation_id),
         {:ok, effective_conversation} <-
           maybe_mark_effective_multi_session(
             scope,
             effective_conversation,
             participants,
             participants_has_more?
           ),
         {:ok, current} <-
           resolve_read_conversation_participant(scope, effective_conversation, participants),
         messages = filter_visible_messages(messages, effective_conversation, current),
         {:ok, messages} <- ConversationAttachments.materialize_messages(scope.agent_id, messages),
         {:ok, task_lifecycle} <- public_task_lifecycle(effective_conversation) do
      state = build_read_state(effective_conversation["kind"], current, participants, messages)

      result =
        %{
          "conversation_id" => conversation_id,
          "state" => state,
          "participants" => public_participants(participants),
          "messages" => Enum.map(messages, &public_message/1)
        }
        |> put_present("task_lifecycle", task_lifecycle)
        |> put_present("current_participant_id", current && current["participant_id"])

      {:ok, result}
    end
  end

  # One Task's files, a name search (in one Task with conversation_id), or the
  # Group's newest files.
  defp task_files_read(params) do
    conversation_id = str(params["conversation_id"])
    query = str(params["query"])

    with {:ok, limit} <- task_files_limit(params["limit"]),
         :ok <- task_files_conversation(conversation_id) do
      cursor = if str(params["cursor"]) == "", do: nil, else: str(params["cursor"])
      scope = if conversation_id == "", do: [], else: [conversation_id: conversation_id]

      cond do
        String.trim(query) != "" ->
          {:ok, {:search, query, [limit: min(limit, SalixStore.TaskFiles.max_search())] ++ scope}}

        conversation_id != "" ->
          {:ok, {:task, conversation_id, [limit: limit, cursor: cursor]}}

        true ->
          {:ok, {:group, [limit: limit, cursor: cursor]}}
      end
    end
  end

  defp task_files_limit(nil), do: {:ok, @task_files_default_limit}

  defp task_files_limit(limit) when is_integer(limit) and limit in 1..@task_files_max_limit,
    do: {:ok, limit}

  defp task_files_limit(_limit),
    do: {:error, "limit must be an integer between 1 and #{@task_files_max_limit}"}

  defp task_files_conversation(conversation_id) do
    case StationHostedTasks.parse(conversation_id) do
      {_station_id, _thread} ->
        {:error,
         "A Task a station hosts keeps no files here. Read it with internal.read_conversation."}

      _canonical ->
        :ok
    end
  end

  defp read_task_files(group_id, {:search, query, opts}),
    do: SalixIM.TaskFiles.search(group_id, query, opts)

  defp read_task_files(group_id, {:task, conversation_id, opts}),
    do: SalixIM.TaskFiles.list_task(group_id, conversation_id, opts)

  defp read_task_files(group_id, {:group, opts}), do: SalixIM.TaskFiles.list_group(group_id, opts)

  defp usage_by(by) when by in @usage_by, do: {:ok, String.to_existing_atom(by)}
  defp usage_by(_by), do: {:error, "by must be one of #{Enum.join(@usage_by, ", ")}"}

  defp usage_source(nil), do: {:ok, nil}
  defp usage_source(source) when source in @usage_sources, do: {:ok, source}

  defp usage_source(_source),
    do: {:error, "source must be one of #{Enum.join(@usage_sources, ", ")}"}

  defp optional_text(params, key) do
    case Map.fetch(params, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _invalid} -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp station_task_list_options(params) do
    with {:ok, source} <- optional_text(params, "source"),
         true <- source in [nil, "stillfail"] || {:error, "source must be stillfail"},
         {:ok, created_by} <- optional_text(params, "created_by"),
         {:ok, status} <- optional_text(params, "status"),
         true <-
           status in [nil | @station_task_statuses] ||
             {:error, "status must be one of #{Enum.join(@station_task_statuses, ", ")}"},
         {:ok, attention} <- optional_text(params, "attention"),
         true <-
           attention in [nil | @station_task_attentions] ||
             {:error, "attention must be one of #{Enum.join(@station_task_attentions, ", ")}"},
         {:ok, waits_for} <- optional_text(params, "waits_for"),
         {:ok, device} <- optional_text(params, "device_id"),
         {:ok, query} <- station_task_query(params),
         {:ok, since} <- station_task_since(params["since"]),
         {:ok, limit} <- station_task_limit(params["limit"]),
         {:ok, after_row} <- station_task_after(params["cursor"]) do
      {:ok,
       [limit: limit]
       |> maybe_put_keyword(:source, source)
       |> maybe_put_keyword(:created_by, created_by)
       |> maybe_put_keyword(:status, status)
       |> maybe_put_keyword(:attention, attention)
       |> maybe_put_keyword(:waits_for, waits_for)
       |> maybe_put_keyword(:device_id, device)
       |> maybe_put_keyword(:query, query)
       |> maybe_put_keyword(:since, since)
       |> maybe_put_keyword(:after, after_row)}
    end
  end

  defp station_task_query(params) do
    case optional_text(params, "query") do
      {:ok, query} when is_binary(query) and byte_size(query) > @station_task_query_max ->
        {:error, "query must be at most #{@station_task_query_max} bytes"}

      other ->
        other
    end
  end

  # Names of the still.fail workspaces the page's rows are of, by device id:
  # one bounded read of the Group's still.fail devices, none when no row is of
  # one. A failed read leaves the names out.
  defp stillfail_workspace_names(group_id, rows) do
    stillfail = for row <- rows, String.starts_with?(row.station_id, "stillfail-"), do: row

    with [_ | _] <- stillfail,
         {:ok, names} when is_map(names) <- StationHostedTasks.workspace_names(group_id) do
      names
    else
      _ -> %{}
    end
  end

  defp station_task_since(nil), do: {:ok, nil}
  defp station_task_since(since) when is_integer(since) and since >= 0, do: {:ok, since}
  defp station_task_since(_since), do: {:error, "since must be a time in unix milliseconds"}

  defp station_task_limit(nil), do: {:ok, 100}

  defp station_task_limit(limit) when is_integer(limit) and limit in 1..@station_task_list_max,
    do: {:ok, limit}

  defp station_task_limit(_limit),
    do: {:error, "limit must be an integer between 1 and #{@station_task_list_max}"}

  defp station_task_cursor(row),
    do:
      Base.url_encode64(Jason.encode!([row.last_activity_at, row.station_id, row.thread]),
        padding: false
      )

  defp station_task_after(nil), do: {:ok, nil}

  defp station_task_after(cursor) when is_binary(cursor) and byte_size(cursor) <= 1024 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [at, station, thread]}
         when is_integer(at) and is_binary(station) and is_binary(thread) <-
           Jason.decode(json) do
      {:ok, {at, station, thread}}
    else
      _ -> {:error, "cursor must be the next_cursor of the previous page"}
    end
  end

  defp station_task_after(_cursor),
    do: {:error, "cursor must be the next_cursor of the previous page"}

  defp task_list_options(params) do
    with :ok <-
           validate_param_keys(
             params,
             ~w(cursor limit archive status),
             "im_api.internal.task.list"
           ),
         {:ok, limit} <- task_list_limit(params),
         {:ok, cursor} <- task_list_cursor(params),
         {:ok, statuses} <- task_list_statuses(params),
         {:ok, archive} <- task_list_archive(params, statuses) do
      {:ok,
       [limit: limit, archive: archive]
       |> maybe_put_keyword(:cursor, cursor)
       |> maybe_put_keyword(:statuses, statuses)}
    end
  end

  defp task_list_statuses(params) do
    case Map.fetch(params, "status") do
      :error ->
        {:ok, nil}

      {:ok, status} when is_binary(status) ->
        trimmed = String.trim(status)

        if SalixIM.TaskStatus.valid?(trimmed),
          do: {:ok, [trimmed]},
          else: {:error, invalid_task_list_status_error()}

      {:ok, statuses} when is_list(statuses) and statuses != [] ->
        trimmed = Enum.map(statuses, &if(is_binary(&1), do: String.trim(&1), else: :invalid))

        if Enum.all?(trimmed, &SalixIM.TaskStatus.valid?/1),
          do: {:ok, Enum.uniq(trimmed)},
          else: {:error, invalid_task_list_status_error()}

      {:ok, _invalid} ->
        {:error, invalid_task_list_status_error()}
    end
  end

  defp invalid_task_list_status_error do
    "status must be one of #{Enum.join(SalixIM.TaskStatus.canonical(), ", ")} or a non-empty array of them"
  end

  defp task_list_archive(params, statuses) do
    case Map.fetch(params, "archive") do
      :error ->
        if is_list(statuses) and "archived" in statuses,
          do: {:ok, "include"},
          else: {:ok, "exclude"}

      {:ok, mode} when mode in ["exclude", "only", "include"] ->
        {:ok, mode}

      {:ok, _invalid} ->
        {:error, "archive must be one of exclude, only, include"}
    end
  end

  defp task_list_limit(params) do
    case Map.fetch(params, "limit") do
      :error -> {:ok, @task_list_default_limit}
      {:ok, limit} when is_integer(limit) and limit in 1..@task_list_max_limit -> {:ok, limit}
      {:ok, _invalid} -> {:error, "limit must be an integer between 1 and 1000"}
    end
  end

  defp task_list_cursor(params) do
    case Map.fetch(params, "cursor") do
      :error ->
        {:ok, nil}

      {:ok, cursor} when is_binary(cursor) and cursor != "" ->
        if String.length(cursor) <= @task_list_cursor_max_length,
          do: {:ok, cursor},
          else: {:error, "cursor must be a non-empty string of at most 1024 characters"}

      {:ok, _invalid} ->
        {:error, "cursor must be a non-empty string of at most 1024 characters"}
    end
  end

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  # A coding Task's sandbox terminal link (`SalixIM.Ports.TaskStations.terminal_urls/2`),
  # for the Router to give the user who asks to work in the sandbox.
  defp put_terminal_url(response, group_id, %{"kind" => "sandbox"}) do
    id = response["conversation_id"]

    case SalixIM.Ports.TaskStations.terminal_urls(group_id, [id]) do
      %{^id => url} -> Map.put(response, "terminal_url", url)
      _ -> response
    end
  end

  defp put_terminal_url(response, _group_id, _runs_on), do: response

  # The page's coding Tasks' links, in one read.
  defp put_terminal_urls(tasks, group_id) do
    ids = for %{"kind" => "agent_task", "task_id" => id} <- tasks, do: id
    urls = SalixIM.Ports.TaskStations.terminal_urls(group_id, ids)

    Enum.map(tasks, fn task ->
      case urls[task["task_id"]] do
        nil -> task
        url -> Map.put(task, "terminal_url", url)
      end
    end)
  end

  defp task_list_entry(conversation, loops) do
    task_id = conversation["conversation_id"]
    kind = conversation["kind"]

    conversation
    |> Map.take(~w(title status activity_status created_at updated_at))
    |> Map.put("task_id", task_id)
    |> Map.put("kind", kind)
    |> Map.put("task_ref", task_ref(task_id, kind))
    |> put_present("loop", SalixIM.TaskLoop.summary(loops[task_id]))
  end

  # The Loops of the page's Tasks, one indexed read per 50 Tasks.
  defp task_list_loops(group_id, conversations) do
    conversations
    |> Enum.filter(&(&1["kind"] == "agent_task"))
    |> Enum.map(& &1["conversation_id"])
    |> Enum.chunk_every(50)
    |> Enum.reduce_while({:ok, %{}}, fn ids, {:ok, acc} ->
      case SalixIM.Ports.TaskLoops.task_loops(group_id, ids) do
        {:ok, loops} -> {:cont, {:ok, Map.merge(acc, loops)}}
        {:error, reason} -> {:halt, {:error, {:task_loops, reason}}}
      end
    end)
  end

  defp task_dismiss_ids(ids) when is_list(ids) and ids != [] do
    ids = Enum.uniq(ids)

    cond do
      not Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")) ->
        {:error, "conversation_ids must be non-empty strings"}

      length(ids) > @task_dismiss_max ->
        {:error, "conversation_ids accepts at most #{@task_dismiss_max} ids"}

      true ->
        {:ok, ids}
    end
  end

  defp task_dismiss_ids(_), do: {:error, "conversation_ids must be a non-empty array"}

  defp task_list_loops_by_ids(group_id, ids) do
    case SalixIM.Ports.TaskLoops.task_loops(group_id, ids) do
      {:ok, loops} -> {:ok, loops}
      {:error, reason} -> {:error, {:task_loops, reason}}
    end
  end

  # Dismiss clears a finished Task from its owner's chat Task panel
  # (`SalixIM.Ports.TaskPanelDismissals`). It changes no Task fact. Only the
  # Router that created a completed or cancelled, non-Loop Task with one
  # owning User may do it, for that User.
  defp dismiss_tasks(scope, ids, loops) do
    checked = Enum.map(ids, &{&1, check_dismissible(scope, &1, loops)})

    written =
      checked
      |> Enum.flat_map(fn
        {_id, {:ok, owner, task}} -> [{owner, task}]
        _ -> []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {owner, tasks} ->
        dismissals =
          Enum.map(
            tasks,
            &%{"task_id" => &1["conversation_id"], "revision" => &1["run_started_at"] || 0}
          )

        {owner, SalixIM.Ports.TaskPanelDismissals.dismiss(owner, dismissals)}
      end)

    Enum.map(checked, fn
      {id, {:ok, owner, _task}} ->
        case written[owner] do
          {:ok, _} -> %{"conversation_id" => id, "dismissed" => true, "status" => "dismissed"}
          {:error, reason} -> dismiss_skipped(id, "dismissal not saved: #{control_error(reason)}")
        end

      {id, {:skip, reason}} ->
        dismiss_skipped(id, reason)
    end)
  end

  defp check_dismissible(scope, id, loops) do
    case Conversations.get_group_conversation(scope.group_id, id) do
      {:ok, %{"kind" => "agent_task"} = task} ->
        owner = task["owner_user_id"]

        cond do
          task["created_by_agent_id"] != scope.agent_id ->
            {:skip, "not created by this Router"}

          Map.has_key?(loops, id) ->
            {:skip, "Loop Tasks are not dismissed"}

          task["status"] not in ["completed", "cancelled"] ->
            {:skip, "status #{task["status"]} is not dismissible; only completed or cancelled"}

          not (is_binary(owner) and String.trim(owner) != "") ->
            {:skip, "the Task has no single owning user to dismiss it for"}

          true ->
            {:ok, owner, task}
        end

      {:ok, _other} ->
        {:skip, "not a Task"}

      {:error, :not_found} ->
        {:skip, "conversation not found"}

      {:error, reason} ->
        {:skip, control_error(reason)}
    end
  end

  defp dismiss_skipped(id, reason),
    do: %{
      "conversation_id" => id,
      "dismissed" => false,
      "status" => "skipped",
      "reason" => reason
    }

  defp set_tasks_archived(scope, params, action, tool_name)
       when action in [:archive, :unarchive] do
    with :ok <- validate_param_keys(params, ~w(conversation_ids), tool_name),
         {:ok, ids} <- task_archive_ids(params["conversation_ids"]),
         :ok <- authorize_task_update(scope) do
      results = Enum.map(ids, &set_one_task_archived(scope, &1, action))

      {flag_key, count_key} =
        case action do
          :archive -> {"archived", "archived_count"}
          :unarchive -> {"unarchived", "unarchived_count"}
        end

      {:ok,
       %{
         "results" => results,
         count_key => Enum.count(results, & &1[flag_key]),
         "failed_count" => Enum.count(results, &(not &1[flag_key]))
       }}
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp task_archive_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")) do
      ids = ids |> Enum.map(&String.trim/1) |> Enum.uniq()

      if length(ids) > @task_archive_max do
        {:error, "conversation_ids accepts at most #{@task_archive_max} ids"}
      else
        {:ok, ids}
      end
    else
      {:error, "conversation_ids must be non-empty strings"}
    end
  end

  defp task_archive_ids(_), do: {:error, "conversation_ids must be a non-empty array"}

  defp set_one_task_archived(scope, id, action) do
    with {:ok, conversation} <- get_conversation(scope.group_id, id),
         :ok <- authorize_conversation_update(scope, id),
         version when is_integer(version) and version > 0 <- conversation["updated_at"],
         {:ok, updated} <-
           SalixIM.ConversationServer.set_task_archived(scope.group_id, id, action, version) do
      case action do
        :archive ->
          %{
            "conversation_id" => id,
            "archived" => true,
            "status" => updated["status"],
            "updated_at" => updated["updated_at"]
          }
          |> maybe_put("archived_from_status", updated["archived_from_status"])

        :unarchive ->
          %{
            "conversation_id" => id,
            "unarchived" => true,
            "status" => updated["status"],
            "updated_at" => updated["updated_at"]
          }
      end
    else
      {:error, reason} ->
        archive_entry_error(action, id, archive_error_message(reason))

      _ ->
        archive_entry_error(action, id, "Task version is unavailable")
    end
  end

  defp archive_entry_error(:archive, id, message),
    do: %{"conversation_id" => id, "archived" => false, "error" => message}

  defp archive_entry_error(:unarchive, id, message),
    do: %{"conversation_id" => id, "unarchived" => false, "error" => message}

  defp archive_error_message({:conflict, message}) when is_binary(message), do: message
  defp archive_error_message({:bad_request, message}) when is_binary(message), do: message
  defp archive_error_message({:forbidden, message}) when is_binary(message), do: message
  defp archive_error_message(:not_found), do: "conversation not found"
  defp archive_error_message(message) when is_binary(message), do: message
  defp archive_error_message(reason), do: control_error(reason)

  defp task_ref(task_id, "agent_task") do
    %{
      "type" => "conversation_ref",
      "conversation_id" => task_id,
      "kind" => "agent_task",
      "presentation" => "inline"
    }
  end

  defp task_ref(task_id, kind) do
    %{
      "type" => "conversation_ref",
      "conversation_id" => task_id,
      "kind" => kind
    }
  end

  defp task_list_next_action(has_more, true) do
    task_list_next_action(has_more) <>
      " station_tasks are Tasks a station of the Group hosts, as the station last reported them: read one with im_api.internal.read_conversation and write in it with im_api.internal.send_message, with its task_id as conversation_id. Neither works while that station is offline; say so instead of creating a replacement Task."
  end

  defp task_list_next_action(has_more, false), do: task_list_next_action(has_more)

  defp task_list_next_action(has_more) do
    base =
      "Each tasks[].task_ref is the authoritative locator for that internal IM resource. Only agent_task refs include presentation=inline for rich Task mentions. Choose the candidates relevant to the current decision and follow the current send-message content contract when mentioning them. If the listed facts do not establish whether a resource is the same work, read that conversation before deciding; do not decide from its title alone. Continue the exact existing Task with im_api.internal.send_message and omitted mentions; The responsible Worker and Router subscribe to ordinary Task Messages. An ordinary Message does not reopen an ended Task. Do not create a replacement Task."

    if has_more do
      base <>
        " More results remain; when more candidates are needed, call im_api.internal.task.list again with params.cursor=next_cursor and the same limit. Do not claim the list is exhaustive until has_more is false."
    else
      base
    end
  end

  defp get_conversation(group_id, conversation_id) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      {:ok, conversation} -> {:ok, conversation}
      {:error, :not_found} -> {:error, "conversation not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp list_conversation_messages(group_id, conversation_id, opts) do
    case Conversations.list_group_conversation_messages(group_id, conversation_id, opts) do
      {:ok, messages} -> {:ok, messages}
      {:error, :not_found} -> {:error, "conversation not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp read_conversation_messages(group_id, conversation_id, "", opts),
    do: list_conversation_messages(group_id, conversation_id, opts)

  defp read_conversation_messages(group_id, conversation_id, message_id, _opts) do
    case Conversations.get_group_conversation_message(group_id, conversation_id, message_id) do
      {:ok, message} -> {:ok, [message]}
      {:error, :not_found} -> {:error, "message not found"}
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp list_conversation_participants(group_id, conversation_id, opts) do
    case list_conversation_participants_with_more(group_id, conversation_id, opts) do
      {:ok, participants, _has_more} -> {:ok, participants}
      {:error, _reason} = error -> error
    end
  end

  defp list_conversation_participants_with_more(group_id, conversation_id, opts) do
    case Conversations.list_group_conversation_participants(group_id, conversation_id, opts) do
      {:ok, %{"participants" => participants} = page} ->
        {:ok, participants, page["has_more"] == true}

      {:error, :not_found} ->
        {:error, "conversation not found"}

      {:error, reason} ->
        {:error, control_error(reason)}
    end
  end

  defp get_conversation_participant(group_id, conversation_id, participant_id) do
    with {:ok, _conversation} <- get_conversation(group_id, conversation_id) do
      case Conversations.get_group_conversation_participant(
             group_id,
             conversation_id,
             participant_id
           ) do
        {:ok, participant} -> {:ok, participant}
        {:error, :not_found} -> {:error, "participant not found"}
        {:error, {:bad_request, "invalid participant_id"}} -> {:error, "participant not found"}
        {:error, reason} -> {:error, control_error(reason)}
      end
    end
  end

  defp public_participants(participants) do
    participants
    |> Enum.map(&public_participant/1)
    |> Enum.reject(&(str(&1["participant_id"]) == ""))
  end

  defp public_task_lifecycle(%{"kind" => "agent_task"} = conversation) do
    {:ok,
     %{
       "kind" => "agent_task",
       "mode" => "plain",
       "status" => str(conversation["status"])
     }}
  end

  defp public_task_lifecycle(_conversation), do: {:ok, nil}

  defp public_message(message) when is_map(message) do
    # Message metadata and immutable attachment refs are private delivery state.
    message
    |> Map.drop([
      "metadata",
      "owner_inline_task_refs_v1",
      ProviderRecipientIdentity.owner_field()
    ])
    |> Map.update("content", [], fn content ->
      Enum.map(content, &Map.delete(&1, "blob_ref"))
    end)
  end

  defp public_participant(participant) do
    participant_id = str(participant["participant_id"])

    %{
      "participant_id" => participant_id,
      "type" => participant_type(participant),
      "name" => participant_name(participant, participant_id)
    }
  end

  defp participant_type(participant) do
    case str(participant["actor_type"]) do
      "" -> "unknown"
      type -> type
    end
  end

  defp participant_name(participant, participant_id) do
    if str(participant["actor_type"]) == "provider" do
      "provider participant"
    else
      participant_name_value(participant, participant_id)
    end
  end

  defp participant_name_value(participant, participant_id) do
    [
      participant["name"],
      participant["display_name"],
      participant["agent_name"],
      participant["user_name"],
      participant_id
    ]
    |> Enum.map(&str/1)
    |> Enum.find(&(&1 != ""))
  end

  defp current_agent_participant(participants, agent_id) do
    candidates =
      Enum.filter(participants, fn participant ->
        participant_agent?(participant) and str(participant["agent_id"]) == agent_id
      end)

    session_id =
      SalixIM.Provider.current_tool_context()
      |> Map.get("session_id")
      |> str()

    cond do
      session_id != "" ->
        Enum.find(candidates, &(str(get_in(&1, ["payload", "session_id"])) == session_id))

      length(candidates) == 1 ->
        List.first(candidates)

      true ->
        nil
    end
  end

  defp participant_status(group_id, conversation_id, participant) do
    with {:ok, status} <-
           ConversationParticipantActivity.read(
             group_id,
             conversation_id,
             str(participant["participant_id"]),
             participant
           ) do
      {:ok, status |> Map.delete("presentation_activity") |> drop_home_display_hints()}
    end
  end

  # These hints are for the owner's Home display. Agents query a Participant's
  # progress, not the other Conversations that its shared Session answers.
  defp drop_home_display_hints(%{"activity" => %{} = activity} = status),
    do: %{
      status
      | "activity" =>
          Map.drop(activity, [
            "working_conversation_ids",
            "waiting",
            "wait_tool",
            "wait_started_at"
          ])
    }

  defp drop_home_display_hints(status), do: status

  defp participant_status_error(:participant_status_unavailable),
    do: "participant status is unavailable"

  defp participant_status_error(:agent_id_missing), do: "participant agent id is missing"
  defp participant_status_error(:session_id_missing), do: "participant session id is missing"
  defp participant_status_error(:session_not_found), do: "participant session was not found"
  defp participant_status_error(:runtime_unavailable), do: "session activity is unavailable"

  # willow buildIMReadState: peer/own counts, peer_reply_state, and the
  # recommendation fields (omitted when empty, like Go's omitempty).
  defp build_read_state(conversation_kind, current, participants, messages) do
    current_id = (current && str(current["participant_id"])) || ""
    observer = current_id == ""

    active_peers =
      Enum.count(participants, fn p ->
        str(p["participant_id"]) != current_id and p["state"] == "active"
      end)

    own = Enum.count(messages, &(str(&1["participant_id"]) == current_id))
    peer = length(messages) - own
    only_current = own > 0 and peer == 0

    peer_reply_state =
      cond do
        peer > 0 -> "has_peer_messages"
        active_peers > 0 -> "waiting_for_peer"
        true -> "no_peer_activity"
      end

    state = %{
      "peer_reply_state" => peer_reply_state,
      "own_message_count" => own,
      "peer_message_count" => peer,
      "active_peer_count" => active_peers,
      "only_current_participant_messages" => only_current
    }

    cond do
      task_report_for_delegator?(conversation_kind, current) and
          peer_reply_state == "has_peer_messages" ->
        Map.put(
          state,
          "recommended_next_action",
          "A worker task report is available in this task conversation. Treat it as the delegated task result."
        )

      peer_reply_state == "has_peer_messages" and observer ->
        Map.put(
          state,
          "recommended_next_action",
          "Peer messages are available. Plain assistant text stays in the runtime transcript and is not visible in this conversation. If progress, a result, or an answer should be visible, use call(tool=\"im_api.internal.send_message\", params={\"connect_id\":\"internal\",\"conversation_id\":\"...\",\"content\":[{\"type\":\"text\",\"text\":\"...\"}]}) with this conversation_id. A request to reply, report, or answer is not complete until that call succeeds; otherwise stay silent."
        )

      peer_reply_state == "has_peer_messages" ->
        Map.put(
          state,
          "recommended_next_action",
          "Peer messages are available. Plain assistant text stays in the runtime transcript and is not visible in this conversation. If progress, a result, or an answer should be visible, reply with call(tool=\"im_api.internal.send_message\", params={\"connect_id\":\"internal\",\"conversation_id\":\"...\",\"content\":[{\"type\":\"text\",\"text\":\"...\"}]}) using this conversation_id. A request to reply, report, or answer is not complete until that call succeeds; otherwise stay silent."
        )

      peer_reply_state == "waiting_for_peer" and only_current ->
        Map.put(
          state,
          "recommended_next_action",
          "No peer reply is available yet. Continue any independent work now. Work that needs the peer response resumes when a later ordinary message arrives in this conversation."
        )

      true ->
        state
    end
  end

  defp validate_conversation_update(%{} = update) do
    cond do
      invalid_conversation_update_string_field(update) ->
        {:error,
         "#{invalid_conversation_update_string_field(update)} must be a string when present"}

      invalid_conversation_update_map_field(update) ->
        {:error,
         "#{invalid_conversation_update_map_field(update)} must be a JSON object when present"}

      Map.has_key?(update, "labels") and not valid_conversation_update_labels?(update["labels"]) ->
        {:error, "labels must be an array of strings when present"}

      true ->
        trimmed = normalize_conversation_update(update)

        cond do
          map_size(trimmed) == 0 ->
            {:error, "conversation update requires at least one mutable field"}

          trimmed["status"] == "archived" ->
            {:error, "Use im_api.internal.task.archive to archive a Task"}

          Map.has_key?(trimmed, "status") and
              not SalixIM.TaskStatus.ordinary_mutable?(trimmed["status"]) ->
            {:error, SalixIM.TaskStatus.invalid_ordinary_status_message(trimmed["status"])}

          true ->
            {:ok, trimmed}
        end
    end
  end

  defp validate_activation_conversation_update(
         provenance,
         %{"source_refs" => _source_refs}
       )
       when is_map(provenance) and map_size(provenance) > 0 do
    {:error, "activation-bound internal operations cannot mutate source_refs"}
  end

  defp validate_activation_conversation_update(_provenance, _conversation_update),
    do: :ok

  defp normalize_conversation_update(update) do
    string_fields =
      Enum.reduce(@conversation_update_string_fields, %{}, fn field, acc ->
        case update[field] do
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> acc
              trimmed -> Map.put(acc, field, trimmed)
            end

          _ ->
            acc
        end
      end)

    map_fields =
      Enum.reduce(@conversation_update_map_fields, string_fields, fn field, acc ->
        case update[field] do
          value when is_map(value) -> Map.put(acc, field, value)
          _ -> acc
        end
      end)

    case update["labels"] do
      labels when is_list(labels) ->
        labels =
          labels
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(map_fields, "labels", labels)

      _ ->
        map_fields
    end
  end

  defp invalid_conversation_update_string_field(update) do
    Enum.find(@conversation_update_string_fields, fn field ->
      Map.has_key?(update, field) and not (is_binary(update[field]) or is_nil(update[field]))
    end)
  end

  defp invalid_conversation_update_map_field(update) do
    Enum.find(@conversation_update_map_fields, fn field ->
      Map.has_key?(update, field) and not (is_map(update[field]) or is_nil(update[field]))
    end)
  end

  defp valid_conversation_update_labels?(labels) when is_list(labels),
    do: Enum.all?(labels, &is_binary/1)

  defp valid_conversation_update_labels?(_labels), do: false

  defp validate_inline_task_refs(content) do
    inline_refs =
      content
      |> List.wrap()
      |> Enum.filter(&(is_map(&1) and &1["presentation"] == "inline"))

    cond do
      length(inline_refs) > @inline_task_ref_limit ->
        {:error, "content exceeds the #{@inline_task_ref_limit} inline Task reference limit"}

      true ->
        inline_refs
        |> Enum.map(&canonical_inline_task_ref/1)
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, ref}, {:ok, refs} -> {:cont, {:ok, [ref | refs]}}
          {:error, reason}, _acc -> {:halt, {:error, reason}}
        end)
        |> case do
          {:ok, refs} -> {:ok, Enum.reverse(refs)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp canonical_inline_task_ref(%{
         "type" => "conversation_ref",
         "conversation_id" => conversation_id,
         "kind" => "agent_task",
         "presentation" => "inline"
       }) do
    if Ids.valid_conversation_id?(conversation_id) do
      {:ok,
       %{
         "type" => "conversation_ref",
         "conversation_id" => conversation_id,
         "kind" => "agent_task",
         "presentation" => "inline"
       }}
    else
      {:error, "inline Task conversation_ref.conversation_id must be canonical"}
    end
  end

  defp canonical_inline_task_ref(%{"type" => "conversation_ref"}),
    do: {:error, "inline Task conversation_ref.kind must be agent_task"}

  defp canonical_inline_task_ref(_block),
    do: {:error, "inline Task presentation requires type conversation_ref"}

  defp send_message(scope, params) do
    with :ok <-
           validate_param_keys(
             params,
             @send_message_params,
             "im_api.internal.send_message"
           ),
         {:ok, activation_provenance} <-
           SalixIM.SendTiming.measure("im_send_authorize", fn ->
             MeetingActivationAuthorization.provenance_for_tool_context(
               scope.group_id,
               SalixIM.Provider.current_tool_context()
             )
           end),
         {:ok, delivery_filter} <- validate_delivery_filter(params["delivery_filter"]),
         {:ok, mentions} <- validate_mentions(params["mentions"]) do
      case str(params["conversation_id"]) do
        "" ->
          {:error, "conversation_id is required"}

        "station:" <> _ = conversation_id ->
          say_station_task(scope, conversation_id, params)

        conversation_id ->
          case SalixIM.SendTiming.measure("im_send_conversation", fn ->
                 Conversations.get_group_conversation(scope.group_id, conversation_id)
               end) do
            {:ok, conversation} ->
              with {:ok, destination_provenance} <-
                     MeetingActivationAuthorization.provenance_for_conversation(conversation),
                   {:ok, effective_provenance} <-
                     MeetingActivationAuthorization.merge_provenance([
                       activation_provenance,
                       destination_provenance
                     ]),
                   {:ok, _inline_task_refs} <- validate_inline_task_refs(params["content"]) do
                internal_send(
                  scope,
                  conversation,
                  str(params["request_id"]),
                  params["content"],
                  effective_provenance,
                  delivery_filter,
                  mentions,
                  message_reply_target(params, conversation_id)
                )
              end

            {:error, :not_found} ->
              {:error, "conversation not found"}

            {:error, reason} ->
              {:error, control_error(reason)}
          end
      end
    end
  end

  # willow callInternalSendMessage → internalNativeSendMessageResult /
  # internalRoutedSendMessageToolResult (see @moduledoc for the
  # PersistedOutput / metadata divergence).
  defp internal_send(
         scope,
         conversation,
         request_id,
         content,
         activation_provenance,
         delivery_filter,
         mentions,
         {reply_field, reply_to_message_id}
       ) do
    conversation_id = conversation["conversation_id"]
    client_request_id = internal_send_client_request_id(scope, conversation_id, request_id)

    with {:ok, content} <- SalixIM.ConversationQuestion.normalize_agent_content(content),
         {:ok, content} <- SalixIM.MacAppItem.normalize_agent_content(content),
         {:ok, content} <- prepare_collaboration_send_files(scope, conversation, content),
         {:ok, content} <-
           SalixIM.SendTiming.measure("im_send_attachments", fn ->
             ConversationAttachments.bind_sender_files(scope.agent_id, content)
           end) do
      attrs =
        %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => scope.agent_id,
          "content" => content
        }
        |> put_present("client_request_id", client_request_id)
        |> put_present(reply_field, reply_to_message_id)
        |> then(fn attrs ->
          SalixIM.SendTiming.measure("im_send_participant", fn ->
            put_current_conversation_participant(attrs, conversation_id, scope)
          end)
        end)
        |> put_activation_provenance_metadata(activation_provenance)
        |> put_requester_timezone()
        |> put_local_account_binding(content)
        |> put_delivery_filter(delivery_filter)
        |> put_mentions(mentions)
        |> put_task_request(conversation, reply_to_message_id)
        |> put_egress_archive_broker()

      SalixIM.ConversationServer.append_group_conversation_agent_message(
        scope.group_id,
        conversation_id,
        scope.agent_id,
        attrs
      )
    end
    |> case do
      {:ok, %{"message_id" => message_id} = append_result} ->
        SalixIM.MentionReplyLatency.message_sent(message_id)

        base =
          %{
            "sent" => true,
            "conversation_id" => conversation_id,
            "message_id" => message_id,
            "inserted" => append_result["inserted"] == true,
            "delivery_status" => append_result["delivery_status"] || "recorded"
          }
          |> put_egress_archive_reservation(append_result)

        cond do
          str(conversation["kind"]) in ["", "user_chat"] ->
            {:ok, base}

          true ->
            {:ok,
             SalixIM.SendTiming.measure("im_send_result", fn ->
               best_effort_routed_send_result(scope, conversation_id, message_id, base)
               |> put_terminal_task_notice(scope, conversation)
             end)}
        end

      {:error, reason} ->
        {:error, control_error(reason)}
    end
  end

  # Use the conversation already read for this send. This is advice, not a
  # lifecycle transition, and must not affect human ingress or Worker replies.
  defp put_terminal_task_notice(
         result,
         %{agent: %{"role" => "router"}} = scope,
         %{"kind" => "agent_task", "status" => status, "conversation_id" => conversation_id}
       )
       when status in ~w(canceled cancelled completed failed terminal) do
    message =
      case SalixIM.TaskLoop.get(scope.group_id, conversation_id) do
        {:ok, %{"trigger" => %{}, "status" => "ended"} = view} ->
          reason = view["ended_reason"] || status

          "This Loop Task is ended (status=#{status}) and its Background Loop ended (#{reason}). " <>
            "Sending this message does not reopen it or restart its Loop. " <>
            "To resume automated runs after a user request, use im_api.internal.task.update with loop and command " <>
            "(it sets the Task active and creates a new Loop). " <>
            "Use im_api.internal.update_conversation with status=active only for one-off follow-up work without automation. " <>
            "If this message only adds information, ignore this notice."

        _other ->
          "This task is cancelled or ended (status=#{status}). Sending this message does not reopen it. " <>
            "If you intend to continue execution, explicitly reopen the task. " <>
            "Use im_api.internal.update_conversation with status=active. " <>
            "If this message only adds information, ignore this notice."
      end

    Map.put(result, "task_status_notice", %{
      "status" => status,
      "message" => message
    })
  end

  defp put_terminal_task_notice(result, _scope, _conversation), do: result

  defp put_activation_provenance_metadata(
         attrs,
         %{"meeting_activation_refs" => refs}
       )
       when is_list(refs) and refs != [],
       do: put_message_metadata(attrs, "meeting_activation_refs", refs)

  defp put_activation_provenance_metadata(attrs, _provenance), do: attrs

  # The timezone of the human request this turn serves, from the delivery that
  # woke the Agent. A reused Task then gets the current requester's timezone.
  # A display hint, never authority; Agent parameters cannot set it.
  defp put_requester_timezone(attrs) do
    with origin when is_map(origin) <-
           context_value(SalixIM.Provider.current_tool_context(), "trusted_origin"),
         zone when zone != "" <- str(stringify_value(origin)["source_timezone"]) do
      put_message_metadata(attrs, "requester_timezone", zone)
    else
      _other -> attrs
    end
  end

  # The computer and runtime a server-written local-account question card asks
  # about (`SalixWeb.LocalAccountChoice`). Only server code puts it in the
  # tool context; an Agent's parameters cannot. The owner's answer to this
  # card allows exactly that computer and runtime, nothing else.
  defp put_local_account_binding(attrs, content) do
    with %{"device_id" => device, "runtime" => runtime}
         when is_binary(device) and is_binary(runtime) <-
           context_value(SalixIM.Provider.current_tool_context(), "local_account_binding"),
         %{} <- SalixIM.ConversationQuestion.question_block(content) do
      put_message_metadata(attrs, "local_account", %{"device_id" => device, "runtime" => runtime})
    else
      _other -> attrs
    end
  end

  # A Message that hands a Task a request made elsewhere, such as a person's
  # Message in Home: the delivery that woke the Agent came from no Message of
  # this Task, it replies to nothing, and it reaches the Task's Participants.
  # The Task's Activity starts a group at it. A Message without a waking
  # delivery (a timer, the Agent's own follow-up) hands in nothing.
  defp put_task_request(
         %{"content" => content} = attrs,
         %{"kind" => "agent_task", "conversation_id" => conversation_id},
         nil
       )
       when is_list(content) do
    sources = tool_context_source_message_ids(SalixIM.Provider.current_tool_context())

    handed_in? =
      sources != [] and
        Enum.all?(
          sources,
          &match?({:error, _}, SalixIM.ConversationSourceIdentity.message_id(&1, conversation_id))
        ) and
        attrs["delivery_filter"] != %{"participant_ids" => []} and
        not Enum.all?(content, &match?(%{"type" => "milestone"}, &1))

    if handed_in?, do: put_message_metadata(attrs, "task_request", true), else: attrs
  end

  defp put_task_request(attrs, _conversation, _reply_to_message_id), do: attrs

  defp put_delivery_filter(attrs, nil), do: attrs
  defp put_delivery_filter(attrs, filter), do: Map.put(attrs, "delivery_filter", filter)
  defp put_mentions(attrs, nil), do: attrs
  defp put_mentions(attrs, mentions), do: Map.put(attrs, "mentions", mentions)

  defp put_egress_archive_broker(attrs) do
    case SalixIM.Provider.current_tool_context()[@egress_archive_broker_key] do
      {pid, token} = broker
      when SystemsRuntime.Proc.is_process(pid) and SystemsRuntime.Proc.is_ref(token) ->
        Map.put(attrs, @egress_archive_broker_key, broker)

      _missing ->
        attrs
    end
  end

  defp message_reply_target(params, conversation_id) do
    case Map.fetch(params, "reply_to_message_id") do
      {:ok, target} ->
        {"reply_to_message_id", target}

      :error ->
        context = SalixIM.Provider.current_tool_context()

        source =
          context_value(context, "source_message_id") ||
            List.last(tool_context_source_message_ids(context))

        target =
          case SalixIM.ConversationSourceIdentity.message_id(source, conversation_id) do
            {:ok, message_id} -> message_id
            {:error, :invalid_source_identity} -> nil
          end

        {:default_reply_to_message_id, target}
    end
  end

  defp put_egress_archive_reservation(result, append_result) do
    case append_result[@egress_archive_reservation_key] do
      nil -> result
      reservation -> Map.put(result, @egress_archive_reservation_key, reservation)
    end
  end

  defp validate_delivery_filter(nil), do: {:ok, nil}

  defp validate_delivery_filter(%{"participant_ids" => participant_ids})
       when is_list(participant_ids) and length(participant_ids) <= @delivery_filter_limit do
    if Enum.all?(participant_ids, &is_binary/1),
      do: {:ok, %{"participant_ids" => participant_ids}},
      else: {:error, "delivery_filter.participant_ids must be an array of participant IDs"}
  end

  defp validate_delivery_filter(_other),
    do: {:error, "delivery_filter.participant_ids must be an array of participant IDs"}

  defp validate_mentions(nil), do: {:ok, nil}

  defp validate_mentions(%{"participant_ids" => participant_ids})
       when is_list(participant_ids) and length(participant_ids) <= @delivery_filter_limit do
    if Enum.all?(participant_ids, &is_binary/1),
      do: {:ok, %{"participant_ids" => participant_ids}},
      else: {:error, "mentions.participant_ids must be an array of participant IDs"}
  end

  defp validate_mentions(_other),
    do: {:error, "mentions.participant_ids must be an array of participant IDs"}

  defp put_current_conversation_participant(attrs, conversation_id, scope) do
    participant_ids =
      SalixIM.Provider.current_tool_context()
      |> tool_context_source_message_ids()
      |> Enum.flat_map(fn source_message_id ->
        case group_conversation_source_identity(source_message_id, conversation_id) do
          {_message_id, participant_id} -> [participant_id]
          nil -> []
        end
      end)
      |> Enum.uniq()

    participant_id =
      case participant_ids do
        [participant_id] -> participant_id
        [] -> current_tool_session_participant_id(scope, conversation_id)
        _ -> nil
      end

    if is_binary(participant_id),
      do: Map.put(attrs, "participant_id", participant_id),
      else: attrs
  end

  defp current_tool_session_participant_id(scope, conversation_id) do
    case list_conversation_participants(scope.group_id, conversation_id, []) do
      {:ok, participants} ->
        case current_agent_participant(participants, scope.agent_id) do
          %{"participant_id" => participant_id} -> participant_id
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  # The Group conversation whose message woke this turn: the chat then offers
  # the confirmation in place. A turn without a decodable source (a schedule,
  # an external wake) files the proposal for Settings › Labels alone.
  defp proposal_source_conversation_id(group_id, tool_context) do
    tool_context
    |> tool_context_source_message_ids()
    |> Enum.find_value(fn source_message_id ->
      with {:ok, conversation_id} <-
             SalixIM.ConversationSourceIdentity.conversation_id(source_message_id),
           {:ok, _conversation} <-
             SalixIM.Conversations.get_group_conversation(group_id, conversation_id) do
        conversation_id
      else
        _ -> nil
      end
    end)
  end

  defp tool_context_source_message_ids(tool_context) do
    source_message_ids =
      case Map.get(tool_context, "source_message_ids") do
        message_ids when is_list(message_ids) -> message_ids
        _missing -> []
      end

    (source_message_ids ++ [Map.get(tool_context, "source_message_id")])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp group_conversation_source_identity(source_message_id, conversation_id) do
    case SalixIM.ConversationSourceIdentity.decode(source_message_id, conversation_id) do
      {:ok, %{message_id: message_id, participant_id: participant_id}} ->
        {message_id, participant_id}

      {:error, :invalid_source_identity} ->
        nil
    end
  end

  defp put_message_metadata(attrs, key, value) do
    metadata = Map.get(attrs, "metadata", %{})
    Map.put(attrs, "metadata", Map.put(metadata, key, value))
  end

  defp internal_send_client_request_id(scope, conversation_id, idempotency_key) do
    cond do
      presence(idempotency_key) != nil ->
        namespaced_message_id(scope, conversation_id, "request", idempotency_key)

      presence(scope[:tool_call_id]) != nil ->
        namespaced_message_id(scope, conversation_id, "tool", scope[:tool_call_id])

      true ->
        nil
    end
  end

  defp namespaced_message_id(scope, conversation_id, source, value) do
    material =
      [
        "internal.send_message",
        source,
        scope.group_id,
        conversation_id,
        scope.agent_id,
        value
      ]
      |> Enum.map(&str/1)
      |> Enum.join("\0")

    "internal-send-" <> short_hash(material)
  end

  defp short_hash(material) do
    :crypto.hash(:sha256, material)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 22)
  end

  # willow internalRoutedSendMessageToolResult; recipients derive from the
  # non-sender participants (Salix has no IM delivery rows — @moduledoc).
  defp routed_send_result(agent_id, participants, base, target_ids) do
    Map.merge(base, %{
      "recipients" => routed_recipients(agent_id, participants, target_ids),
      "peer_has_replied" => false,
      "peer_reply_state" => "pending",
      "recommended_next_action" =>
        "The message was routed asynchronously to the listed recipients. Later ordinary messages in this conversation will wake this session if they require follow-up."
    })
  end

  defp best_effort_routed_send_result(scope, conversation_id, message_id, base) do
    with {:ok, participants} <-
           list_conversation_participants(scope.group_id, conversation_id, []),
         {:ok, target_ids} <-
           routed_target_ids(scope.group_id, conversation_id, message_id) do
      routed_send_result(scope.agent_id, participants, base, target_ids)
    else
      {:error, _reason} -> routed_send_result(scope.agent_id, [], base, [])
    end
  end

  defp routed_recipients(agent_id, participants, target_ids) do
    participants
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> maybe_filter_recipient_ids(target_ids)
    |> Enum.reject(fn p ->
      participant_agent?(p) and str(p["agent_id"]) == agent_id
    end)
    |> Enum.map(fn p ->
      %{"participant_id" => p["participant_id"]}
      |> put_present("agent_id", p["agent_id"])
      |> put_present("agent_name", p["agent_name"])
      |> put_present("role_label", p["role_label"])
    end)
  end

  defp maybe_filter_recipient_ids(participants, nil), do: participants

  defp maybe_filter_recipient_ids(participants, target_ids) do
    target_ids = MapSet.new(target_ids)
    Enum.filter(participants, &MapSet.member?(target_ids, &1["participant_id"]))
  end

  defp routed_target_ids(group_id, conversation_id, message_id) do
    with {:ok, message} <-
           Conversations.get_group_conversation_message(group_id, conversation_id, message_id) do
      case get_in(message, ["delivery_filter", "participant_ids"]) do
        nil -> {:ok, nil}
        participant_ids when is_list(participant_ids) -> {:ok, participant_ids}
        _ -> {:error, "persisted delivery filter is invalid"}
      end
    else
      {:error, reason} -> {:error, control_error(reason)}
    end
  end

  defp participant_agent?(participant), do: participant["actor_type"] == "agent"

  defp task_report_for_delegator?(conversation_kind, current),
    do:
      str(conversation_kind) == "agent_task" and is_map(current) and
        str(current["role_label"]) == "delegator"
end
