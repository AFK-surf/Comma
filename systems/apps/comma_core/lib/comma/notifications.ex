defmodule Comma.Notifications do
  @moduledoc "Auth Session-owned APNs addresses and bounded exact-Task delivery work."
  import Ecto.Query
  alias Comma.{Accounts, Conversations, Repo, Workspaces}
  alias Comma.Notifications.{APNs, Target}

  @page 100
  @lease_seconds 120
  @terminal ~w(completed cancelled failed archived)
  @attention ~w(ready_for_review escalated)
  @device_statuses ~w(ready_for_review escalated completed failed)

  def register(user, session, kind, attrs) when kind in ~w(device live_activity push_to_start) do
    with :ok <- unrestricted(session),
         {:ok, bundle_id} <- APNs.registration_bundle(attrs["environment"], attrs["bundle_id"]),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, attrs["group_id"]),
         true <- workspace["id"] == attrs["workspace_id"],
         :ok <- authorize_task(user, session, kind, attrs) do
      expiry = min(session["expires_at"], System.system_time(:second) + lifetime(kind))

      values = %{
        auth_session_id: session["id"],
        kind: kind,
        token: attrs["token"],
        environment: attrs["environment"],
        bundle_id: bundle_id,
        locale: normalize_locale(attrs["locale"]),
        workspace_id: workspace["id"],
        group_id: workspace["default_group_id"],
        conversation_id: if(kind == "live_activity", do: attrs["task_id"]),
        activity_id: if(kind == "live_activity", do: attrs["activity_id"]),
        expires_at: DateTime.from_unix!(expiry)
      }

      # Each product session owns one address of each kind. Rotation replaces the
      # previous token; an iPhone-selected activity replaces that session's former Task.
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
                  :expires_at,
                  :updated_at,
                  :last_sent_version,
                  :last_sent_status,
                  :delivery_lease_until
                ]},
             returning: true
           ) do
        {:ok, target} ->
          wake_listener(target.group_id)
          if kind == "live_activity", do: enqueue(target.id)
          {:ok, %{"id" => target.id, "status" => "active"}}

        {:error, _} ->
          {:error, :invalid_push_registration}
      end
    else
      false -> {:error, :forbidden}
      {:error, _} = error -> error
    end
  end

  def unregister(session, id) do
    with {:ok, id} <- Ecto.UUID.cast(id), :ok <- unrestricted(session) do
      Repo.delete_all(
        from(t in Target, where: t.id == ^id and t.auth_session_id == ^session["id"])
      )

      :ok
    else
      _ -> {:error, :not_found}
    end
  end

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
    %{"target_id" => id, "conversation_id" => conversation_id}
    |> Comma.Workers.NativePush.new()
    |> then(&Oban.insert(Comma.Oban, &1))
  end

  def enqueue_task(group_id, conversation_id, cursor \\ nil) do
    %{"group_id" => group_id, "conversation_id" => conversation_id, "cursor" => cursor}
    |> Comma.Workers.NativePushFanout.new()
    |> then(&Oban.insert(Comma.Oban, &1))
  end

  def targets_for_task(group_id, conversation_id, cursor) do
    now = DateTime.utc_now()

    from(t in Target,
      where:
        t.group_id == ^group_id and t.expires_at > ^now and
          (t.kind in ["device", "push_to_start"] or
             (t.kind == "live_activity" and t.conversation_id == ^conversation_id)),
      order_by: [asc: t.id],
      limit: ^@page
    )
    |> after_id(cursor)
    |> Repo.all()
  end

  def recovery_page(cursor) do
    now = DateTime.utc_now()

    from(t in Target, where: t.expires_at > ^now, order_by: [asc: t.id], limit: ^@page)
    |> after_id(cursor)
    |> Repo.all()
  end

  def deliver(target_id, conversation_id) do
    # A short lease, not a row lock held across owner reads and APNs, keeps
    # concurrent Pods from sending to one address without pinning a DB connection.
    with_lease(target_id, &deliver_leased(&1, conversation_id))
  end

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
    now = DateTime.utc_now()

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

  defp deliver_leased(target, requested_task) do
    task_id = target.conversation_id || requested_task

    with true <- DateTime.compare(target.expires_at, DateTime.utc_now()) == :gt,
         {:ok, user, session} <- Accounts.resolve_session_id(target.auth_session_id),
         :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, target.group_id),
         true <- workspace["id"] == target.workspace_id,
         {:ok, task} <- Conversations.preview(user, session, target.group_id, task_id),
         version when is_integer(version) and version > 0 <- task["updated_at"] do
      cond do
        target.kind == "live_activity" and version <= target.last_sent_version ->
          :current

        target.kind == "device" and
            get_in(target.recent_states, [task_id, "status"]) == task["status"] ->
          :current

        target.kind == "device" and task["status"] not in @device_statuses ->
          remember_state(target, task)
          :current

        target.kind == "push_to_start" ->
          maybe_start(target, user, session, task)

        true ->
          push(target, task, version)
      end
    else
      false ->
        remove(target)

      {:error, reason} when reason in [:not_found, :forbidden, :revoked, :expired, :disabled] ->
        remove(target)

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_task_projection}
    end
  end

  defp push(target, task, version) do
    payload =
      if target.kind == "device", do: alert_payload(target, task), else: activity_payload(task)

    case send_authorized(target, payload) do
      :ok ->
        if target.kind == "live_activity" and task["status"] in @terminal do
          remove(target)
        else
          Repo.update_all(leased(target),
            set: [
              last_sent_version: version,
              last_sent_status: task["status"],
              updated_at: DateTime.utc_now()
            ]
          )

          if target.kind == "device", do: remember_state(target, task)
          :delivered
        end

      {:error, reason} when reason in [:invalid_token, :target_revoked] ->
        remove(target)

      {:error, _} = error ->
        error
    end
  end

  def activity_payload(task, now \\ System.system_time(:second)) do
    terminal = task["status"] in @terminal

    aps = %{
      "timestamp" => now,
      "event" => if(terminal, do: "end", else: "update"),
      "content-state" => %{
        "title" => String.slice(task["title"] || "Task", 0, 160),
        "status" => task["status"],
        "updatedAtEpochSeconds" => div(task["updated_at"], 1_000)
      },
      "stale-date" => now + 120
    }

    aps = if terminal, do: Map.put(aps, "dismissal-date", now + 60), else: aps

    aps =
      if task["status"] in @attention,
        do: Map.put(aps, "alert", %{"title" => "Comma", "body" => "A task needs your attention"}),
        else: aps

    %{"aps" => aps}
  end

  defp maybe_start(target, user, session, task) do
    with false <- Map.has_key?(target.recent_states, task["id"]),
         {:ok, %{"data" => [summary]}} <-
           Conversations.task_summaries(user, session, target.group_id, [task["id"]]),
         true <- summary["origin"] == "comma" and summary["client_platform"] == "ios",
         created_at when is_integer(created_at) <- summary["created_at"],
         true <- created_at >= DateTime.to_unix(target.inserted_at, :millisecond),
         false <- task["status"] in @terminal,
         :ok <- end_previous_activity(target, user, session, task["id"]) do
      now = System.system_time(:second)

      aps =
        activity_payload(task, now)["aps"]
        |> Map.merge(%{
          "event" => "start",
          "attributes-type" => "TaskActivityAttributes",
          "attributes" => %{
            "accountID" => user["id"],
            "workspaceID" => target.workspace_id,
            "groupID" => target.group_id,
            "taskID" => task["id"]
          },
          "input-push-token" => 1,
          "alert" => %{"title" => "Comma", "body" => "Your task is now being followed"}
        })

      case send_authorized(target, %{"aps" => aps}) do
        :ok ->
          remember_state(target, task)
          :delivered

        {:error, reason} when reason in [:invalid_token, :target_revoked] ->
          remove(target)

        {:error, _} = error ->
          error
      end
    else
      {:error, _} = error ->
        error

      :already_followed ->
        remember_state(target, task)
        :current

      _ ->
        :current
    end
  end

  defp end_previous_activity(target, user, session, task_id) do
    previous_id =
      Repo.one(
        from(t in Target,
          where: t.auth_session_id == ^target.auth_session_id and t.kind == "live_activity",
          select: t.id
        )
      )

    case previous_id && with_lease(previous_id, &end_activity(&1, user, session, task_id)) do
      result when result in [nil, :obsolete] -> :ok
      result -> result
    end
  end

  defp end_activity(previous, user, session, task_id) do
    case previous do
      %{conversation_id: ^task_id} ->
        :already_followed

      previous ->
        with {:ok, old_task} <-
               Conversations.preview(user, session, previous.group_id, previous.conversation_id) do
          payload = activity_payload(old_task)
          payload = update_in(payload, ["aps"], &Map.delete(&1, "alert"))
          # Ending presentation does not complete/cancel the underlying Task.
          payload =
            put_in(payload, ["aps", "event"], "end")
            |> put_in(["aps", "dismissal-date"], System.system_time(:second))

          case send_authorized(previous, payload) do
            result when result in [:ok, {:error, :invalid_token}, {:error, :target_revoked}] ->
              remove(previous)
              :ok

            {:error, _} = error ->
              error
          end
        end
    end
  end

  defp send_authorized(target, payload) do
    # An exact owner read may wait on another node. Recheck revocation and Group
    # ownership after that wait, immediately before entering the APNs transport.
    with true <- DateTime.compare(target.expires_at, DateTime.utc_now()) == :gt,
         {:ok, user, session} <- Accounts.resolve_session_id(target.auth_session_id),
         :ok <- unrestricted(session),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, target.group_id),
         true <- workspace["id"] == target.workspace_id do
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

  defp alert_payload(target, task) do
    %{
      "aps" => %{
        "alert" => %{"title" => "Comma", "body" => status_label(task["status"], target.locale)},
        "sound" => "default"
      },
      # Opaque routing correlation only; clients must still recheck authority.
      "session_id" => target.auth_session_id,
      "workspace_id" => target.workspace_id,
      "group_id" => target.group_id,
      "task_id" => task["id"]
    }
  end

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

  defp authorize_task(user, session, "live_activity", attrs) do
    with activity when is_binary(activity) and byte_size(activity) in 1..256 <-
           attrs["activity_id"],
         {:ok, _} <- Conversations.preview(user, session, attrs["group_id"], attrs["task_id"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_push_registration}
    end
  end

  defp authorize_task(_user, _session, _kind, _attrs), do: :ok

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: from(t in query, where: t.id > ^id)

  defp remember_state(target, task) do
    # Retain the latest 128 Task attention intervals per address, not all Task
    # history. An evicted old interval may notify again; delivery is best effort.
    recent =
      Map.put(target.recent_states, task["id"], %{
        "status" => task["status"],
        "at" => System.system_time(:millisecond)
      })
      |> Enum.sort_by(fn {_id, value} -> value["at"] end, :desc)
      |> Enum.take(128)
      |> Map.new()

    Repo.update_all(leased(target), set: [recent_states: recent, updated_at: DateTime.utc_now()])
  end

  defp wake_listener(group_id) do
    case Process.whereis(CommaWeb.NativePushListener) do
      nil -> :ok
      pid -> send(pid, {:native_push_group, group_id})
    end
  end
end
