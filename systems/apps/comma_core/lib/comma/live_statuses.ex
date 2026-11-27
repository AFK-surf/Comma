defmodule Comma.LiveStatuses do
  @moduledoc """
  Generalized Dynamic Island / Live Activity (`live_status_v1`) status projection,
  Auth Session-owned APNs target registration, and bounded delivery.
  """
  import Ecto.Query

  alias Comma.{Notifications, Repo, Workspaces}
  alias Comma.LiveStatuses.{Status, Target}
  alias Comma.Notifications.{APNs, Delivery}

  @activity_schema "live_status_v1"
  @max_active_per_group 5
  @page 100
  @activity_seconds 8 * 60 * 60
  @push_to_start_seconds 30 * 24 * 60 * 60
  @default_ttl_minutes 120
  @default_stale_minutes 15
  @recent_terminal_window_seconds 300
  @prune_age_seconds 24 * 60 * 60
  @prune_limit 50

  @active_statuses ~w(active attention)
  @terminal_statuses ~w(done cancelled failed)

  # ---------------------------------------------------------------------------
  # Status lifecycle (Agent / Loop / Server)
  # ---------------------------------------------------------------------------

  def upsert(workspace_id, group_id, attrs, opts \\ [])
      when is_binary(workspace_id) and is_binary(group_id) and is_map(attrs) do
    with {:ok, params} <- validate_upsert(attrs) do
      now = SystemsClock.utc_now()
      live_key = params.live_key
      conversation_id = opts[:conversation_id] || params.conversation_id

      Repo.transaction(fn ->
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["comma_live_statuses:" <> group_id]
        )

        existing =
          Repo.one(
            from(s in Status,
              where: s.group_id == ^group_id and s.live_key == ^live_key,
              lock: "FOR UPDATE"
            )
          )

        existing_active? =
          existing != nil and existing.status in @active_statuses and
            DateTime.compare(existing.expires_at, now) == :gt

        if not existing_active? do
          active_count =
            Repo.aggregate(
              from(s in Status,
                where:
                  s.group_id == ^group_id and s.status in ^@active_statuses and
                    s.expires_at > ^now
              ),
              :count
            )

          if active_count >= @max_active_per_group do
            Repo.rollback(:live_activity_limit_reached)
          end
        end

        {alert_seq, alert_title, alert_body} =
          case params.alert do
            nil ->
              if existing_active?,
                do: {existing.alert_seq, existing.alert_title, existing.alert_body},
                else: {(existing && existing.alert_seq) || 0, nil, nil}

            %{title: title, body: body} ->
              {((existing && existing.alert_seq) || 0) + 1, title, body}
          end

        started_at = if existing_active?, do: existing.started_at, else: now
        version = if existing, do: existing.version + 1, else: 1
        stale_at = DateTime.add(now, params.stale_minutes * 60, :second)
        expires_at = DateTime.add(now, params.ttl_minutes * 60, :second)

        resolved_conversation_id =
          conversation_id || if(existing, do: existing.conversation_id, else: nil)

        attrs_map = %{
          workspace_id: workspace_id,
          group_id: group_id,
          live_key: live_key,
          conversation_id: resolved_conversation_id,
          category: params.category,
          status: params.status,
          accent: params.accent,
          title: params.title,
          subtitle: params.subtitle,
          compact_label: params.compact_label,
          eta_at: params.eta_at,
          progress: params.progress,
          step_current: params.step_current,
          step_total: params.step_total,
          step_label: params.step_label,
          detail_left: params.detail_left,
          detail_right: params.detail_right,
          alert_title: alert_title,
          alert_body: alert_body,
          alert_seq: alert_seq,
          dismiss_after_seconds: (existing && existing.dismiss_after_seconds) || 15,
          version: version,
          started_at: started_at,
          stale_at: stale_at,
          expires_at: expires_at,
          ended_at: nil
        }

        changeset =
          if existing,
            do: Status.changeset(existing, attrs_map),
            else: Status.changeset(%Status{}, attrs_map)

        case if(existing, do: Repo.update(changeset), else: Repo.insert(changeset)) do
          {:ok, saved} -> saved
          {:error, _} -> Repo.rollback(:invalid_live_status)
        end
      end)
      |> case do
        {:ok, saved} ->
          prune_old_statuses(group_id, SystemsClock.utc_now())
          enqueue_group(group_id, saved.live_key)
          enqueue_expiry(group_id, saved.live_key, saved.expires_at)
          {:ok, serialize(saved)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def end_status(group_id, attrs) when is_binary(group_id) and is_map(attrs) do
    with {:ok, params} <- validate_end(attrs) do
      now = SystemsClock.utc_now()
      live_key = params.live_key

      Repo.transaction(fn ->
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["comma_live_statuses:" <> group_id]
        )

        existing =
          Repo.one(
            from(s in Status,
              where: s.group_id == ^group_id and s.live_key == ^live_key,
              lock: "FOR UPDATE"
            )
          )

        if is_nil(existing) do
          Repo.rollback(:not_found)
        end

        {alert_seq, alert_title, alert_body} =
          case params.alert do
            nil -> {existing.alert_seq, existing.alert_title, existing.alert_body}
            %{title: title, body: body} -> {existing.alert_seq + 1, title, body}
          end

        changes = %{
          status: params.outcome,
          title: params.title || existing.title,
          subtitle: if(params.has_subtitle, do: params.subtitle, else: existing.subtitle),
          alert_seq: alert_seq,
          alert_title: alert_title,
          alert_body: alert_body,
          dismiss_after_seconds: params.dismiss_after_seconds,
          version: existing.version + 1,
          ended_at: now
        }

        case Repo.update(Status.changeset(existing, changes)) do
          {:ok, saved} -> saved
          {:error, _} -> Repo.rollback(:invalid_live_status)
        end
      end)
      |> case do
        {:ok, saved} ->
          enqueue_group(group_id, saved.live_key)
          {:ok, serialize(saved)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def list_active(group_id) when is_binary(group_id) do
    active_status_rows(group_id) |> Enum.map(&serialize/1)
  end

  def list_visible(group_id) when is_binary(group_id) do
    now = SystemsClock.utc_now()
    now_unix = DateTime.to_unix(now)
    active = active_status_rows(group_id, now)
    recent_cutoff = DateTime.add(now, -@recent_terminal_window_seconds, :second)

    recent_terminal =
      from(s in Status,
        where:
          s.group_id == ^group_id and s.status in ^@terminal_statuses and
            not is_nil(s.ended_at) and s.ended_at > ^recent_cutoff,
        order_by: [desc: s.ended_at, asc: s.live_key],
        limit: ^@max_active_per_group
      )
      |> Repo.all()
      |> Enum.filter(fn s ->
        DateTime.to_unix(s.ended_at) + (s.dismiss_after_seconds || 0) > now_unix
      end)

    (active ++ recent_terminal) |> Enum.map(&serialize/1)
  end

  def list_active_authorized(user, session, group_id) when is_binary(group_id) do
    with :ok <- unrestricted(session),
         {:ok, _workspace} <- Workspaces.authorize_group(user, session, group_id) do
      {:ok, %{"data" => list_visible(group_id)}}
    end
  end

  def prune_old_statuses(group_id, now \\ SystemsClock.utc_now()) when is_binary(group_id) do
    cutoff = DateTime.add(now, -@prune_age_seconds, :second)

    ids_query =
      from(s in Status,
        where:
          s.group_id == ^group_id and
            ((not is_nil(s.ended_at) and s.ended_at < ^cutoff) or
               (is_nil(s.ended_at) and s.expires_at < ^cutoff)),
        order_by: [asc: s.updated_at, asc: s.id],
        limit: ^@prune_limit,
        select: s.id
      )

    {deleted, _} = Repo.delete_all(from(s in Status, where: s.id in subquery(ids_query)))
    deleted
  end

  def serialize(%Status{} = s) do
    %{
      "key" => s.live_key,
      "workspace_id" => s.workspace_id,
      "group_id" => s.group_id,
      "conversation_id" => s.conversation_id,
      "category" => s.category,
      "status" => s.status,
      "accent" => s.accent,
      "title" => s.title,
      "subtitle" => s.subtitle,
      "compact_label" => s.compact_label,
      "eta_epoch_seconds" => unix_or_nil(s.eta_at),
      "progress" => s.progress,
      "step_current" => s.step_current,
      "step_total" => s.step_total,
      "step_label" => s.step_label,
      "detail_left" => s.detail_left,
      "detail_right" => s.detail_right,
      "started_at_epoch_seconds" => unix_or_nil(s.started_at),
      "dismiss_at_epoch_seconds" => dismiss_at_unix(s),
      "stale_epoch_seconds" => unix_or_nil(s.stale_at),
      "expires_epoch_seconds" => unix_or_nil(s.expires_at),
      "updated_at_epoch_seconds" => unix_or_nil(s.updated_at)
    }
  end

  # ---------------------------------------------------------------------------
  # Target registration & unregistration
  # ---------------------------------------------------------------------------

  def register(user, session, kind, attrs)
      when kind in ~w(push_to_start live_activity) and is_map(attrs) do
    with :ok <- unrestricted(session),
         {:ok, bundle_id} <- APNs.registration_bundle(attrs["environment"], attrs["bundle_id"]),
         {:ok, workspace} <- Workspaces.authorize_group(user, session, attrs["group_id"]),
         true <- workspace["id"] == attrs["workspace_id"],
         :ok <- validate_registration_shape(kind, attrs),
         {:ok, registration_id} <- parse_registration_id(attrs["registration_id"]) do
      live_key = if kind == "push_to_start", do: "", else: attrs["live_key"]
      now = SystemsClock.utc_now()
      now_unix = DateTime.to_unix(now)

      previous =
        Repo.one(
          from(t in Target,
            where:
              t.auth_session_id == ^session["id"] and t.kind == ^kind and
                t.live_key == ^live_key
          )
        )

      started_at =
        if kind == "live_activity" do
          if previous && previous.activity_id == attrs["activity_id"] &&
               previous.activity_started_at != nil do
            previous.activity_started_at
          else
            now
          end
        else
          nil
        end

      expiry_unix =
        min(
          session["expires_at"],
          if(kind == "live_activity",
            do: DateTime.to_unix(started_at) + @activity_seconds,
            else: now_unix + @push_to_start_seconds
          )
        )

      {seed, reset_tracking?} =
        if kind == "live_activity" do
          same_activity? =
            previous != nil and previous.group_id == workspace["default_group_id"] and
              previous.activity_id == attrs["activity_id"]

          if same_activity? do
            {%{
               last_sent_version: previous.last_sent_version,
               last_sent_timestamp: previous.last_sent_timestamp,
               last_sent_alert_seq: previous.last_sent_alert_seq,
               last_sent_content: previous.last_sent_content
             }, false}
          else
            {pending_start_seed(session["id"], workspace["default_group_id"], live_key), true}
          end
        else
          {%{
             last_sent_version: 0,
             last_sent_timestamp: 0,
             last_sent_alert_seq: 0,
             last_sent_content: %{}
           }, false}
        end

      values = %{
        auth_session_id: session["id"],
        kind: kind,
        live_key: live_key,
        token: attrs["token"],
        environment: attrs["environment"],
        bundle_id: bundle_id,
        locale: normalize_locale(attrs["locale"]),
        workspace_id: workspace["id"],
        group_id: workspace["default_group_id"],
        activity_id: if(kind == "live_activity", do: attrs["activity_id"], else: nil),
        activity_schema: @activity_schema,
        activity_started_at: started_at,
        last_sent_version: seed.last_sent_version,
        last_sent_timestamp: seed.last_sent_timestamp,
        last_sent_alert_seq: seed.last_sent_alert_seq,
        last_sent_content: seed.last_sent_content,
        expires_at: DateTime.from_unix!(expiry_unix)
      }

      values = if registration_id, do: Map.put(values, :id, registration_id), else: values

      reset_scope? = previous == nil or previous.group_id != values.group_id

      replace_fields =
        [
          :id,
          :token,
          :environment,
          :bundle_id,
          :locale,
          :workspace_id,
          :group_id,
          :activity_id,
          :activity_schema,
          :activity_started_at,
          :expires_at,
          :updated_at,
          :delivery_lease_until
        ] ++
          if(reset_scope?, do: [:pending_starts, :suppressed_keys], else: []) ++
          if(reset_scope? or reset_tracking?,
            do: [
              :last_sent_version,
              :last_sent_timestamp,
              :last_sent_alert_seq,
              :last_sent_content
            ],
            else: []
          )

      case Repo.insert(Target.changeset(%Target{}, values),
             conflict_target: [:auth_session_id, :kind, :live_key],
             on_conflict: {:replace, replace_fields},
             returning: true
           ) do
        {:ok, target} ->
          if kind == "live_activity" do
            acknowledge_pending_start(session["id"], target.group_id, live_key)
            enqueue_target(target.id, live_key)
          else
            enqueue_target(target.id, nil)
          end

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
      Repo.transaction(fn ->
        target =
          Repo.one(
            from(t in Target,
              where: t.id == ^id and t.auth_session_id == ^session["id"],
              lock: "FOR UPDATE"
            )
          )

        if target && target.kind == "live_activity" do
          pts_query =
            from(t in Target,
              where:
                t.auth_session_id == ^session["id"] and t.group_id == ^target.group_id and
                  t.kind == "push_to_start",
              lock: "FOR UPDATE"
            )

          case Repo.one(pts_query) do
            %Target{} = pts ->
              pending = Map.delete(pts.pending_starts || %{}, target.live_key)

              suppressed =
                if reason in ["dismissed", "stopped"] do
                  started_unix = suppressed_started_unix(target)
                  Map.put(pts.suppressed_keys || %{}, target.live_key, started_unix)
                else
                  pts.suppressed_keys || %{}
                end

              Repo.update_all(
                from(t in Target, where: t.id == ^pts.id),
                set: [
                  pending_starts: pending,
                  suppressed_keys: suppressed,
                  updated_at: SystemsClock.timestamp(:utc_datetime_usec)
                ]
              )

            nil ->
              :ok
          end
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

  # ---------------------------------------------------------------------------
  # Oban enqueue & fanout queries
  # ---------------------------------------------------------------------------

  def enqueue_group(group_id, live_key, cursor \\ nil) do
    if Oban.whereis(Comma.Oban) do
      Notifications.insert_wakeup(Comma.Workers.LiveStatusPushFanout, %{
        "group_id" => group_id,
        "live_key" => live_key,
        "cursor" => cursor
      })
    else
      {:ok, :no_oban}
    end
  end

  def enqueue_expiry(group_id, live_key, %DateTime{} = expires_at) do
    if Oban.whereis(Comma.Oban) do
      Oban.insert(
        Comma.Oban,
        Comma.Workers.LiveStatusPushFanout.new(
          %{
            "group_id" => group_id,
            "live_key" => live_key,
            "cursor" => nil,
            "expires_at_unix" => DateTime.to_unix(expires_at),
            "successor" => 0
          },
          scheduled_at: expires_at
        )
      )
    else
      {:ok, :no_oban}
    end
  end

  def enqueue_target(target_id, live_key) do
    if Oban.whereis(Comma.Oban) do
      Notifications.insert_wakeup(Comma.Workers.LiveStatusPush, %{
        "target_id" => target_id,
        "live_key" => live_key
      })
    else
      {:ok, :no_oban}
    end
  end

  def targets_for_key(group_id, live_key, cursor \\ nil) do
    now = SystemsClock.utc_now()

    from(t in Target,
      where:
        t.group_id == ^group_id and t.expires_at > ^now and
          (t.kind == "push_to_start" or (t.kind == "live_activity" and t.live_key == ^live_key)),
      order_by: [asc: t.id],
      limit: ^@page
    )
    |> after_id(cursor)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # APNs delivery
  # ---------------------------------------------------------------------------

  def deliver(target_id, live_key \\ nil) do
    with_lease(target_id, &deliver_leased(&1, live_key))
  end

  def content_state(%Status{} = s) do
    %{
      "category" => s.category,
      "status" => s.status,
      "accent" => s.accent,
      "title" => s.title,
      "updatedAtEpochSeconds" => DateTime.to_unix(s.updated_at || SystemsClock.utc_now())
    }
    |> maybe_put("subtitle", s.subtitle)
    |> maybe_put("compactLabel", s.compact_label)
    |> maybe_put("etaEpochSeconds", unix_or_nil(s.eta_at))
    |> maybe_put("progress", s.progress)
    |> maybe_put("stepCurrent", s.step_current)
    |> maybe_put("stepTotal", s.step_total)
    |> maybe_put("stepLabel", s.step_label)
    |> maybe_put("detailLeft", s.detail_left)
    |> maybe_put("detailRight", s.detail_right)
  end

  defp deliver_leased(%Target{kind: "live_activity"} = target, _requested_key) do
    with {:ok, _user, _session} <- authority(target) do
      case Repo.get_by(Status, group_id: target.group_id, live_key: target.live_key) do
        nil ->
          remove(target)

        %Status{} = status ->
          now = SystemsClock.utc_now()

          ended? =
            status.status in @terminal_statuses or DateTime.compare(status.expires_at, now) != :gt

          if ended? do
            deliver_end(target, status)
          else
            deliver_update(target, status)
          end
      end
    else
      error -> delivery_error(target, error)
    end
  end

  defp deliver_leased(%Target{kind: "push_to_start"} = target, requested_key) do
    with {:ok, user, _session} <- authority(target) do
      now = SystemsClock.utc_now()
      now_unix = DateTime.to_unix(now)

      {target, statuses} =
        if is_binary(requested_key) and requested_key != "" do
          case Repo.get_by(Status, group_id: target.group_id, live_key: requested_key) do
            %Status{} = status ->
              if status.status in @active_statuses and
                   DateTime.compare(status.expires_at, now) == :gt do
                {target, [status]}
              else
                {clear_pending_start(target, requested_key), []}
              end

            nil ->
              {clear_pending_start(target, requested_key), []}
          end
        else
          active = active_status_rows(target.group_id, now)
          {prune_stale_pending_starts(target, active), active}
        end

      deliver_starts(target, user, statuses, now, now_unix)
    else
      error -> delivery_error(target, error)
    end
  end

  def relevance_score(%Status{} = status, now \\ SystemsClock.utc_now()) do
    cond do
      status.status in @terminal_statuses ->
        10.0

      status.status == "attention" ->
        case status.eta_at do
          %DateTime{} = eta_at ->
            if DateTime.compare(eta_at, now) == :gt do
              remaining = DateTime.diff(eta_at, now, :second)
              bonus = 5.0 * max(0.0, 1.0 - min(remaining, 3600) / 3600.0)
              Float.round(90.0 + bonus, 1)
            else
              90.0
            end

          _ ->
            90.0
        end

      true ->
        case status.eta_at do
          %DateTime{} = eta_at ->
            if DateTime.compare(eta_at, now) == :gt do
              remaining = DateTime.diff(eta_at, now, :second)
              score = 45.0 + 40.0 * max(0.0, 1.0 - min(remaining, 7200) / 7200.0)
              Float.round(score, 1)
            else
              40.0
            end

          _ ->
            40.0
        end
    end
  end

  defp deliver_update(target, status) do
    content = content_state(status)
    alert? = new_alert?(target, status)

    if status.version <= target.last_sent_version and target.last_sent_content == content and
         not alert? do
      :current
    else
      with {:ok, timestamp} <- next_activity_timestamp(target) do
        aps =
          %{
            "timestamp" => timestamp,
            "event" => "update",
            "content-state" => content,
            "stale-date" => DateTime.to_unix(status.stale_at),
            "relevance-score" => relevance_score(status, SystemsClock.utc_now())
          }
          |> maybe_put_alert(status, alert?)

        case send_authorized(target, %{"aps" => aps}) do
          :ok ->
            next_alert_seq = if alert?, do: status.alert_seq, else: target.last_sent_alert_seq

            Repo.update_all(leased(target),
              set: [
                last_sent_version: status.version,
                last_sent_timestamp: timestamp,
                last_sent_alert_seq: next_alert_seq,
                last_sent_content: content,
                updated_at: SystemsClock.timestamp(:utc_datetime_usec)
              ]
            )

            :delivered

          error ->
            delivery_error(target, error)
        end
      end
    end
  end

  defp deliver_end(target, status) do
    content = content_state(status)
    alert? = new_alert?(target, status)

    with {:ok, timestamp} <- next_activity_timestamp(target) do
      aps =
        %{
          "timestamp" => timestamp,
          "event" => "end",
          "content-state" => content,
          "stale-date" => DateTime.to_unix(status.stale_at),
          "dismissal-date" => timestamp + status.dismiss_after_seconds,
          "relevance-score" => relevance_score(status, SystemsClock.utc_now())
        }
        |> maybe_put_alert(status, alert?)

      case send_authorized(target, %{"aps" => aps}) do
        :ok ->
          Repo.update_all(leased(target),
            set: [
              last_sent_timestamp: timestamp,
              updated_at: SystemsClock.timestamp(:utc_datetime_usec)
            ]
          )

          acknowledge_pending_start(target.auth_session_id, target.group_id, target.live_key)
          remove(target)
          :delivered

        error ->
          delivery_error(target, error)
      end
    end
  end

  defp deliver_starts(_target, _user, [], _now, _now_unix), do: :current

  defp deliver_starts(target, user, statuses, now, now_unix) do
    Enum.reduce_while(statuses, {:current, target}, fn status, {acc_result, current_target} ->
      case maybe_start_one(current_target, user, status, now, now_unix) do
        {:delivered, updated_target} -> {:cont, {:delivered, updated_target}}
        :current -> {:cont, {acc_result, current_target}}
        {:error, _} = error -> {:halt, {error, current_target}}
        :obsolete -> {:halt, {:obsolete, current_target}}
      end
    end)
    |> elem(0)
  end

  defp maybe_start_one(target, user, status, now, now_unix) do
    live_key = status.live_key
    started_unix = DateTime.to_unix(status.started_at)

    existing_activity =
      Repo.one(
        from(t in Target,
          where:
            t.auth_session_id == ^target.auth_session_id and t.group_id == ^target.group_id and
              t.kind == "live_activity" and t.live_key == ^live_key and t.expires_at > ^now
        )
      )

    suppressed_unix = (target.suppressed_keys || %{})[live_key]
    pending = (target.pending_starts || %{})[live_key]

    cond do
      existing_activity != nil ->
        enqueue_target(existing_activity.id, live_key)
        :current

      is_integer(suppressed_unix) and suppressed_unix >= started_unix ->
        :current

      is_map(pending) and pending["started_at_unix"] == started_unix and
        is_integer(pending["pending_until_unix"]) and pending["pending_until_unix"] > now_unix ->
        :current

      true ->
        with {:ok, timestamp} <- next_activity_timestamp(target) do
          content = content_state(status)

          attributes =
            %{
              "accountID" => user["id"],
              "workspaceID" => target.workspace_id,
              "groupID" => target.group_id,
              "liveKey" => live_key,
              "startedAtEpochSeconds" => started_unix
            }
            |> maybe_put("conversationID", status.conversation_id)

          aps = %{
            "timestamp" => timestamp,
            "event" => "start",
            "content-state" => content,
            "stale-date" => DateTime.to_unix(status.stale_at),
            "relevance-score" => relevance_score(status, now),
            "attributes-type" => "LiveStatusAttributes",
            "attributes" => attributes,
            "input-push-token" => 1,
            "alert" => %{
              "title" => status.alert_title || status.title,
              "body" => status.alert_body || status.subtitle || default_start_body(target.locale)
            }
          }

          case send_authorized(target, %{"aps" => aps}) do
            :ok ->
              pending_starts =
                Map.put(target.pending_starts || %{}, live_key, %{
                  "started_at_unix" => started_unix,
                  "pending_until_unix" => timestamp + @activity_seconds,
                  "version" => status.version,
                  "timestamp" => timestamp,
                  "alert_seq" => status.alert_seq,
                  "content" => content
                })

              suppressed_keys = Map.delete(target.suppressed_keys || %{}, live_key)

              Repo.update_all(leased(target),
                set: [
                  pending_starts: pending_starts,
                  suppressed_keys: suppressed_keys,
                  last_sent_version: status.version,
                  last_sent_timestamp: timestamp,
                  updated_at: SystemsClock.timestamp(:utc_datetime_usec)
                ]
              )

              {:delivered,
               %{
                 target
                 | pending_starts: pending_starts,
                   suppressed_keys: suppressed_keys,
                   last_sent_version: status.version,
                   last_sent_timestamp: timestamp
               }}

            error ->
              delivery_error(target, error)
          end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Lease & authorization helpers
  # ---------------------------------------------------------------------------

  defp with_lease(target_id, fun), do: Delivery.with_lease(Target, target_id, fun)
  defp leased(target), do: Delivery.leased(target)
  defp authority(target), do: Delivery.authority(target)
  defp send_authorized(target, payload), do: Delivery.send_authorized(target, payload)

  defp delivery_error(target, error),
    do: Delivery.delivery_error(target, error, :invalid_live_status)

  defp remove(target), do: Delivery.remove(target)

  # ---------------------------------------------------------------------------
  # Internal helpers & validation
  # ---------------------------------------------------------------------------

  defp active_status_rows(group_id, now \\ SystemsClock.utc_now()) do
    from(s in Status,
      where: s.group_id == ^group_id and s.status in ^@active_statuses and s.expires_at > ^now,
      order_by: [desc: s.updated_at, asc: s.live_key],
      limit: ^@max_active_per_group
    )
    |> Repo.all()
  end

  defp next_activity_timestamp(target) do
    now = SystemsClock.system_time(:second)

    if now > target.last_sent_timestamp,
      do: {:ok, now},
      else: {:error, :activity_update_busy}
  end

  defp pending_start_seed(session_id, group_id, live_key) do
    default = %{
      last_sent_version: 0,
      last_sent_timestamp: 0,
      last_sent_alert_seq: 0,
      last_sent_content: %{}
    }

    case Repo.one(
           from(t in Target,
             where:
               t.auth_session_id == ^session_id and t.group_id == ^group_id and
                 t.kind == "push_to_start"
           )
         ) do
      %Target{pending_starts: pending} when is_map(pending) ->
        case pending[live_key] do
          %{} = entry ->
            %{
              last_sent_version: if(is_integer(entry["version"]), do: entry["version"], else: 0),
              last_sent_timestamp:
                if(is_integer(entry["timestamp"]), do: entry["timestamp"], else: 0),
              last_sent_alert_seq:
                if(is_integer(entry["alert_seq"]), do: entry["alert_seq"], else: 0),
              last_sent_content: if(is_map(entry["content"]), do: entry["content"], else: %{})
            }

          _ ->
            default
        end

      _ ->
        default
    end
  end

  defp acknowledge_pending_start(session_id, group_id, live_key) do
    case Repo.one(
           from(t in Target,
             where:
               t.auth_session_id == ^session_id and t.group_id == ^group_id and
                 t.kind == "push_to_start"
           )
         ) do
      %Target{id: id, pending_starts: pending} when is_map(pending) ->
        if Map.has_key?(pending, live_key) do
          Repo.update_all(
            from(t in Target, where: t.id == ^id),
            set: [
              pending_starts: Map.delete(pending, live_key),
              updated_at: SystemsClock.timestamp(:utc_datetime_usec)
            ]
          )
        end

      _ ->
        :ok
    end
  end

  defp clear_pending_start(%Target{} = target, live_key) do
    pending = target.pending_starts || %{}

    if Map.has_key?(pending, live_key) do
      cleaned = Map.delete(pending, live_key)

      Repo.update_all(leased(target),
        set: [
          pending_starts: cleaned,
          updated_at: SystemsClock.timestamp(:utc_datetime_usec)
        ]
      )

      %{target | pending_starts: cleaned}
    else
      target
    end
  end

  defp prune_stale_pending_starts(%Target{} = target, active_statuses) do
    pending = target.pending_starts || %{}
    active_keys = MapSet.new(active_statuses, & &1.live_key)
    stale_keys = Enum.reject(Map.keys(pending), &MapSet.member?(active_keys, &1))

    if stale_keys != [] do
      cleaned = Map.drop(pending, stale_keys)

      Repo.update_all(leased(target),
        set: [
          pending_starts: cleaned,
          updated_at: SystemsClock.timestamp(:utc_datetime_usec)
        ]
      )

      %{target | pending_starts: cleaned}
    else
      target
    end
  end

  defp suppressed_started_unix(target) do
    case Repo.get_by(Status, group_id: target.group_id, live_key: target.live_key) do
      %Status{started_at: %DateTime{} = started_at} -> DateTime.to_unix(started_at)
      _ -> unix_or_nil(target.activity_started_at) || SystemsClock.system_time(:second)
    end
  end

  defp new_alert?(target, status) do
    status.alert_seq > target.last_sent_alert_seq and is_binary(status.alert_body) and
      status.alert_body != ""
  end

  defp maybe_put_alert(aps, status, true) do
    Map.put(aps, "alert", %{
      "title" => status.alert_title || status.title,
      "body" => status.alert_body
    })
  end

  defp maybe_put_alert(aps, _status, false), do: aps

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_start_body("zh-Hans"), do: "实时状态已开始跟踪。"
  defp default_start_body(_), do: "Live status tracking started."

  defp normalize_locale(locale), do: Delivery.normalize_locale(locale)
  defp unrestricted(session), do: Delivery.unrestricted(session)

  defp dismiss_at_unix(%Status{status: status, ended_at: %DateTime{} = ended_at} = s)
       when status in @terminal_statuses do
    DateTime.to_unix(ended_at) + (s.dismiss_after_seconds || 0)
  end

  defp dismiss_at_unix(_), do: nil

  defp validate_registration_shape("push_to_start", %{"activity_schema" => @activity_schema}),
    do: :ok

  defp validate_registration_shape(
         "live_activity",
         %{"activity_schema" => @activity_schema} = attrs
       ) do
    if is_binary(attrs["activity_id"]) and byte_size(attrs["activity_id"]) in 1..256 and
         is_binary(attrs["live_key"]) and Regex.match?(Status.key_pattern(), attrs["live_key"]) do
      :ok
    else
      {:error, :invalid_push_registration}
    end
  end

  defp validate_registration_shape(_, _), do: {:error, :invalid_push_registration}

  defp parse_registration_id(nil), do: {:ok, nil}

  defp parse_registration_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_push_registration}
    end
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: from(t in query, where: t.id > ^id)

  defp unix_or_nil(nil), do: nil
  defp unix_or_nil(%DateTime{} = dt), do: DateTime.to_unix(dt)

  # ---------------------------------------------------------------------------
  # Input validation
  # ---------------------------------------------------------------------------

  defp validate_upsert(attrs) do
    raw_key = attrs["key"] || attrs["live_key"]
    category = attrs["category"]
    status = attrs["status"] || "active"
    accent = attrs["accent"] || "auto"

    with {:ok, live_key} <- validate_key(raw_key),
         true <- category in Status.categories() || {:error, :invalid_category},
         true <- status in @active_statuses || {:error, :invalid_status},
         true <- accent in Status.accents() || {:error, :invalid_accent},
         {:ok, title} <- validate_required_text(attrs["title"], 1, 80, :invalid_title),
         {:ok, subtitle} <- validate_optional_text(attrs["subtitle"], 100, :invalid_subtitle),
         {:ok, compact_label} <-
           validate_optional_text(attrs["compact_label"], 16, :invalid_compact_label),
         {:ok, eta_at} <- validate_eta(attrs["eta_at"]),
         {:ok, progress} <- validate_progress(attrs["progress"]),
         {:ok, {step_current, step_total, step_label}} <- validate_step(attrs),
         {:ok, detail_left} <-
           validate_optional_text(attrs["detail_left"], 48, :invalid_detail_left),
         {:ok, detail_right} <-
           validate_optional_text(attrs["detail_right"], 32, :invalid_detail_right),
         {:ok, alert} <- validate_alert(attrs["alert"]),
         {:ok, ttl_minutes} <-
           validate_int_range(attrs["ttl_minutes"], 5, 480, @default_ttl_minutes, :invalid_ttl),
         {:ok, stale_minutes} <-
           validate_int_range(
             attrs["stale_minutes"],
             1,
             120,
             @default_stale_minutes,
             :invalid_stale
           ),
         {:ok, conversation_id} <-
           validate_optional_text(attrs["conversation_id"], 256, :invalid_conversation_id) do
      {:ok,
       %{
         live_key: live_key,
         category: category,
         status: status,
         accent: accent,
         title: title,
         subtitle: subtitle,
         compact_label: compact_label,
         eta_at: eta_at,
         progress: progress,
         step_current: step_current,
         step_total: step_total,
         step_label: step_label,
         detail_left: detail_left,
         detail_right: detail_right,
         alert: alert,
         ttl_minutes: ttl_minutes,
         stale_minutes: stale_minutes,
         conversation_id: conversation_id
       }}
    end
  end

  defp validate_end(attrs) do
    raw_key = attrs["key"] || attrs["live_key"]
    outcome = attrs["outcome"] || "done"
    default_dismiss = if outcome == "done", do: 15, else: 0

    with {:ok, live_key} <- validate_key(raw_key),
         true <- outcome in @terminal_statuses || {:error, :invalid_outcome},
         {:ok, title} <- validate_optional_nonempty_text(attrs["title"], 80, :invalid_title),
         {:ok, subtitle} <- validate_optional_text(attrs["subtitle"], 100, :invalid_subtitle),
         {:ok, alert} <- validate_alert(attrs["alert"]),
         {:ok, dismiss_after_seconds} <-
           validate_int_range(
             attrs["dismiss_after_seconds"],
             0,
             300,
             default_dismiss,
             :invalid_dismiss_after_seconds
           ) do
      {:ok,
       %{
         live_key: live_key,
         outcome: outcome,
         title: title,
         has_subtitle: Map.has_key?(attrs, "subtitle"),
         subtitle: subtitle,
         alert: alert,
         dismiss_after_seconds: dismiss_after_seconds
       }}
    end
  end

  defp validate_key(key) when is_binary(key) do
    if Regex.match?(Status.key_pattern(), key),
      do: {:ok, key},
      else: {:error, :invalid_live_key}
  end

  defp validate_key(_), do: {:error, :invalid_live_key}

  defp validate_required_text(value, min, max, error) when is_binary(value) do
    trimmed = String.trim(value)
    len = String.length(trimmed)
    if len >= min and len <= max, do: {:ok, trimmed}, else: {:error, error}
  end

  defp validate_required_text(_, _, _, error), do: {:error, error}

  defp validate_optional_nonempty_text(nil, _max, _error), do: {:ok, nil}

  defp validate_optional_nonempty_text(value, max, error) when is_binary(value) do
    trimmed = String.trim(value)
    len = String.length(trimmed)
    if len >= 1 and len <= max, do: {:ok, trimmed}, else: {:error, error}
  end

  defp validate_optional_nonempty_text(_, _, error), do: {:error, error}

  defp validate_optional_text(nil, _max, _error), do: {:ok, nil}

  defp validate_optional_text(value, max, error) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) <= max -> {:ok, trimmed}
      true -> {:error, error}
    end
  end

  defp validate_optional_text(_, _, error), do: {:error, error}

  defp validate_eta(nil), do: {:ok, nil}
  defp validate_eta(%DateTime{} = dt), do: {:ok, dt}

  defp validate_eta(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:error, :invalid_eta_at}
    end
  end

  defp validate_eta(_), do: {:error, :invalid_eta_at}

  defp validate_progress(nil), do: {:ok, nil}

  defp validate_progress(value) when is_integer(value) and value in [0, 1],
    do: {:ok, value * 1.0}

  defp validate_progress(value) when is_float(value) and value >= 0.0 and value <= 1.0,
    do: {:ok, value}

  defp validate_progress(_), do: {:error, :invalid_progress}

  defp validate_step(%{"step" => nil}), do: {:ok, {nil, nil, nil}}

  defp validate_step(%{"step" => %{} = step}) do
    current = step["current"]
    total = step["total"]

    with true <- (is_integer(current) and current in 1..8) || {:error, :invalid_step},
         true <- (is_integer(total) and total in 2..8) || {:error, :invalid_step},
         true <- current <= total || {:error, :invalid_step},
         {:ok, label} <- validate_optional_text(step["label"], 24, :invalid_step_label) do
      {:ok, {current, total, label}}
    end
  end

  defp validate_step(%{"step" => _}), do: {:error, :invalid_step}

  defp validate_step(attrs) do
    current = attrs["step_current"]
    total = attrs["step_total"]
    label = attrs["step_label"]

    if is_nil(current) and is_nil(total) and is_nil(label) do
      {:ok, {nil, nil, nil}}
    else
      validate_step(%{"step" => %{"current" => current, "total" => total, "label" => label}})
    end
  end

  defp validate_alert(nil), do: {:ok, nil}

  defp validate_alert(%{} = alert) do
    with {:ok, body} <- validate_required_text(alert["body"], 1, 120, :invalid_alert),
         {:ok, title} <- validate_optional_text(alert["title"], 48, :invalid_alert) do
      {:ok, %{title: title, body: body}}
    end
  end

  defp validate_alert(_), do: {:error, :invalid_alert}

  defp validate_int_range(nil, _min, _max, default, _error), do: {:ok, default}

  defp validate_int_range(val, min, max, _default, _error)
       when is_integer(val) and val >= min and val <= max,
       do: {:ok, val}

  defp validate_int_range(_, _min, _max, _default, error), do: {:error, error}
end
