defmodule SalixAgent.Schedules do
  @moduledoc """
  Agent schedule and heartbeat public API.

  Reads and writes the shared Postgres schedule store
  (`SalixStore.Schedules` / `SalixStore.ScheduleRuns`) — the same table the
  sweeper (`SalixCluster.Schedules`) fires from — so the two legacy writer
  schemas are gone: heartbeat records are ordinary rows with
  `kind: "heartbeat"`, their heartbeat-only fields (`cron_expr`, result
  echoes) riding the `attrs` jsonb. Pause/resume writes the `status` column
  the due scan actually honors (the legacy S3 `status` field was decorative).

  Heartbeats are interval-recurrence rows (`interval_minutes`); `cron_expr` is
  display metadata, exactly as the legacy sweeper treated it. This module
  computes interval next-fire bounds locally and never needs the cron
  evaluator (status-only updates go through `set_status`, which leaves the
  stored bound untouched).
  """

  alias SalixAgent.Control
  alias SalixStore.ScheduleRuns

  @store SalixStore.Schedules

  def get_heartbeat(agent_id, tenant_id) do
    with {:ok, agent} <- Control.get(agent_id, tenant_id),
         {:ok, schedule_id} <- heartbeat_schedule_id(agent),
         {:ok, rec} <- @store.get(schedule_id),
         true <- rec["kind"] == "heartbeat" do
      {:ok, heartbeat_json(rec)}
    else
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  def upsert_heartbeat(agent_id, attrs, tenant_id) when is_map(attrs) do
    now_ms = now_ms()

    with {:ok, agent} <- Control.get(agent_id, tenant_id),
         {:ok, schedule_id} <- heartbeat_schedule_id(agent) do
      rec =
        %{
          "id" => schedule_id,
          "agent_id" => agent_id,
          "kind" => "heartbeat",
          "name" => "Heartbeat",
          "prompt" => attrs["prompt"] || "",
          "cron_expr" => attrs["cron_expr"] || "0 */12 * * *",
          "timezone" => attrs["timezone"] || "UTC",
          "interval_minutes" => attrs["interval_minutes"] || 720,
          "status" => attrs["status"] || "active",
          "created_at" => now_ms,
          "updated_at" => now_ms,
          "last_run" => nil
        }
        |> put_optional("template_id", nonblank(attrs["template_id"]))
        |> put_optional("reasoning_effort", nonblank(attrs["reasoning_effort"]))

      with {:ok, heartbeat} <- upsert(schedule_id, rec, now_ms) do
        {:ok, heartbeat_json(heartbeat)}
      end
    end
  end

  def pause_heartbeat(agent_id, tenant_id),
    do: update_agent_heartbeat_status(agent_id, "paused", tenant_id)

  def resume_heartbeat(agent_id, tenant_id),
    do: update_agent_heartbeat_status(agent_id, "active", tenant_id)

  def list(agent_id, tenant_id) do
    with {:ok, _agent} <- Control.get(agent_id, tenant_id),
         {:ok, records} <- @store.list_by_agent(agent_id) do
      schedules =
        records
        |> Enum.reject(&(&1["kind"] == "heartbeat"))
        |> Enum.map(&schedule_json/1)
        |> Enum.sort_by(&{&1["created_at"], &1["schedule_id"]}, :desc)

      {:ok, schedules}
    end
  end

  def list_runs(agent_id, schedule_id, tenant_id) do
    with {:ok, schedule} <- get_owned_schedule(agent_id, schedule_id, tenant_id),
         {:ok, records} <- ScheduleRuns.list_for(schedule["id"]) do
      runs =
        records
        |> Enum.map(&schedule_run_json(schedule, &1))
        |> Enum.sort_by(&{&1["scheduled_for"], &1["run_id"]}, :desc)

      {:ok, runs}
    end
  end

  def pause(agent_id, schedule_id, tenant_id),
    do: update_agent_schedule_status(agent_id, schedule_id, "paused", tenant_id)

  def resume(agent_id, schedule_id, tenant_id),
    do: update_agent_schedule_status(agent_id, schedule_id, "active", tenant_id)

  def delete(agent_id, schedule_id, tenant_id) do
    # The kind check needs the row, but the delete carries the ownership
    # predicate itself (atomic, receiver-fenced) — never a global delete.
    with {:ok, _schedule} <- get_owned_schedule(agent_id, schedule_id, tenant_id) do
      case @store.delete_agent_owned(schedule_id, agent_id) do
        :ok -> :ok
        {:error, :not_found} -> {:error, :not_found}
        {:error, _} = err -> err
      end
    end
  end

  defp heartbeat_schedule_id(%{"heartbeat_schedule_id" => schedule_id})
       when is_binary(schedule_id) do
    case String.trim(schedule_id) do
      "" -> {:error, :heartbeat_schedule_id_required}
      schedule_id -> {:ok, schedule_id}
    end
  end

  defp heartbeat_schedule_id(_agent), do: {:error, :heartbeat_schedule_id_required}

  # Create-or-merge for the heartbeat row. Update wins the common path; a
  # concurrent first write is absorbed by retrying through the other branch.
  defp upsert(schedule_id, rec, now_ms, attempts \\ 3)

  defp upsert(_schedule_id, _rec, _now_ms, 0), do: {:error, :conflict}

  defp upsert(schedule_id, rec, now_ms, attempts) do
    merge = fn current ->
      merged =
        current
        |> Map.merge(Map.drop(rec, ["created_at", "last_run"]))
        |> Map.put("id", current["id"] || schedule_id)
        |> Map.put("agent_id", rec["agent_id"])
        |> Map.put("kind", "heartbeat")
        |> Map.put("updated_at", now_ms)

      {:ok, merged, interval_next_fire(merged)}
    end

    case @store.update(schedule_id, merge) do
      {:ok, merged} ->
        {:ok, merged}

      {:error, :not_found} ->
        case @store.create(rec, interval_next_fire(rec)) do
          {:ok, created} -> {:ok, created}
          {:error, :already_exists} -> upsert(schedule_id, rec, now_ms, attempts - 1)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  # Heartbeats are interval rows; their exact next fire needs no cron math.
  defp interval_next_fire(rec) do
    anchor = rec["last_run"] || rec["created_at"] || now_ms()
    anchor + interval_minutes(rec) * 60_000
  end

  defp interval_minutes(%{"interval_minutes" => minutes})
       when is_integer(minutes) and minutes > 0,
       do: minutes

  defp interval_minutes(_rec), do: 720

  defp update_agent_heartbeat_status(agent_id, status, tenant_id) do
    with {:ok, agent} <- Control.get(agent_id, tenant_id),
         {:ok, schedule_id} <- heartbeat_schedule_id(agent),
         {:ok, current} <- @store.get(schedule_id),
         true <- current["kind"] == "heartbeat",
         {:ok, rec} <- @store.set_status(schedule_id, status, now_ms()) do
      {:ok, heartbeat_json(rec)}
    else
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp get_owned_schedule(agent_id, schedule_id, tenant_id) do
    # Ownership (agent-owned AND not a Task row — a Task's owner is its group
    # binding, never an agent) is enforced by the store predicate; only the
    # heartbeat-surface split is decided here.
    with {:ok, _agent} <- Control.get(agent_id, tenant_id),
         {:ok, rec} <- @store.get_agent_owned(schedule_id, agent_id),
         true <- rec["kind"] != "heartbeat" do
      {:ok, Map.put(rec, "id", rec["id"] || schedule_id)}
    else
      false -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp update_agent_schedule_status(agent_id, schedule_id, status, tenant_id) do
    with {:ok, schedule} <- get_owned_schedule(agent_id, schedule_id, tenant_id),
         {:ok, rec} <- @store.set_status(schedule["id"], status, now_ms()) do
      {:ok, schedule_json(rec)}
    end
  end

  defp heartbeat_json(rec) do
    rec
    |> schedule_json()
    |> Map.take([
      "agent_id",
      "schedule_id",
      "prompt",
      "cron_expr",
      "timezone",
      "template_id",
      "reasoning_effort",
      "status",
      "next_run_at",
      "last_run_at",
      "created_at",
      "updated_at"
    ])
    |> put_optional("last_result", nonblank(rec["last_result"]))
    |> put_optional("last_title", nonblank(rec["last_title"]))
    |> put_optional("last_summary", nonblank(rec["last_summary"]))
    |> put_optional("last_error", nonblank(rec["last_error"]))
    |> put_optional("last_session_id", nonblank(rec["last_session_id"]))
    |> put_optional("last_surface_session_id", nonblank(rec["last_surface_session_id"]))
    |> put_optional("last_surface_conversation_id", nonblank(rec["last_surface_conversation_id"]))
  end

  defp schedule_json(rec) do
    created_ms = schedule_ms(rec["created_at"]) || now_ms()
    updated_ms = schedule_ms(rec["updated_at"]) || created_ms
    last_run_ms = schedule_ms(rec["last_run"] || rec["last_run_at"])

    %{
      "schedule_id" => rec["id"] || rec["schedule_id"],
      "agent_id" => rec["agent_id"],
      "name" => rec["name"] || "Schedule",
      "prompt" => rec["prompt"] || "",
      "cron_expr" => rec["cron_expr"] || interval_cron_expr(rec["interval_minutes"]),
      "timezone" => rec["timezone"] || "UTC",
      "status" => rec["status"] || "active",
      "next_run_at" => div(schedule_next_run_ms(rec, created_ms, last_run_ms), 1000),
      "last_run_at" => if(is_integer(last_run_ms), do: div(last_run_ms, 1000), else: nil),
      "created_at" => div(created_ms, 1000),
      "updated_at" => div(updated_ms, 1000)
    }
    |> put_optional("session_id", nonblank(rec["session_id"]))
    |> put_optional("template_id", nonblank(rec["template_id"]))
    |> put_optional("reasoning_effort", nonblank(rec["reasoning_effort"]))
  end

  defp schedule_run_json(schedule, rec) do
    scheduled_ms =
      schedule_ms(rec["scheduled_for_ms"]) ||
        schedule_ms(rec["scheduled_for"]) ||
        schedule_ms(rec["fired_at"]) ||
        now_ms()

    updated_ms = schedule_ms(rec["updated_at"] || rec["fired_at"]) || scheduled_ms
    schedule_id = schedule["id"] || schedule["schedule_id"]
    {disposition_status, disposition_error} = run_disposition_projection(rec["disposition"])

    %{
      "run_id" => rec["run_id"] || schedule_id <> ":" <> Integer.to_string(scheduled_ms),
      "schedule_id" => schedule_id,
      "scheduled_for" => div(scheduled_ms, 1000),
      "status" => rec["status"] || disposition_status,
      # rec's session_id is the CLAIM's frozen target (#871 occurrence
      # authority) and it stays authoritative in the projection: "" is the
      # explicit claimed-session-less sentinel, surfaced as ABSENT — never
      # replaced by the definition's current (possibly retargeted) session,
      # which this run did not deliver to (#874 round 4). Only a legacy
      # pre-migration row with NO recorded target falls back to the
      # mutable definition, mirroring its legacy snapshot dispatch.
      "session_id" => project_claimed_session(rec["session_id"], schedule),
      "error" => rec["error"] || disposition_error,
      "created_at" =>
        div(schedule_ms(rec["created_at"] || rec["fired_at"]) || scheduled_ms, 1000),
      "updated_at" => div(updated_ms, 1000)
    }
  end

  defp project_claimed_session("", _schedule), do: nil
  defp project_claimed_session(sid, _schedule) when is_binary(sid), do: nonblank(sid)
  defp project_claimed_session(_legacy_nil, schedule), do: nonblank(schedule["session_id"])

  # The durable run disposition is the truthful public outcome: an
  # occurrence resolved `undeliverable` must never read as a clean
  # "dispatched" in run history (#871 review — the anchor advanced past it
  # by design, but the record says why).
  defp run_disposition_projection("undeliverable"),
    do: {"undeliverable", "no session id and the target role cannot resolve one"}

  defp run_disposition_projection("skipped_stale"), do: {"skipped", nil}
  defp run_disposition_projection(_dispatch_or_nil), do: {"dispatched", nil}

  defp schedule_next_run_ms(rec, created_ms, last_run_ms) do
    schedule_ms(rec["next_run_at"]) ||
      (last_run_ms || created_ms) + schedule_interval_minutes(rec) * 60_000
  end

  defp schedule_interval_minutes(%{"interval_minutes" => minutes})
       when is_integer(minutes) and minutes > 0,
       do: minutes

  defp schedule_interval_minutes(_rec), do: 720

  defp interval_cron_expr(minutes) when is_integer(minutes) and minutes > 0 and minutes < 60,
    do: "*/#{minutes} * * * *"

  defp interval_cron_expr(minutes) when is_integer(minutes) and rem(minutes, 60) == 0,
    do: "0 */#{div(minutes, 60)} * * *"

  defp interval_cron_expr(_minutes), do: "0 */12 * * *"

  defp schedule_ms(value) when is_integer(value) and value > 9_999_999_999, do: value
  defp schedule_ms(value) when is_integer(value) and value > 0, do: value * 1000

  defp schedule_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> schedule_ms(int)
      _ -> nil
    end
  end

  defp schedule_ms(_value), do: nil

  defp nonblank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp nonblank(_value), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp now_ms, do: System.system_time(:millisecond)
end
