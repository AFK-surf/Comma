defmodule SalixWeb.Migrations.CloudVMCutover do
  @moduledoc """
  The Cloud VM cutover (docs/agent-runtime.md, "Cloud VM cutover"): in the
  release that retires every Group's Cloud VM, what still names it is changed
  once, and the Cloudflare VMs are stopped.

  It runs after the core rollout, from the release's post-rollout job
  (`Comma.Release.transfer_agent_configuration_page/1`), and only where the
  deployment retires the Cloud VM (`SalixAgent.Sandboxes.cloud_vm_retired?/1`
  for no Group: `SALIX_CLOUD_VM_RETIRED` on). Elsewhere
  it does nothing and records nothing, so it runs in the first release that
  turns the switch on. Its stages, in order, a page of at most 100 records at
  a time:

    * `groups`: each Group record gets `cloud_vm_retired`, so the Group stays
      retired when the deployment switch is removed later; a default place
      `{kind: cloud_vm}` becomes `{kind: sandbox}` (`SalixAgent.TaskPlace`).
    * `workers`: each Worker bound to its Group's Cloud VM is bound to a
      sandbox of each Task's own, its model kept
      (`SalixAgent.AgentControl.rebind_cloud_vm/2`).
    * `tasks`: each Task the Group's Cloud VM station takes part in
      (`SalixStore.StationTaskSessions`) that is still open gets one notice
      from its Worker, and is closed: `ready_for_review` as `completed`, any
      other open status (`active`, `escalated`, `failed`) as `cancelled`; its
      Messages and Sessions stay. Then that station alone leaves the Task,
      closed before or now, so no Message wakes the VM for it; other stations
      stay. A page closes at most 100 Tasks, and a Group with more goes on in
      the next page after its last Task.
    * `workloads`: each Cloudflare Group Workload that is not archived is asked
      to stop (`SalixStore.Compute.request_group_stop/1`). The Compute
      reconciler of every node then archives a running VM, releases one with
      no container, and retires the Workload
      (`SalixWeb.ComputeProviders.Cloudflare.teardown/2`).

  A Group whose VM is on an Agent VMM Host (its Group Workload's provider,
  `SalixStore.ComputeGroupStation.group_vm_on_vmm_host/1`) keeps that VM:
  the Host is the Group's own hardware. Its default place and its Workers'
  bindings name the VM as the station it is, `{kind: station, device_id}` with
  the VM's device id (`SalixStore.ComputeGroupStation.vmm_group_vm?/2`); its
  Tasks go on there, and its Agent VMM Workload is not stopped. After the
  cutover no binding or default place names `{kind: cloud_vm}`. A Group with a
  Host registered whose Group VM is on Cloudflare, or that has none, is
  changed like any other.

  The marker `cloud_vm_cutover_v1` in `salix_cutover_markers` records the
  stage and cursor of the next page (`SalixStore.CutoverMarkers.page/2`): a
  run cut off resumes there, and once the last page is done, running it again
  does nothing. Each change is conditional on the record it read, and a record
  already changed is left as it is, so a page run again changes nothing. A
  page that cannot read its records fails and leaves the marker, and the
  release runs it again. A record whose change fails is logged, left as it
  was and counted (`failed` in the marker), and the page goes on: what it
  still names is refused all the same, and `run/1` tries it again.
  """

  require Logger

  alias SalixAgent.{AgentControl, Sandboxes, TaskPlace}

  alias SalixStore.{
    AgentPGStore,
    CasRecord,
    Compute,
    ComputeGroupStation,
    CutoverMarkers,
    Ids,
    Keys,
    RuntimeIds,
    S3,
    StationTaskSessions
  }

  @marker "cloud_vm_cutover_v1"
  @page 100
  @stages ~w(groups workers tasks workloads)
  # An open Task and the status it is closed with (`SalixIM.ConversationActor`:
  # `escalated` and `failed` have not ended).
  @closed %{
    "active" => "cancelled",
    "escalated" => "cancelled",
    "failed" => "cancelled",
    "ready_for_review" => "completed"
  }

  @doc """
  One page of the cutover after the rollout, where the deployment retires
  the Cloud VM; elsewhere none. Answers `{:ok, %{processed: n, done: boolean}}`.
  """
  def after_rollout_page do
    if Sandboxes.cloud_vm_retired?(nil),
      do: CutoverMarkers.page(@marker, &page/1),
      else: {:ok, %{processed: 0, done: true}}
  end

  @doc """
  Every page from the start, without the marker: how many records each stage
  changed, and how many it left as they were (`failed`). `tenant:` keeps it
  to one Tenant; `page:` takes fewer than 100 records a page.
  """
  def run(opts \\ []), do: run(nil, opts, Map.new(["failed" | @stages], &{&1, 0}))

  defp run(position, opts, counts) do
    stage = if position, do: position["stage"], else: hd(@stages)

    with {:ok, %{processed: processed, failed: failed, next: next}} <- page(position, opts) do
      counts =
        counts |> Map.update!(stage, &(&1 + processed)) |> Map.update!("failed", &(&1 + failed))

      if next, do: run(next, opts, counts), else: {:ok, counts}
    end
  end

  @doc """
  One page at `position` (nil: the first): `{:ok, %{processed: n, failed: n,
  next: position}}`, where processed is how many records it changed, failed
  how many it left as they were, and a next position of nil means the cutover
  is done. `tenant:` keeps it to one Tenant; `page:` takes fewer records.
  """
  def page(position, opts \\ [])

  def page(nil, opts), do: page(%{"stage" => hd(@stages), "cursor" => nil}, opts)

  def page(%{"stage" => stage, "cursor" => cursor}, opts) when stage in @stages do
    with {:ok, changed, failed, next_cursor} <- stage_page(stage, cursor, opts) do
      next =
        cond do
          next_cursor -> %{"stage" => stage, "cursor" => next_cursor}
          next_stage(stage) -> %{"stage" => next_stage(stage), "cursor" => nil}
          true -> nil
        end

      {:ok, %{processed: changed, failed: failed, next: next}}
    end
  end

  def page(position, _opts), do: {:error, {:unknown_position, position}}

  defp next_stage(stage) do
    case Enum.drop_while(@stages, &(&1 != stage)) do
      [_stage, next | _] -> next
      _last -> nil
    end
  end

  defp size(opts), do: min(opts[:page] || @page, @page)

  defp stage_page("groups", cursor, opts) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(groups_prefix(opts), max_keys: size(opts), continuation_token: cursor) do
      {changed, failed} =
        count(Enum.flat_map(objects, &group_id/1), "Group", & &1, &retire_group/1)

      {:ok, changed, failed, next}
    end
  end

  defp stage_page("workers", cursor, opts) do
    scope = if opts[:tenant], do: %{tenant_id: opts[:tenant]}, else: %{}

    with {:ok, %{items: agents, next: next}} <-
           AgentPGStore.page_configs(scope, limit: size(opts), cursor: cursor) do
      {changed, failed} =
        count(Enum.filter(agents, &cloud_vm_worker?/1), "Worker", & &1["agent_id"], &rebind/1)

      {:ok, changed, failed, next}
    end
  end

  # The cursor is the key of a Group record, with the last Task read in it
  # when the page ran out of room there (`after`).
  defp stage_page("tasks", cursor, opts) do
    tally = %{changed: 0, failed: 0, room: size(opts)}

    case cursor do
      %{"key" => key, "after" => last} when is_binary(last) ->
        case group_tasks(key, last, tally) do
          {:done, tally} -> tasks_after(key, tally, opts)
          other -> tasks_page(other)
        end

      %{"key" => key} ->
        tasks_after(key, tally, opts)

      nil ->
        tasks_after(nil, tally, opts)
    end
  end

  defp stage_page("workloads", cursor, opts) do
    with {:ok, %{records: records, next_cursor: next}} <-
           Compute.page_group_workloads(
             limit: size(opts),
             cursor: cursor,
             tenant_id: opts[:tenant]
           ) do
      {changed, failed} =
        count(Enum.filter(records, &running?/1), "Workload", & &1["group_id"], &stop/1)

      {:ok, changed, failed, next}
    end
  end

  defp groups_prefix(opts) do
    if opts[:tenant],
      do: Keys.ctl_groups_prefix_for_tenant(opts[:tenant]),
      else: Keys.ctl_groups_prefix()
  end

  defp group_id(%{key: key}) do
    with "ctl/groups/" <> name <- key,
         group_id = String.replace_suffix(name, ".json", ""),
         true <- group_id != name and Ids.valid_group_id?(group_id) do
      [group_id]
    else
      _ -> []
    end
  end

  # `fun` answers `{:ok, changed?}` for one item. An item that fails, or
  # raises, is logged and counted, and the others go on. Answers
  # `{changed, failed}`.
  defp count(items, what, id, fun) do
    Enum.reduce(items, {0, 0}, fn item, {changed, failed} ->
      case attempt(fun, item) do
        {:ok, true} ->
          {changed + 1, failed}

        {:ok, false} ->
          {changed, failed}

        {:error, reason} ->
          Logger.warning(
            "the Cloud VM cutover left a #{what} as it was: #{id.(item)} #{inspect(reason)}"
          )

          {changed, failed + 1}
      end
    end)
  end

  defp attempt(fun, item) do
    fun.(item)
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # The default is decided on the record the update writes: a Group whose VM
  # is on its Agent VMM Host keeps a Cloud VM default.
  defp retire_group(group_id) do
    key = Keys.ctl_group(group_id)

    retired = fn group ->
      with {:ok, next} <- retire_default(group_id, Map.put(group, Sandboxes.field(), true)) do
        if next == group, do: {:unchanged, group}, else: next
      end
    end

    with {:ok, group} <- CasRecord.get(key),
         %{} <- retired.(group),
         {:ok, _group} <- CasRecord.update(key, retired, create: false) do
      {:ok, true}
    else
      {:unchanged, _group} -> {:ok, false}
      {:error, :not_found} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  defp retire_default(group_id, group) do
    if TaskPlace.of_group(group) == TaskPlace.cloud_vm() do
      with {:ok, place} <- place_instead(group_id),
           do: {:ok, TaskPlace.retire_cloud_vm(group, place)}
    else
      {:ok, group}
    end
  end

  # What takes the place of `{kind: cloud_vm}`: the Group VM's station on its
  # Agent VMM Host, else a sandbox of each Task's own.
  defp place_instead(group_id) do
    with {:ok, on_host?} <- ComputeGroupStation.group_vm_on_vmm_host(group_id) do
      {:ok,
       if(on_host?,
         do: %{"kind" => "station", "device_id" => RuntimeIds.cloud_vm_device_id(group_id)},
         else: TaskPlace.sandbox()
       )}
    end
  end

  defp cloud_vm_worker?(agent),
    do:
      agent["role"] == "worker" and agent["permanent_archive"] != true and
        match?(%{"runs_on" => %{"kind" => "cloud_vm"}}, agent["station_binding"])

  defp rebind(agent) do
    with {:ok, runs_on} <- place_instead(agent["group_id"]) do
      case AgentControl.rebind_cloud_vm(agent["agent_id"], runs_on) do
        {:ok, %{"station_binding" => %{"runs_on" => ^runs_on}}} -> {:ok, true}
        {:ok, _bound_elsewhere} -> {:ok, false}
        {:error, :not_found} -> {:ok, false}
        {:error, :agent_permanently_archived} -> {:ok, false}
        error -> error
      end
    end
  end

  # The Groups after the record at `start` (nil: from the first), while the
  # page has room for Tasks.
  defp tasks_after(start, tally, opts) do
    list = [max_keys: size(opts)] ++ if(start, do: [start_after: start], else: [])

    with {:ok, %{objects: objects, next: more}} <- S3.list(groups_prefix(opts), list) do
      objects
      |> Enum.reduce_while({:done, tally}, fn %{key: key}, {:done, tally} ->
        case group_tasks(key, nil, tally) do
          {:done, _tally} = done -> {:cont, done}
          other -> {:halt, other}
        end
      end)
      |> case do
        {:done, tally} when is_binary(more) and objects != [] ->
          {:ok, tally.changed, tally.failed, %{"key" => List.last(objects).key, "after" => nil}}

        other ->
          tasks_page(other)
      end
    end
  end

  defp tasks_page({:done, tally}), do: {:ok, tally.changed, tally.failed, nil}
  defp tasks_page({:full, tally, cursor}), do: {:ok, tally.changed, tally.failed, cursor}
  defp tasks_page({:error, _} = error), do: error

  # The Tasks of the Cloud VM station of the Group at `key`, after Task `last`
  # (nil: from the first), as many as the page has room for: `{:full, tally,
  # cursor}` when that took the rest of its room. A Group whose Workload
  # cannot be read is counted failed, its Tasks left.
  defp group_tasks(key, last, tally) do
    with [group_id] <- group_id(%{key: key}),
         tenant = Ids.tenant_id_from_group!(group_id),
         device = RuntimeIds.cloud_vm_device_id(group_id),
         {:ok, [_ | _] = tasks} <-
           StationTaskSessions.tasks_of_device(tenant, group_id, device, last, tally.room),
         {:ok, false} <- on_host(group_id) do
      {changed, failed} =
        count(
          tasks,
          "Task",
          &"group=#{group_id} task=#{&1.conversation_id}",
          &close_task(group_id, device, &1)
        )

      tally = %{
        changed: tally.changed + changed,
        failed: tally.failed + failed,
        room: tally.room - length(tasks)
      }

      if tally.room == 0,
        do: {:full, tally, %{"key" => key, "after" => List.last(tasks).conversation_id}},
        else: {:done, tally}
    else
      {:error, :group_workload, reason} ->
        Logger.warning(
          "the Cloud VM cutover left a Group's Tasks as they were: #{key} #{inspect(reason)}"
        )

        {:done, %{tally | failed: tally.failed + 1}}

      {:error, _} = error ->
        error

      _none ->
        {:done, tally}
    end
  end

  defp on_host(group_id) do
    with {:error, reason} <- ComputeGroupStation.group_vm_on_vmm_host(group_id),
         do: {:error, :group_workload, reason}
  end

  # The notice first, the status next, and the station leaves last: a run cut
  # off before the end finds the Task again by its station, and the notice is
  # written once.
  defp close_task(group_id, device, %{conversation_id: conversation, agent_id: agent_id}) do
    with {:ok, closed?} <- close_open(group_id, conversation, agent_id),
         :ok <- StationTaskSessions.leave(group_id, conversation, device) do
      {:ok, closed?}
    end
  end

  defp close_open(group_id, conversation, agent_id) do
    case SalixIM.Conversations.get_group_conversation(group_id, conversation) do
      {:ok, %{"status" => status}} when is_map_key(@closed, status) ->
        closed = Map.fetch!(@closed, status)

        with :ok <- notify(group_id, conversation, agent_id, closed),
             {:ok, _task} <-
               SalixIM.ConversationServer.update_group_conversation(group_id, conversation, %{
                 "status" => closed
               }) do
          Logger.info(
            "the Cloud VM cutover closed a Task: group=#{group_id} task=#{conversation} status=#{closed}"
          )

          {:ok, true}
        end

      {:ok, _ended} ->
        {:ok, false}

      {:error, :not_found} ->
        {:ok, false}

      {:error, _} = error ->
        error
    end
  end

  # Written as the Task's Worker; a Worker no longer taking part writes none,
  # and the Task is closed all the same.
  defp notify(group_id, conversation, agent_id, closed) do
    case SalixWeb.StationTasks.notice(
           group_id,
           conversation,
           agent_id,
           "cloud_vm_retired",
           notice(closed),
           "cloud_vm_notice"
         ) do
      {:error, :not_taking_part} -> :ok
      {:error, _} = error -> error
      _appended -> :ok
    end
  end

  # The words of migration notice 66 (`SalixAgent.MigrationNotice`).
  defp notice(closed) do
    "The Group's Cloud VM, where this Task ran, is retired: sandboxes have taken its place, " <>
      "and Salix does not start the Cloud VM again. Salix closed this Task (#{closed}). Its " <>
      "Messages stay; files on the Cloud VM that were not pushed or saved to Drive are gone. " <>
      "To continue the work, create a new Task with runs_on {kind: sandbox}, with repo " <>
      "{owner, name} to work in a repository, or {kind: default}, and tell the requester. " <>
      "A schedule of this Task ends with it."
  end

  defp running?(record),
    do:
      record["provider"] == "cloudflare" and record["status"] != "archived" and
        record["desired_state"] != "stopped"

  defp stop(record) do
    with :ok <- Compute.request_group_stop(record["group_id"]) do
      Logger.info(
        "the Cloud VM cutover stopped a Cloud VM: group=#{record["group_id"]} status=#{record["status"]}"
      )

      {:ok, true}
    end
  end
end
