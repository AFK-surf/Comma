defmodule Comma.Notifications do
  @moduledoc "Auth Session-owned APNs addresses and bounded current-state delivery."
  import Ecto.Query
  alias Comma.{Accounts, Conversations, Repo, RouterNotifications, Workspaces}
  alias Comma.Notifications.{APNs, Target}

  @page 100
  @lease_seconds 120
  @device_statuses ~w(ready_for_review escalated completed failed)
  @attention ~w(ready_for_review escalated)
  @activity_schema "tasks_v1"
  @activity_seconds 8 * 60 * 60
  @wakeup_generations 3

  def register(user, session, kind, attrs) when kind in ~w(device live_activity push_to_start) do
    with :ok <- unrestricted(session),
         {:ok, bundle_id} <- APNs.registration_bundle(attrs["environment"], attrs["bundle_id"]),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, attrs["group_id"]),
         true <- workspace["id"] == attrs["workspace_id"],
         :ok <- authorize_activity(kind, attrs),
         {:ok, registration_id} <- registration_id(kind, attrs),
         {:ok, baseline} <- registration_baseline(user, session, kind, workspace) do
      previous =
        Repo.one(
          from(t in Target, where: t.auth_session_id == ^session["id"] and t.kind == ^kind)
        )

      started_at =
        cond do
          kind == "live_activity" -> activity_started_at(previous, attrs)
          kind == "push_to_start" and previous != nil -> previous.activity_started_at
          true -> nil
        end

      expiry =
        min(
          session["expires_at"],
          if(kind == "live_activity",
            do: DateTime.to_unix(started_at) + @activity_seconds,
            else: SystemsClock.system_time(:second) + lifetime(kind)
          )
        )

      values = %{
        auth_session_id: session["id"],
        kind: kind,
        token: attrs["token"],
        environment: attrs["environment"],
        bundle_id: bundle_id,
        locale: normalize_locale(attrs["locale"]),
        workspace_id: workspace["id"],
        group_id: workspace["default_group_id"],
        conversation_id: nil,
        activity_id: if(kind == "live_activity", do: attrs["activity_id"]),
        activity_schema: if(kind != "device", do: @activity_schema),
        activity_started_at: started_at,
        last_sent_version:
          accepted_activity_timestamp(kind, session["id"], previous, attrs, workspace),
        router_last_sent_seq: baseline["latest_seq"] || 0,
        expires_at: DateTime.from_unix!(expiry)
      }

      # This UUID identifies a recoverable registration attempt. Session/Group
      # admission and the unique Session/kind slot remain its authority.
      values = if registration_id, do: Map.put(values, :id, registration_id), else: values

      # Each Session owns one Group activity. Rotation retains delivery receipts
      # and known dismissal intent; a Workspace change establishes a new scope.
      reset_scope = previous == nil or previous.group_id != values.group_id

      extra =
        if reset_scope,
          do: [:recent_states, :suppressed_task_ids, :router_last_sent_seq],
          else: []

      reset_activity =
        reset_scope or previous.activity_schema != @activity_schema or
          (kind == "live_activity" and previous.activity_id != attrs["activity_id"])

      extra =
        if reset_activity,
          do:
            extra ++
              [
                :activity_content,
                :activity_start_pending_until,
                :last_sent_version,
                :last_sent_status
              ],
          else: extra

      case Repo.insert(Target.changeset(%Target{}, values),
             conflict_target: [:auth_session_id, :kind],
             on_conflict:
               {:replace,
                [
                  :id,
                  :token,
                  :environment,
                  :bundle_id,
                  :locale,
                  :workspace_id,
                  :group_id,
                  :conversation_id,
                  :activity_id,
                  :activity_schema,
                  :activity_started_at,
                  :router_last_sent_badge,
                  :expires_at,
                  :updated_at,
                  :delivery_lease_until
                ] ++ extra},
             returning: true
           ) do
        {:ok, target} ->
          if kind == "live_activity", do: acknowledge_activity(target)
          wake_listener(target.group_id)
          if kind == "device", do: enqueue_router_target(target.id), else: enqueue(target.id)
          {:ok, %{"id" => target.id, "status" => "active"}}

        {:error, _} ->
          {:error, :invalid_push_registration}
      end
    else
      false -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  def unregister(session, id, reason \\ nil) do
    with {:ok, id} <- Ecto.UUID.cast(id), :ok <- unrestricted(session) do
      # A foreground-created Activity can be dismissed before its first APNs
      # update records content. Read the bounded owner projection before locking
      # the registration, so that this dismissal still suppresses its cohort.
      dismissed_ids = dismissed_task_ids(session, id, reason)

      Repo.transaction(fn ->
        target =
          Repo.one(
            from(t in Target,
              where: t.id == ^id and t.auth_session_id == ^session["id"],
              lock: "FOR UPDATE"
            )
          )

        if target && target.kind == "live_activity" && target.activity_schema == @activity_schema do
          values = [activity_start_pending_until: nil]

          starts =
            from(t in Target,
              where:
                t.auth_session_id == ^session["id"] and t.group_id == ^target.group_id and
                  t.kind == "push_to_start"
            )

          started = Repo.one(starts)
          tasks = target.activity_content["tasks"] || []

          tasks =
            if tasks == [] and started != nil,
              do: started.activity_content["tasks"] || [],
              else: tasks

          values =
            if reason in ["dismissed", "stopped"],
              do:
                Keyword.put(
                  values,
                  :suppressed_task_ids,
                  dismissed_ids || Enum.map(tasks, & &1["id"])
                ),
              else: values

          Repo.update_all(starts, set: values)
        end

        Repo.delete_all(
          from(t in Target, where: t.id == ^id and t.auth_session_id == ^session["id"])
        )
      end)

      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp dismissed_task_ids(session, id, reason) when reason in ["dismissed", "stopped"] do
    target =
      Repo.one(from(t in Target, where: t.id == ^id and t.auth_session_id == ^session["id"]))

    with %Target{kind: "live_activity", activity_schema: @activity_schema} <- target,
         [] <- target.activity_content["tasks"] || [],
         started <-
           Repo.one(
             from(t in Target,
               where:
                 t.auth_session_id == ^session["id"] and t.group_id == ^target.group_id and
                   t.kind == "push_to_start"
             )
           ),
         [] <- if(started, do: started.activity_content["tasks"] || [], else: []),
         {:ok, user, current_session} <- authority(target),
         {:ok, %{"data" => tasks}} <-
           Conversations.activity_tasks(user, current_session, target.group_id) do
      Enum.map(tasks, & &1["id"])
    else
      _ -> nil
    end
  end

  defp dismissed_task_ids(_, _, _), do: nil

  # Legacy installations need not know the registration ID or guess a token.
  # Session authority, not a caller-selected identifier, owns this exact slot.
  def unregister_device(session) do
    with :ok <- unrestricted(session) do
      Repo.delete_all(
        from(t in Target, where: t.auth_session_id == ^session["id"] and t.kind == "device")
      )

      :ok
    end
  end

  def enqueue(id, conversation_id \\ nil) do
    insert_wakeup(Comma.Workers.NativePush, %{
      "target_id" => id,
      "conversation_id" => conversation_id,
      "mode" => if(conversation_id, do: "task", else: "activity")
    })
  end

  defp enqueue_router_target(id) do
    insert_wakeup(Comma.Workers.NativePush, %{
      "target_id" => id,
      "conversation_id" => nil,
      "mode" => "router"
    })
  end

  # Oban uniqueness also covers executing jobs, which may already have read the
  # canonical state this wakeup reports. Such a collision schedules a successor
  # generation that rereads it. Every job carries its generation, so a wakeup
  # never matches a job of another generation; losing one needs all
  # @wakeup_generations jobs for the same address to be executing at once.
  def insert_wakeup(worker, args, generation \\ 0) do
    args = Map.put(args, "successor", generation)
    opts = if generation > 0, do: [schedule_in: 1], else: []

    case Oban.insert(Comma.Oban, worker.new(args, opts)) do
      {:ok, %Oban.Job{conflict?: true, state: "executing"}}
      when generation + 1 < @wakeup_generations ->
        insert_wakeup(worker, args, generation + 1)

      result ->
        result
    end
  end

  def enqueue_router(group_id, cursor \\ nil), do: enqueue_group(group_id, "router", cursor)
  def enqueue_activity(group_id, cursor \\ nil), do: enqueue_group(group_id, "activity", cursor)

  defp enqueue_group(group_id, mode, cursor) do
    insert_wakeup(Comma.Workers.NativePushFanout, %{
      "group_id" => group_id,
      "conversation_id" => nil,
      "cursor" => cursor,
      "mode" => mode
    })
  end

  def enqueue_task(group_id, conversation_id, cursor \\ nil) do
    insert_wakeup(Comma.Workers.NativePushFanout, %{
      "group_id" => group_id,
      "conversation_id" => conversation_id,
      "cursor" => cursor,
      "mode" => "task"
    })
  end

  def targets_for_task(group_id, _conversation_id, cursor),
    do: targets_page(group_id, ["device"], cursor)

  def targets_for_router(group_id, cursor), do: targets_page(group_id, ["device"], cursor)

  def targets_for_activity(group_id, cursor),
    do: targets_page(group_id, ["live_activity", "push_to_start"], cursor)

  defp targets_page(group_id, kinds, cursor) do
    now = SystemsClock.utc_now()

    from(t in Target,
      where:
        t.group_id == ^group_id and t.expires_at > ^now and
          t.kind in ^kinds,
      order_by: [asc: t.id],
      limit: ^@page
    )
    |> after_id(cursor)
    |> Repo.all()
  end

  @doc """
  Live `device` addresses of these accounts for station notices, at most 20 per
  account. The station's Workspace membership is the caller's check; the
  address is the Auth Session's, wherever it was registered.
  """
  def station_notice_targets([]), do: []

  def station_notice_targets(user_ids) when is_list(user_ids) do
    now = SystemsClock.utc_now()

    from(t in Target,
      join: s in Accounts.AuthSession,
      on: s.id == t.auth_session_id,
      where:
        s.user_id in ^user_ids and t.kind == "device" and t.expires_at > ^now and
          is_nil(s.revoked_at) and s.expires_at > ^now and s.restricted == false,
      order_by: [asc: s.user_id, desc: t.updated_at],
      limit: ^(20 * length(user_ids)),
      select: {s.user_id, t}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.flat_map(fn {_user, rows} -> Enum.take(rows, 20) end)
  end

  @doc "Sends one station notice to an address after rechecking its Auth Session."
  def deliver_station_notice(%Target{kind: "device"} = target, payload) do
    with {:ok, _user, session} <- Accounts.resolve_session_id(target.auth_session_id),
         :ok <- unrestricted(session) do
      case APNs.send(target, payload) do
        {:error, :invalid_token} = error ->
          Repo.delete_all(
            from(t in Target, where: t.id == ^target.id and t.token == ^target.token)
          )

          error

        result ->
          result
      end
    end
  end

  def recovery_page(cursor) do
    now = SystemsClock.utc_now()

    from(t in Target, where: t.expires_at > ^now, order_by: [asc: t.id], limit: ^@page)
    |> after_id(cursor)
    |> Repo.all()
  end

  def deliver(target_id, conversation_id) do
    # A short lease, not a row lock held across owner reads and APNs, keeps
    # concurrent Pods from sending to one address without pinning a DB connection.
    with_lease(target_id, &deliver_leased(&1, conversation_id))
  end

  def deliver_router(target_id), do: with_lease(target_id, &deliver_router_leased/1)

  defp with_lease(target_id, fun) do
    case claim(target_id) do
      {:ok, target} ->
        try do
          fun.(target)
        after
          release(target)
        end

      error ->
        error
    end
  end

  defp claim(target_id) do
    now = SystemsClock.utc_now()

    from(t in Target,
      where:
        t.id == ^target_id and
          (is_nil(t.delivery_lease_until) or t.delivery_lease_until < ^now),
      select: t
    )
    |> Repo.update_all(set: [delivery_lease_until: DateTime.add(now, @lease_seconds)])
    |> case do
      {1, [target]} ->
        {:ok, target}

      {0, _} ->
        if Repo.exists?(from(t in Target, where: t.id == ^target_id)),
          do: {:error, :delivery_busy},
          else: :obsolete
    end
  end

  defp release(target), do: leased(target) |> Repo.update_all(set: [delivery_lease_until: nil])

  # Rotation replaces the row ID and clears the lease; an older lease then
  # writes nothing to the replacement address.
  defp leased(target),
    do:
      from(t in Target,
        where: t.id == ^target.id and t.delivery_lease_until == ^target.delivery_lease_until
      )

  defp deliver_leased(%{kind: "device"} = target, task_id) do
    with {:ok, user, session} <- authority(target) do
      deliver_task(target, user, session, task_id)
    else
      error -> delivery_error(target, error)
    end
  end

  defp deliver_leased(target, _requested_task) do
    # Keep historical credentials without sending a new payload to an old
    # ActivityKit decoder. New registration explicitly admits tasks_v1.
    if target.activity_schema != @activity_schema do
      :current
    else
      with {:ok, user, session} <- authority(target),
           {:ok, %{"data" => tasks}} <-
             Conversations.activity_tasks(user, session, target.group_id) do
        content = activity_content(tasks)

        if target.kind == "push_to_start",
          do: maybe_start(target, user, content),
          else: update_activity(target, content)
      else
        error -> delivery_error(target, error)
      end
    end
  end

  defp deliver_task(target, user, session, task_id) do
    with {:ok, task} <- Conversations.preview(user, session, target.group_id, task_id),
         version when is_integer(version) and version > 0 <- task["updated_at"] do
      cond do
        get_in(target.recent_states, [task_id, "status"]) == task["status"] ->
          :current

        task["status"] not in @device_statuses ->
          remember_state(target, task)
          :current

        true ->
          push(target, task, version)
      end
    else
      {:error, :not_found} ->
        # A missing Task cannot retire a Session-owned delivery address. Preview
        # also checks Group ownership, so recheck authority before preserving it.
        case authority(target) do
          {:ok, _, _} -> :current
          error -> delivery_error(target, error)
        end

      error ->
        delivery_error(target, error)
    end
  end

  defp deliver_router_leased(%{kind: "device"} = target) do
    with {:ok, user, session} <- authority(target),
         {:ok, router} <- RouterNotifications.snapshot(user, session, target.group_id) do
      latest = router["latest_seq"] || 0
      badge = router["unread_count"] || 0

      alert? =
        latest > target.router_last_sent_seq and badge > 0 and
          is_binary(router["latest_message_id"])

      if alert? or target.router_last_sent_badge != badge do
        with :ok <- send_authorized(target, router_payload(target, router, alert?)) do
          Repo.update_all(leased(target),
            set: [
              router_last_sent_seq: max(latest, target.router_last_sent_seq),
              router_last_sent_badge: badge
            ]
          )

          :delivered
        else
          error -> delivery_error(target, error)
        end
      else
        :current
      end
    else
      error -> delivery_error(target, error)
    end
  end

  defp deliver_router_leased(_target), do: :current

  defp push(target, task, version) do
    with {:ok, user, session} <- authority(target),
         badge = task_alert_badge(target, user, session),
         :ok <- send_authorized(target, alert_payload(target, task, badge)) do
      Repo.update_all(leased(target),
        set: [
          last_sent_version: version,
          last_sent_status: task["status"],
          router_last_sent_badge: badge,
          updated_at: SystemsClock.timestamp(:utc_datetime_usec)
        ]
      )

      remember_state(target, task)
      :delivered
    else
      error -> delivery_error(target, error)
    end
  end

  # The badge is best effort: a pending or unavailable Router projection keeps
  # the last delivered badge, or omits it, and never blocks a Task alert.
  defp task_alert_badge(target, user, session) do
    case RouterNotifications.snapshot(user, session, target.group_id) do
      {:ok, router} -> router["unread_count"] || 0
      {:error, _} -> target.router_last_sent_badge
    end
  end

  defp update_activity(target, content) do
    cond do
      content["tasks"] == [] ->
        with {:ok, now} <- next_activity_timestamp(target),
             :ok <- send_authorized(target, activity_payload(content, "end", now)) do
          remove(target)
        else
          error -> delivery_error(target, error)
        end

      target.activity_content == content ->
        :current

      true ->
        with {:ok, now} <- next_activity_timestamp(target),
             :ok <- send_authorized(target, activity_payload(content, "update", now)) do
          Repo.update_all(leased(target),
            set: [
              activity_content: content,
              last_sent_version: now,
              updated_at: SystemsClock.timestamp(:utc_datetime_usec)
            ]
          )

          :delivered
        else
          error -> delivery_error(target, error)
        end
    end
  end

  def activity_content(tasks) do
    tasks =
      Enum.take(tasks, 2)
      |> Enum.map(fn task ->
        %{
          "id" => task["id"],
          "title" => String.slice(task["title"] || "Task", 0, 160),
          "status" => task["status"],
          "updatedAtEpochSeconds" => div(task["updated_at"] || 0, 1_000)
        }
      end)

    %{
      "tasks" => tasks,
      "updatedAtEpochSeconds" => Enum.reduce(tasks, 0, &max(&1["updatedAtEpochSeconds"], &2))
    }
  end

  def activity_payload(content, event, now \\ SystemsClock.system_time(:second)) do
    aps = %{
      "timestamp" => now,
      "event" => event,
      "content-state" => content,
      "stale-date" => now + 120
    }

    aps = if event == "end", do: Map.put(aps, "dismissal-date", now), else: aps
    %{"aps" => aps}
  end

  defp maybe_start(target, user, content) do
    current = current_activity(target)
    ids = Enum.map(content["tasks"], & &1["id"])

    cond do
      ids == [] ->
        Repo.update_all(leased(target),
          set: [
            suppressed_task_ids: [],
            activity_content: content,
            activity_start_pending_until: nil
          ]
        )

        if current, do: enqueue(current.id)
        :current

      current != nil ->
        enqueue(current.id)
        :current

      MapSet.new(ids) == MapSet.new(target.suppressed_task_ids) ->
        :current

      future?(target.activity_start_pending_until) ->
        :current

      true ->
        with {:ok, timestamp} <- next_activity_timestamp(target) do
          now = SystemsClock.utc_now()

          aps =
            activity_payload(content, "start", timestamp)["aps"]
            |> Map.merge(%{
              "attributes-type" => "TaskActivityAttributes",
              "attributes" => %{
                "accountID" => user["id"],
                "workspaceID" => target.workspace_id,
                "groupID" => target.group_id
              },
              "input-push-token" => 1,
              "alert" => %{"title" => "Comma", "body" => activity_start_label(target.locale)}
            })

          with :ok <- send_authorized(target, %{"aps" => aps}) do
            # APNs accepted the start, so the device may already show it. Without its
            # token this server cannot update or end that Activity; another start would
            # stack a second one. Its registration, an empty Group or its lifetime clears this.
            Repo.update_all(leased(target),
              set: [
                activity_content: content,
                last_sent_version: timestamp,
                activity_started_at: now,
                activity_start_pending_until: DateTime.add(now, @activity_seconds),
                suppressed_task_ids: []
              ]
            )

            :delivered
          else
            error -> delivery_error(target, error)
          end
        end
    end
  end

  defp current_activity(target) do
    now = SystemsClock.utc_now()
    cutoff = DateTime.add(now, -@activity_seconds)

    Repo.one(
      from(t in Target,
        where:
          t.auth_session_id == ^target.auth_session_id and t.group_id == ^target.group_id and
            t.kind == "live_activity" and t.activity_schema == ^@activity_schema and
            t.expires_at > ^now and t.activity_started_at > ^cutoff
      )
    )
  end

  defp acknowledge_activity(target) do
    query =
      from(t in Target,
        where:
          t.auth_session_id == ^target.auth_session_id and t.group_id == ^target.group_id and
            t.kind == "push_to_start" and t.activity_schema == ^@activity_schema
      )

    Repo.update_all(query,
      set: [activity_started_at: target.activity_started_at, activity_start_pending_until: nil]
    )
  end

  defp next_activity_timestamp(target) do
    now = SystemsClock.system_time(:second)

    minimum =
      if target.kind == "live_activity" && target.activity_started_at,
        do: max(target.last_sent_version, DateTime.to_unix(target.activity_started_at)),
        else: target.last_sent_version

    # Token registration may beat the push-to-start HTTP response. Waiting past
    # this registration second also orders its first update after that start.
    if minimum < now,
      do: {:ok, now},
      else: {:error, :activity_update_busy}
  end

  defp future?(nil), do: false
  defp future?(date), do: DateTime.compare(date, SystemsClock.utc_now()) == :gt

  defp authority(target) do
    with true <- DateTime.compare(target.expires_at, SystemsClock.utc_now()) == :gt,
         {:ok, user, session} <- Accounts.resolve_session_id(target.auth_session_id),
         :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, target.group_id),
         true <- workspace["id"] == target.workspace_id do
      {:ok, user, session}
    else
      false -> {:error, :target_revoked}
      error -> error
    end
  end

  defp delivery_error(target, {:error, reason})
       when reason in [
              :not_found,
              :forbidden,
              :revoked,
              :expired,
              :disabled,
              :invalid_token,
              :target_revoked
            ],
       do: remove(target)

  defp delivery_error(_target, {:error, _} = error), do: error
  defp delivery_error(_target, _), do: {:error, :invalid_task_projection}

  defp send_authorized(target, payload) do
    # An exact owner read may wait on another node. Recheck revocation and Group
    # ownership after that wait, immediately before entering the APNs transport.
    with true <- DateTime.compare(target.expires_at, SystemsClock.utc_now()) == :gt,
         {:ok, user, session} <- Accounts.resolve_session_id(target.auth_session_id),
         :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, target.group_id),
         true <- workspace["id"] == target.workspace_id,
         true <- Repo.exists?(leased(target)) do
      APNs.send(target, payload)
    else
      false ->
        {:error, :target_revoked}

      {:error, reason} when reason in [:not_found, :forbidden, :revoked, :expired, :disabled] ->
        {:error, :target_revoked}

      {:error, _} = error ->
        error
    end
  end

  defp alert_payload(target, task, badge) do
    aps = %{
      "alert" => %{"title" => "Comma", "body" => status_label(task["status"], target.locale)},
      "sound" => "default"
    }

    %{
      "aps" => if(is_integer(badge), do: Map.put(aps, "badge", badge), else: aps),
      # Opaque routing correlation only; clients must still recheck authority.
      "session_id" => target.auth_session_id,
      "workspace_id" => target.workspace_id,
      "group_id" => target.group_id,
      "task_id" => task["id"]
    }
  end

  defp router_payload(target, router, alert?) do
    aps = %{"badge" => router["unread_count"] || 0}

    aps =
      if alert?,
        do:
          Map.merge(aps, %{
            "alert" => %{"title" => "Comma", "body" => router_label(target.locale)},
            "sound" => "default"
          }),
        else: aps

    %{
      "aps" => aps,
      "type" => if(alert?, do: "router_message", else: "router_counter"),
      "session_id" => target.auth_session_id,
      "workspace_id" => target.workspace_id,
      "group_id" => target.group_id,
      "conversation_id" => router["conversation_id"],
      "message_id" => router["latest_message_id"]
    }
  end

  defp router_label("zh-Hans"), do: "Router 有新消息。"
  defp router_label(_), do: "You have a new Router message."
  defp activity_start_label("zh-Hans"), do: "你的任务状态已更新。"
  defp activity_start_label(_), do: "Your tasks are being followed."

  defp status_label(status, "zh-Hans") when status in @attention,
    do: "有任务需要你处理。"

  defp status_label("completed", "zh-Hans"), do: "有任务已完成。"
  defp status_label("failed", "zh-Hans"), do: "有任务未能完成。"
  defp status_label(status, _) when status in @attention, do: "A task needs your attention."
  defp status_label("completed", _), do: "A task is complete."
  defp status_label("failed", _), do: "A task couldn’t finish."

  defp normalize_locale("zh-Hans"), do: "zh-Hans"
  defp normalize_locale(_), do: "en-US"

  defp remove(target) do
    Repo.delete_all(leased(target))
    :obsolete
  end

  defp unrestricted(%{"session_source" => "user_login", "restricted" => false}), do: :ok
  defp unrestricted(_), do: {:error, :forbidden}
  defp lifetime("live_activity"), do: 8 * 60 * 60
  defp lifetime(_), do: 30 * 24 * 60 * 60

  defp authorize_activity("device", _attrs), do: :ok

  defp authorize_activity(kind, %{"activity_schema" => @activity_schema} = attrs) do
    if kind == "push_to_start" or
         (is_binary(attrs["activity_id"]) and byte_size(attrs["activity_id"]) in 1..256 and
            is_nil(attrs["task_id"])), do: :ok, else: {:error, :invalid_push_registration}
  end

  defp authorize_activity(_, _), do: {:error, :invalid_push_registration}

  defp registration_id(kind, attrs) when kind in ["live_activity", "push_to_start"] do
    case attrs["registration_id"] do
      nil ->
        {:ok, nil}

      id ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, :invalid_push_registration}
        end
    end
  end

  defp registration_id(_, _), do: {:ok, nil}

  # A fresh snapshot avoids alerting for Router replies sent before registration.
  # When it is unavailable, the last committed position still provides that
  # baseline; Router projection health never blocks device registration.
  defp registration_baseline(user, session, "device", workspace) do
    case RouterNotifications.snapshot(user, session, workspace["default_group_id"]) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _} -> {:ok, RouterNotifications.stored(workspace["id"])}
    end
  end

  defp registration_baseline(_, _, _, _), do: {:ok, %{}}

  defp activity_started_at(previous, attrs) do
    if previous && previous.activity_id == attrs["activity_id"],
      do: previous.activity_started_at || SystemsClock.utc_now(),
      else: SystemsClock.utc_now()
  end

  defp accepted_activity_timestamp("live_activity", session_id, previous, attrs, workspace) do
    if previous && previous.activity_id == attrs["activity_id"] &&
         previous.group_id == workspace["default_group_id"] &&
         previous.activity_schema == @activity_schema do
      previous.last_sent_version
    else
      # Admit the accepted remote start time with the row itself. A concurrent
      # recovery worker cannot observe an update address with a zero timestamp.
      started =
        Repo.one(
          from(t in Target,
            where:
              t.auth_session_id == ^session_id and
                t.group_id == ^workspace["default_group_id"] and t.kind == "push_to_start" and
                t.activity_schema == ^@activity_schema
          )
        )

      if started && future?(started.activity_start_pending_until),
        do: started.last_sent_version,
        else: 0
    end
  end

  defp accepted_activity_timestamp(_, _, _, _, _), do: 0

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: from(t in query, where: t.id > ^id)

  defp remember_state(target, task) do
    # Retain the latest 128 Task attention intervals per address, not all Task
    # history. An evicted old interval may notify again; delivery is best effort.
    recent =
      Map.put(target.recent_states, task["id"], %{
        "status" => task["status"],
        "at" => SystemsClock.system_time(:millisecond)
      })
      |> Enum.sort_by(fn {_id, value} -> value["at"] end, :desc)
      |> Enum.take(128)
      |> Map.new()

    Repo.update_all(leased(target),
      set: [recent_states: recent, updated_at: SystemsClock.timestamp(:utc_datetime_usec)]
    )
  end

  defp wake_listener(group_id) do
    case SystemsRuntime.Proc.whereis(CommaWeb.NativePushListener) do
      nil -> :ok
      pid -> SystemsRuntime.Proc.send(pid, {:native_push_group, group_id})
    end
  end
end
