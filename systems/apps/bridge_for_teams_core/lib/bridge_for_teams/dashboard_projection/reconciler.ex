defmodule BridgeForTeams.DashboardProjection.Reconciler do
  @moduledoc """
  Durable, bounded owner for dashboard projection refresh work.

  PubSub/GenServer messages are only doorbells. PostgreSQL owns the desired
  generation, lease, retry state, and fenced acknowledgement so another Pod
  can resume a lost refresh without allowing a stale worker to commit.
  """
  use GenServer

  require Logger

  alias BridgeForTeams.{DashboardProjection, Repo}

  @name __MODULE__
  @default_interval_ms 30_000
  @default_lease_ms 30_000
  @default_retry_ms 5_000
  @default_backstop_limit 100

  def start_link(opts \\ []) do
    if enabled?(), do: GenServer.start_link(__MODULE__, opts, name: @name), else: :ignore
  end

  def enqueue(project_id) when is_binary(project_id) do
    case request_refresh(project_id) do
      :ok ->
        if Process.whereis(@name), do: GenServer.cast(@name, :drain)
        :ok

      {:error, reason} ->
        Logger.warning(
          "dashboard_projection_enqueue_failed project_id=#{project_id} reason=#{reason_class(reason)}"
        )

        :ok
    end
  end

  @doc "Persist a refresh generation; safe to call from any Pod."
  def request_refresh(project_id, opts \\ []) when is_binary(project_id) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.query(
           """
           INSERT INTO dashboard_projection_refreshes
             (project_id, desired_generation, completed_generation, created_at, updated_at)
           VALUES ($1::text::uuid, 1, 0, now(), now())
           ON CONFLICT (project_id) DO UPDATE
           SET desired_generation = dashboard_projection_refreshes.desired_generation + 1,
               updated_at = now()
           """,
           [project_id]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Claim and execute at most one durable refresh."
  def run_once(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    _ = seed_stale_projects(repo, opts)

    case claim(repo, opts) do
      {:ok, nil} ->
        {:ok, %{claimed: false, refreshed: 0}}

      {:ok, claim} ->
        refresh_claim(repo, claim, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, config(:interval_ms, @default_interval_ms))
    send(self(), :drain)
    {:ok, %{interval_ms: interval_ms, task: nil}}
  end

  @impl true
  def handle_cast(:drain, %{task: nil} = state) do
    {:noreply, start_drain(state)}
  end

  def handle_cast(:drain, state), do: {:noreply, state}

  @impl true
  def handle_info(:drain, %{task: nil} = state), do: {:noreply, start_drain(state)}
  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    log_result(result)
    delay = if match?({:ok, %{claimed: true}}, result), do: 0, else: state.interval_ms
    Process.send_after(self(), :drain, delay)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    Logger.warning("dashboard_projection_refresh_worker_down reason=#{reason_class(reason)}")
    Process.send_after(self(), :drain, state.interval_ms)
    {:noreply, %{state | task: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp start_drain(state) do
    task =
      Task.Supervisor.async_nolink(BridgeForTeams.TaskSupervisor, fn ->
        run_once()
      end)

    %{state | task: task.ref}
  end

  defp seed_stale_projects(repo, opts) do
    limit = Keyword.get(opts, :backstop_limit, config(:backstop_limit, @default_backstop_limit))
    stale_seconds = Keyword.get(opts, :stale_after_seconds, 300)

    repo.query(
      """
      INSERT INTO dashboard_projection_refreshes
        (project_id, desired_generation, completed_generation, created_at, updated_at)
      SELECT p.id, 1, 0, now(), now()
      FROM projects p
      LEFT JOIN project_dashboard_snapshots s ON s.project_id = p.id
      LEFT JOIN dashboard_projection_refreshes r ON r.project_id = p.id
      WHERE p.status <> 'archived' AND p.archived_at IS NULL
        AND (
          s.project_id IS NULL OR s.stale_at IS NOT NULL OR s.refreshed_at IS NULL OR
          s.refreshed_at < now() - ($1::bigint * interval '1 second')
        )
        AND (r.project_id IS NULL OR r.completed_generation >= r.desired_generation)
      ORDER BY p.id
      LIMIT $2
      ON CONFLICT (project_id) DO UPDATE
      SET desired_generation = dashboard_projection_refreshes.completed_generation + 1,
          updated_at = now()
      WHERE dashboard_projection_refreshes.completed_generation >=
            dashboard_projection_refreshes.desired_generation
      """,
      [stale_seconds, limit]
    )
  end

  defp claim(repo, opts) do
    lease_ms = Keyword.get(opts, :lease_ms, config(:lease_ms, @default_lease_ms))
    token = Ecto.UUID.generate()

    repo.transaction(fn ->
      result =
        repo.query!("""
        SELECT r.project_id::text, r.desired_generation
        FROM dashboard_projection_refreshes r
        JOIN projects p ON p.id = r.project_id
        WHERE p.status <> 'archived' AND p.archived_at IS NULL
          AND r.completed_generation < r.desired_generation
          AND (r.next_retry_at IS NULL OR r.next_retry_at <= now())
          AND (r.lease_expires_at IS NULL OR r.lease_expires_at <= now())
        ORDER BY r.updated_at, r.project_id
        FOR UPDATE OF r SKIP LOCKED
        LIMIT 1
        """)

      case result.rows do
        [] ->
          nil

        [[project_id, generation]] ->
          repo.query!(
            """
            UPDATE dashboard_projection_refreshes
            SET lease_token = $2::text::uuid,
                lease_generation = $3,
                lease_expires_at = now() + ($4::bigint * interval '1 millisecond'),
                updated_at = now()
            WHERE project_id = $1::text::uuid
            """,
            [project_id, token, generation, lease_ms]
          )

          %{project_id: project_id, generation: generation, token: token}
      end
    end)
  end

  defp refresh_claim(repo, claim, opts) do
    refresh_fun = Keyword.get(opts, :refresh_fun, &DashboardProjection.refresh_project/2)

    refresh_opts = [
      durable_claim: true,
      refresh_generation: claim.generation,
      commit_guard: fn -> guard_claim(repo, claim) end,
      commit_ack: fn -> acknowledge_claim(repo, claim) end
    ]

    case refresh_fun.(claim.project_id, refresh_opts) do
      {:ok, _snapshot} ->
        {:ok, %{claimed: true, refreshed: 1, project_id: claim.project_id}}

      {:error, reason} ->
        _ = fail_claim(repo, claim, reason, opts)
        {:error, reason}
    end
  rescue
    error ->
      _ = fail_claim(repo, claim, error, opts)
      {:error, {:exception, error}}
  end

  defp guard_claim(repo, claim) do
    case repo.query!(
           """
           SELECT 1
           FROM dashboard_projection_refreshes
           WHERE project_id = $1::text::uuid
             AND lease_token = $2::text::uuid
             AND lease_generation = $3
           FOR UPDATE
           """,
           [claim.project_id, claim.token, claim.generation]
         ).rows do
      [[1]] -> :ok
      [] -> {:error, :stale_dashboard_refresh_claim}
    end
  end

  defp acknowledge_claim(repo, claim) do
    result =
      repo.query!(
        """
        UPDATE dashboard_projection_refreshes
        SET completed_generation = $3,
            lease_token = NULL,
            lease_generation = NULL,
            lease_expires_at = NULL,
            next_retry_at = NULL,
            last_error = NULL,
            updated_at = now()
        WHERE project_id = $1::text::uuid
          AND lease_token = $2::text::uuid
          AND lease_generation = $3
        """,
        [claim.project_id, claim.token, claim.generation]
      )

    if result.num_rows == 1, do: :ok, else: {:error, :stale_dashboard_refresh_claim}
  end

  defp fail_claim(repo, claim, reason, opts) do
    retry_ms = Keyword.get(opts, :retry_ms, config(:retry_ms, @default_retry_ms))

    repo.query(
      """
      UPDATE dashboard_projection_refreshes
      SET lease_token = NULL,
          lease_generation = NULL,
          lease_expires_at = NULL,
          next_retry_at = now() + ($4::bigint * interval '1 millisecond'),
          last_error = $3,
          updated_at = now()
      WHERE project_id = $1::text::uuid AND lease_token = $2::text::uuid
      """,
      [claim.project_id, claim.token, reason_class(reason), retry_ms]
    )
  end

  defp log_result({:ok, %{claimed: false}}), do: :ok

  defp log_result({:ok, %{project_id: project_id}}) do
    Logger.info("dashboard_projection_refresh_ok project_id=#{project_id}")
  end

  defp log_result({:error, reason}) do
    Logger.warning("dashboard_projection_refresh_failed reason=#{reason_class(reason)}")
  end

  defp reason_class({:exception, _detail}), do: "exception"
  defp reason_class({:error, reason}), do: reason_class(reason)
  defp reason_class({reason, _detail}) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(reason) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(%{__struct__: module}) when is_atom(module), do: safe_atom(module)
  defp reason_class(_reason), do: "external_error"

  defp safe_atom(atom), do: atom |> Atom.to_string() |> String.slice(0, 128)

  defp config(key, default) do
    :bridge_for_teams_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp enabled?, do: config(:enabled, true)
end
