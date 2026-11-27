defmodule BridgeForTeams.OwnerNotifications.Worker do
  @moduledoc """
  Sends recorded owner notifications. Each tick leases at most `batch` due
  rows (moving their `send_after` forward), so a Pod that dies mid-send hands
  them to the next tick, and sends each one to the swarm's current owners.

  A send that fails is retried after the lease, up to `@max_attempts` times.
  Notifications not sent within a day expire: by then the next day's alert
  has its own row.
  """
  use SystemsRuntime.Server

  import Ecto.Query

  require Logger

  alias BridgeForTeams.{OwnerNotifications, Repo, TeamsMail}
  alias BridgeForTeams.Schema.{Organization, OwnerNotification, Project}

  @default_interval_ms 60_000
  @default_batch 10
  @lease_seconds 300
  @max_attempts 5
  @expire_seconds 86_400

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Send what is due now; returns how many rows it handled."
  @spec run_once(keyword()) :: {:ok, non_neg_integer()}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.timestamp(:utc_datetime_usec))
    expire(now)

    if TeamsMail.configured?() do
      due = lease(now, Keyword.get(opts, :batch, @default_batch))
      Enum.each(due, &deliver(&1, now))
      {:ok, length(due)}
    else
      {:ok, 0}
    end
  end

  defp expire(now) do
    cutoff = DateTime.add(now, -@expire_seconds, :second)

    from(n in OwnerNotification, where: n.status == "pending" and n.created_at < ^cutoff)
    |> Repo.update_all(set: [status: "expired", updated_at: now])
  end

  defp lease(now, batch) do
    ids =
      from(n in OwnerNotification,
        where: n.status == "pending" and n.send_after <= ^now,
        order_by: [asc: n.send_after],
        limit: ^batch,
        lock: "FOR UPDATE SKIP LOCKED",
        select: n.id
      )

    {:ok, leased} =
      Repo.transaction(fn ->
        {_count, rows} =
          from(n in OwnerNotification, where: n.id in subquery(ids), select: n)
          |> Repo.update_all(
            set: [send_after: DateTime.add(now, @lease_seconds, :second), updated_at: now],
            inc: [attempts: 1]
          )

        rows
      end)

    leased
  end

  defp deliver(%OwnerNotification{} = n, now) do
    with %Project{} = project <- Repo.get(Project, n.project_id),
         %Organization{} = org <- Repo.get(Organization, project.org_id),
         [_ | _] = recipients <- OwnerNotifications.owner_emails(project) do
      {subject, body} = OwnerNotifications.render(n, project, org, base_url())

      case TeamsMail.send_email(recipients, subject, body) do
        :ok -> finish(n, "sent", nil, now)
        {:error, reason} -> retry(n, reason, now)
      end
    else
      _no_project_or_owner -> finish(n, "skipped", "no_recipients", now)
    end
  rescue
    exception ->
      Logger.error("bridge_for_teams.owner_notifications.crashed #{Exception.message(exception)}")
      retry(n, :crashed, now)
  end

  defp retry(%OwnerNotification{attempts: attempts} = n, reason, now)
       when attempts >= @max_attempts,
       do: finish(n, "failed", reason_class(reason), now)

  defp retry(%OwnerNotification{} = n, reason, now) do
    from(o in OwnerNotification, where: o.id == ^n.id)
    |> Repo.update_all(set: [last_error: reason_class(reason), updated_at: now])
  end

  defp finish(%OwnerNotification{} = n, status, error, now) do
    from(o in OwnerNotification, where: o.id == ^n.id)
    |> Repo.update_all(
      set: [
        status: status,
        last_error: error,
        sent_at: if(status == "sent", do: now),
        updated_at: now
      ]
    )
  end

  # Errors carry no addresses or content (`SalixStore.Postmark`).
  defp reason_class({:postmark, status, code}), do: "postmark_#{status}_#{code || "unknown"}"
  defp reason_class({:transport, _reason}), do: "transport"
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "unknown"

  defp base_url, do: SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url)

  @impl true
  def init(opts) do
    cfg = SystemsRuntime.get_env(:bridge_for_teams_core, __MODULE__, [])

    interval =
      Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, @default_interval_ms))

    schedule(interval)
    {:ok, %{interval_ms: interval}}
  end

  @impl true
  def handle_info(:deliver, state) do
    try do
      run_once()
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.owner_notifications.worker.failed #{Exception.message(exception)}"
        )
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :deliver, interval_ms)
end
