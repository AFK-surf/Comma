defmodule SalixIM.Triage.ClickHousePatrolWorker do
  @moduledoc """
  Bounded discovery and execution loop for ClickHouse-only ambient Triage.

  Enabled channels are discovered from PostgreSQL, new generations start at
  the current ClickHouse tail, and due cursor claims are fenced by PostgreSQL.
  The worker itself owns no durable queue or retry state.
  """

  use GenServer

  require Logger

  alias SalixIM.Triage.{ClickHousePatrol, ClickHouseReader, Telemetry}
  alias SalixIM.ProviderConnects
  alias SalixStore.{SlackTriageChannels, TriagePatrolCursors, TriagePatrolScanState}

  @default_interval_ms 2_000
  @default_discovery_limit 5
  @default_batch_size 1
  @default_lease_ms 60_000
  @default_failure_backoff_ms 1_000
  @default_overlap_ms 5_000
  @max_interval_ms 300_000

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs one bounded discovery page and one bounded claimed batch."
  def process_once(opts \\ []) when is_list(opts) do
    with {:ok, config} <- normalize_config(opts),
         {:ok, discovery} <- sync_channels(config, Keyword.get(opts, :discovery_cursor)),
         {:ok, claims} <-
           config.cursor_store.claim_due(config.holder,
             limit: config.batch_size,
             lease_ms: config.lease_ms
           ) do
      summary =
        Enum.reduce(claims, empty_summary(), fn claim, summary ->
          process_claim(claim, config, summary)
        end)

      {:ok,
       summary
       |> Map.put(:claimed, length(claims))
       |> Map.merge(discovery)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    case normalize_config(opts) do
      {:ok, config} ->
        schedule_tick(config.initial_delay_ms)

        {:ok,
         %{
           config: config,
           discovery_cursor: nil,
           discovery_sync_errors: 0,
           sync_errors: 0
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    opts = Keyword.put(state.config.raw_opts, :discovery_cursor, state.discovery_cursor)

    {next_cursor, sync_errors, discovery_sync_errors} =
      case process_once(opts) do
        {:ok, summary} ->
          {sync_errors, discovery_sync_errors} = next_sync_error_state(state, summary)
          log_sync_transition(state.sync_errors, sync_errors)
          {summary.discovery_cursor, sync_errors, discovery_sync_errors}

        {:error, reason} ->
          Logger.warning("triage ClickHouse patrol unavailable reason=#{inspect(reason)}")
          {state.discovery_cursor, state.sync_errors, state.discovery_sync_errors}
      end

    schedule_tick(state.config.interval_ms)

    {:noreply,
     %{
       state
       | discovery_cursor: next_cursor,
         discovery_sync_errors: discovery_sync_errors,
         sync_errors: sync_errors
     }}
  end

  defp sync_channels(config, cursor) do
    with {:ok, page} <- config.channel_store.list_enabled_page(cursor, config.discovery_limit) do
      {synced, errors} =
        Enum.reduce(page.channels, {0, 0}, fn channel, {synced, errors} ->
          case sync_channel(channel, config) do
            :ok -> {synced + 1, errors}
            {:error, :slack_triage_authority_ineligible} -> {synced, errors}
            {:error, _reason} -> {synced, errors + 1}
          end
        end)

      {:ok,
       %{
         discovery_cursor: if(page.scan_complete, do: nil, else: page.next_cursor),
         discovery_complete?: page.scan_complete,
         discovered: length(page.channels),
         synced: synced,
         sync_errors: errors
       }}
    end
  end

  defp sync_channel(channel, config) do
    with {:ok, authority} <- current_authority(channel, config),
         {:ok, initial_cursor} <- initial_cursor(channel, authority, config),
         {:ok, _stored} <- config.cursor_store.ensure(channel, authority, initial_cursor) do
      :ok
    end
  end

  defp initial_cursor(channel, authority, config) do
    case config.cursor_store.get(
           channel["tenant_id"],
           channel["group_id"],
           channel["connect_id"],
           channel["channel_id"]
         ) do
      {:ok, current} ->
        if current["channel_generation"] == channel["channel_generation"] and
             current["authority_generation"] == authority["connect_generation"] do
          if TriagePatrolScanState.valid?(current["scan_state"]),
            do: {:ok, current["scan_state"]},
            else: tail_state(authority, config)
        else
          tail_state(authority, config)
        end

      {:error, :not_found} ->
        tail_state(authority, config)

      {:error, _reason} ->
        {:error, :cursor_unavailable}
    end
  end

  defp tail_state(authority, config) do
    with {:ok, tail} <- config.reader.tail(scope(authority)),
         {:ok, state} <- TriagePatrolScanState.initial(tail) do
      {:ok, state}
    end
  end

  defp process_claim(claim, config, summary) do
    with {:ok, authority} <- current_authority(claim, config),
         true <- authority["connect_generation"] == claim.authority_generation,
         {:ok, scan} <-
           config.patrol.scan(authority, claim.scan_state,
             reader: config.reader,
             cursor_revision: claim.revision,
             limit: config.page_limit,
             overlap_ms: config.overlap_ms,
             authority_verifier: fn current ->
               config.provider_connects.verify_slack_triage_authority(current)
             end
           ),
         {:ok, %{status: :settled}} <-
           config.cursor_store.settle(
             claim,
             %{
               scan_state: scan.next_scan_state,
               last_message_ts: progress_slack_ts(scan.next_scan_state),
               has_more?: scan.has_more?,
               created: scan.created,
               duplicate: scan.duplicate,
               ineligible: scan.ineligible
             },
             interval_ms: config.interval_ms,
             catch_up_ms: config.catch_up_ms
           ) do
      Telemetry.emit_clickhouse_batch(:ok, scan)

      summary
      |> increment(:settled)
      |> add(:created, scan.created)
      |> add(:duplicates, scan.duplicate)
      |> add(:ineligible, scan.ineligible)
    else
      false ->
        fail_claim(claim, :slack_triage_authority_stale, config, summary)

      {:error, :slack_triage_authority_ineligible} ->
        case config.cursor_store.deactivate(claim) do
          {:ok, %{status: :inactive}} ->
            Telemetry.emit_clickhouse_batch(:inactive, %{})
            increment(summary, :inactive)

          {:error, _reason} ->
            increment(summary, :settlement_errors)
        end

      {:error, reason} ->
        fail_claim(claim, reason, config, summary)

      _invalid ->
        fail_claim(claim, :patrol_unavailable, config, summary)
    end
  end

  defp fail_claim(claim, reason, config, summary) do
    Telemetry.emit_clickhouse_batch(:error, %{})

    case config.cursor_store.fail(claim, reason, config.failure_backoff_ms) do
      {:ok, _failed} -> increment(summary, :failed)
      {:error, _reason} -> increment(summary, :settlement_errors)
    end
  end

  defp current_authority(subject, config) do
    config.provider_connects.get_slack_triage_authority(
      field(subject, :tenant_id),
      field(subject, :group_id),
      field(subject, :connect_id),
      field(subject, :channel_id)
    )
  end

  defp normalize_config(opts) do
    reader = Keyword.get(opts, :reader, ClickHouseReader.impl())
    channel_store = Keyword.get(opts, :channel_store, SlackTriageChannels)
    cursor_store = Keyword.get(opts, :cursor_store, TriagePatrolCursors)
    provider_connects = Keyword.get(opts, :provider_connects, ProviderConnects)
    patrol = Keyword.get(opts, :patrol, ClickHousePatrol)
    holder = Keyword.get(opts, :holder, default_holder())
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    initial_delay_ms = Keyword.get(opts, :initial_delay_ms, interval_ms)
    catch_up_ms = Keyword.get(opts, :catch_up_ms, 100)
    discovery_limit = Keyword.get(opts, :discovery_limit, @default_discovery_limit)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    page_limit = Keyword.get(opts, :page_limit, 50)
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)
    failure_backoff_ms = Keyword.get(opts, :failure_backoff_ms, @default_failure_backoff_ms)
    overlap_ms = Keyword.get(opts, :overlap_ms, @default_overlap_ms)

    valid? =
      module_exports?(reader, tail: 1, list_changes: 3, latest_states: 2) and
        module_exports?(channel_store, list_enabled_page: 2) and
        module_exports?(cursor_store,
          ensure: 3,
          get: 4,
          claim_due: 2,
          settle: 3,
          fail: 3,
          deactivate: 1
        ) and
        module_exports?(provider_connects,
          get_slack_triage_authority: 4,
          verify_slack_triage_authority: 1
        ) and module_exports?(patrol, scan: 3) and valid_holder?(holder) and
        valid_ms?(interval_ms, 100) and valid_ms?(initial_delay_ms, 0) and
        valid_ms?(catch_up_ms, 0) and valid_ms?(failure_backoff_ms, 100) and
        valid_ms?(overlap_ms, 0) and
        is_integer(discovery_limit) and discovery_limit in 1..200 and
        is_integer(batch_size) and batch_size in 1..50 and
        is_integer(page_limit) and page_limit in 1..200 and
        is_integer(lease_ms) and lease_ms in 1_000..@max_interval_ms

    if valid? do
      {:ok,
       %{
         reader: reader,
         channel_store: channel_store,
         cursor_store: cursor_store,
         provider_connects: provider_connects,
         patrol: patrol,
         holder: holder,
         interval_ms: interval_ms,
         initial_delay_ms: initial_delay_ms,
         catch_up_ms: catch_up_ms,
         discovery_limit: discovery_limit,
         batch_size: batch_size,
         page_limit: page_limit,
         lease_ms: lease_ms,
         overlap_ms: overlap_ms,
         failure_backoff_ms: failure_backoff_ms,
         raw_opts: opts
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp module_exports?(module, exports) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(exports, fn {fun, arity} -> function_exported?(module, fun, arity) end)
  end

  defp module_exports?(_module, _exports), do: false

  defp field(subject, key) when is_map(subject),
    do: Map.get(subject, key) || Map.get(subject, Atom.to_string(key))

  defp scope(authority) do
    %{
      "tenant_id" => authority["tenant_id"],
      "workspace_id" => authority["workspace_id"],
      "channel_id" => authority["approved_channel_id"]
    }
  end

  defp slack_ts(message_ts_us) when is_integer(message_ts_us) and message_ts_us >= 0 do
    seconds = div(message_ts_us, 1_000_000)
    micros = rem(message_ts_us, 1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
    "#{seconds}.#{micros}"
  end

  defp slack_ts(_invalid), do: "0.000000"

  defp progress_slack_ts(scan_state) do
    case TriagePatrolScanState.progress_cursor(scan_state) do
      {:ok, cursor} -> slack_ts(cursor["message_ts_us"])
      {:error, :invalid} -> "0.000000"
    end
  end

  defp default_holder do
    node_name = node() |> Atom.to_string() |> String.slice(0, 120)
    "#{node_name}:#{System.unique_integer([:positive])}"
  end

  defp valid_holder?(holder),
    do:
      is_binary(holder) and holder != "" and holder == String.trim(holder) and
        byte_size(holder) <= 200

  defp valid_ms?(value, min), do: is_integer(value) and value in min..@max_interval_ms

  defp log_sync_transition(0, current) when current > 0 do
    Logger.warning("triage ClickHouse patrol channel sync degraded errors=#{current}")
  end

  defp log_sync_transition(previous, 0) when previous > 0 do
    Logger.info("triage ClickHouse patrol channel sync recovered")
  end

  defp log_sync_transition(_previous, _current), do: :ok

  defp next_sync_error_state(state, summary) do
    discovery_sync_errors = state.discovery_sync_errors + summary.sync_errors

    if summary.discovery_complete? do
      {discovery_sync_errors, 0}
    else
      {max(state.sync_errors, discovery_sync_errors), discovery_sync_errors}
    end
  end

  defp empty_summary do
    %{
      claimed: 0,
      settled: 0,
      failed: 0,
      created: 0,
      inactive: 0,
      duplicates: 0,
      ineligible: 0,
      settlement_errors: 0
    }
  end

  defp increment(summary, key), do: Map.update!(summary, key, &(&1 + 1))
  defp add(summary, key, count), do: Map.update!(summary, key, &(&1 + count))
  defp schedule_tick(delay_ms), do: Process.send_after(self(), :tick, delay_ms)
end
