defmodule BridgeForTeams.Salix.TenantConfigChecker do
  @moduledoc """
  Background checker that keeps BFT-managed Salix tenant config at target state.

  The checker is intentionally asynchronous: startup creates this actor and the
  actor schedules work after init. Tenant config writes never run in the
  supervision startup callback or in request/Slack runtime paths.
  """

  use GenServer

  require Logger

  alias BridgeForTeams.Observability
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Salix.TenantConfig
  alias BridgeForTeams.Schema.Organization

  import Ecto.Query

  import Bitwise, only: [<<<: 2]

  @initial_delay_ms 1_000
  @ok_interval_ms 300_000
  @retry_interval_ms 30_000
  @max_retry_interval_ms 300_000
  @default_page_size 100
  @default_lease_ms 60_000
  @scan_id "tenant-config"

  defstruct enabled?: true,
            interval_ms: @ok_interval_ms,
            retry_interval_ms: @retry_interval_ms,
            max_retry_interval_ms: @max_retry_interval_ms,
            failure_count: 0,
            status: "pending",
            last_checked_at: nil,
            next_retry_at: nil,
            last_error: nil,
            summary: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, _ -> %{status: "unavailable"}
  end

  @spec ensure_now() :: :ok
  def ensure_now do
    GenServer.cast(__MODULE__, :ensure_now)
  catch
    :exit, _ -> :ok
  end

  @doc "Claim and process one bounded, durable organization page."
  def run_once(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case claim_scan(repo, opts) do
      {:ok, nil} ->
        {:ok, empty_summary(false)}

      {:ok, claim} ->
        run_claimed_page(repo, claim, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    cfg = Application.get_env(:bridge_for_teams_core, __MODULE__, [])
    enabled? = Keyword.get(opts, :enabled, Keyword.get(cfg, :enabled, true))

    state = %__MODULE__{
      enabled?: enabled?,
      status: if(enabled?, do: "pending", else: "disabled"),
      interval_ms:
        Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, @ok_interval_ms)),
      retry_interval_ms:
        Keyword.get(
          opts,
          :retry_interval_ms,
          Keyword.get(cfg, :retry_interval_ms, @retry_interval_ms)
        ),
      max_retry_interval_ms:
        Keyword.get(
          opts,
          :max_retry_interval_ms,
          Keyword.get(cfg, :max_retry_interval_ms, @max_retry_interval_ms)
        )
    }

    if enabled? do
      schedule(
        Keyword.get(
          opts,
          :initial_delay_ms,
          Keyword.get(cfg, :initial_delay_ms, @initial_delay_ms)
        )
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_state(state), state}
  end

  @impl true
  def handle_cast(:ensure_now, state) do
    Process.send(self(), :check_all, [])
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_all, %{enabled?: false} = state), do: {:noreply, state}

  def handle_info(:check_all, state) do
    now = DateTime.utc_now()

    case run_once() do
      {:ok, summary} ->
        failed = Map.get(summary, :failed, [])
        status = if failed == [], do: "ok", else: "failed"
        failure_count = if status == "ok", do: 0, else: state.failure_count + 1

        interval =
          cond do
            status != "ok" -> retry_interval(state, failure_count)
            summary[:wrapped] -> state.interval_ms
            summary[:total] > 0 -> 0
            true -> state.interval_ms
          end

        next_retry_at = DateTime.add(now, interval, :millisecond)

        log_failures(failed)
        schedule(interval)

        {:noreply,
         %{
           state
           | status: status,
             failure_count: failure_count,
             summary: summary,
             last_error: failed_reason(failed),
             last_checked_at: now,
             next_retry_at: next_retry_at
         }}

      {:error, reason} ->
        Logger.warning("tenant config checker failed reason=#{reason_class(reason)}")
        failure_count = state.failure_count + 1
        interval = retry_interval(state, failure_count)
        schedule(interval)

        {:noreply,
         %{
           state
           | status: "failed",
             failure_count: failure_count,
             summary: nil,
             last_error: reason_class(reason),
             last_checked_at: now,
             next_retry_at: DateTime.add(now, interval, :millisecond)
         }}
    end
  end

  defp claim_scan(repo, opts) do
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)
    token = Ecto.UUID.generate()

    repo.transaction(fn ->
      repo.query!(
        """
        INSERT INTO tenant_config_scans (id, generation, created_at, updated_at)
        VALUES ($1, 1, now(), now())
        ON CONFLICT (id) DO NOTHING
        """,
        [@scan_id]
      )

      case repo.query!(
             """
             SELECT cursor_org_id::text, generation
             FROM tenant_config_scans
             WHERE id = $1 AND (lease_expires_at IS NULL OR lease_expires_at <= now())
             FOR UPDATE SKIP LOCKED
             """,
             [@scan_id]
           ).rows do
        [] ->
          nil

        [[cursor_org_id, generation]] ->
          repo.query!(
            """
            UPDATE tenant_config_scans
            SET lease_token = $2::text::uuid,
                lease_expires_at = now() + ($3::bigint * interval '1 millisecond'),
                updated_at = now()
            WHERE id = $1
            """,
            [@scan_id, token, lease_ms]
          )

          %{cursor_org_id: cursor_org_id, generation: generation, token: token}
      end
    end)
  end

  defp run_claimed_page(repo, claim, opts) do
    page_size = Keyword.get(opts, :limit, @default_page_size)
    ensure_fun = Keyword.get(opts, :ensure_fun, &TenantConfig.ensure_org/1)

    organizations =
      Organization
      |> where([org], org.status == "active")
      |> then(fn query ->
        if claim.cursor_org_id do
          where(query, [org], org.id > ^claim.cursor_org_id)
        else
          query
        end
      end)
      |> order_by([org], asc: org.id)
      |> limit(^page_size)
      |> repo.all()

    results = Enum.map(organizations, ensure_fun)
    failed = Enum.filter(results, &(&1.status == "failed"))
    cursor = if organizations == [], do: nil, else: List.last(organizations).id

    case acknowledge_scan(repo, claim, cursor, failed) do
      :ok ->
        {:ok,
         %{
           claimed: true,
           total: length(results),
           ok: Enum.count(results, &(&1.status == "ok")),
           changed: Enum.count(results, &(&1[:changed] == true)),
           skipped: Enum.count(results, &(&1.status == "skipped")),
           failed: failed,
           results: results,
           cursor: cursor,
           wrapped: organizations == []
         }}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      _ = release_scan(repo, claim, error)
      {:error, {:exception, error}}
  catch
    kind, reason ->
      _ = release_scan(repo, claim, {kind, reason})
      {:error, {kind, reason}}
  end

  defp acknowledge_scan(repo, claim, cursor, failed) do
    result =
      repo.query!(
        """
        UPDATE tenant_config_scans
        SET cursor_org_id = $3::text::uuid,
            generation = CASE WHEN $3::text::uuid IS NULL THEN generation + 1 ELSE generation END,
            lease_token = NULL,
            lease_expires_at = NULL,
            last_error = $4,
            updated_at = now()
        WHERE id = $1 AND lease_token = $2::text::uuid AND generation = $5
        """,
        [@scan_id, claim.token, cursor, failed_error(failed), claim.generation]
      )

    if result.num_rows == 1, do: :ok, else: {:error, :stale_tenant_config_scan}
  end

  defp release_scan(repo, claim, reason) do
    repo.query(
      """
      UPDATE tenant_config_scans
      SET lease_token = NULL, lease_expires_at = NULL, last_error = $3, updated_at = now()
      WHERE id = $1 AND lease_token = $2::text::uuid
      """,
      [@scan_id, claim.token, reason_class(reason)]
    )
  end

  defp failed_error([]), do: nil

  defp failed_error(failed), do: error_classes(failed)

  defp empty_summary(claimed) do
    %{
      claimed: claimed,
      total: 0,
      ok: 0,
      changed: 0,
      skipped: 0,
      failed: [],
      results: [],
      cursor: nil,
      wrapped: false
    }
  end

  defp schedule(interval) do
    Process.send_after(self(), :check_all, max(interval, 0))
  end

  defp retry_interval(state, failure_count) do
    multiplier = 1 <<< min(max(failure_count - 1, 0), 5)
    min(state.retry_interval_ms * multiplier, state.max_retry_interval_ms)
  end

  defp public_state(state) do
    %{
      status: state.status,
      last_checked_at: state.last_checked_at,
      next_retry_at: state.next_retry_at,
      last_error: state.last_error,
      summary: state.summary
    }
  end

  defp log_failures([]), do: :ok

  defp log_failures(failed) do
    Logger.warning("tenant config checker found failures reason_classes=#{error_classes(failed)}")
    Enum.each(failed, &record_failure_event/1)
  end

  defp record_failure_event(%{org_id: org_id} = result) when is_binary(org_id) do
    reason = result[:reason]
    reason_class = reason_class(reason)
    tenant_id = result[:tenant_id] || ""

    attrs = %{
      org_id: org_id,
      project_id: nil,
      domain: "org",
      resource_type: "salix_tenant_config",
      resource_id: if(tenant_id == "", do: org_id, else: tenant_id),
      source: "salix.control",
      event_type: "salix.tenant_config.ensure_failed",
      severity: "warning",
      status: "failed",
      reason_class: reason_class,
      summary: "BFT Salix tenant config ensure failed",
      evidence: %{
        org_id: org_id,
        tenant_id: tenant_id,
        config: TenantConfig.conversation_links_config_name(),
        reason_class: reason_class
      },
      correlation_id: "tenant-config:#{org_id}:#{TenantConfig.conversation_links_config_name()}",
      occurred_at: DateTime.utc_now()
    }

    case Observability.create_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "tenant config checker observability failed reason=#{reason_class(reason)}"
        )

        :ok
    end
  end

  defp record_failure_event(_result), do: :ok

  defp reason_class({:exception, _}), do: "exception"
  defp reason_class({:error, reason}), do: reason_class(reason)
  defp reason_class({reason, _detail}) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(reason) when is_atom(reason), do: safe_atom(reason)
  defp reason_class(%{__struct__: module}) when is_atom(module), do: safe_atom(module)
  defp reason_class(_reason), do: "external_error"

  defp safe_atom(atom), do: atom |> Atom.to_string() |> String.slice(0, 128)

  defp error_classes(failed) do
    failed
    |> Enum.map(&reason_class(&1[:reason]))
    |> Enum.uniq()
    |> Enum.join(",")
    |> String.slice(0, 256)
  end

  defp failed_reason([]), do: nil
  defp failed_reason(failed), do: error_classes(failed)
end
