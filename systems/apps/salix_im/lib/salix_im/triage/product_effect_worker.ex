defmodule SalixIM.Triage.ProductEffectWorker do
  @moduledoc """
  Bounded multi-Pod executor for native Triage product obligations.

  PostgreSQL partitions claims and fences stale holders. For a Slack reply the
  adapter uses the immutable obligation id as the provider `operation_ref`,
  rechecks source authority immediately before provider I/O, recovers an
  ambiguous result before any resend, and completes the exact thread admission
  after provider confirmation. Retryable local completion failures remain
  pending without reposting; a non-retryable invalid admission contract settles
  the confirmed delivery with explicit degraded-admission metadata. It never
  uses Router Conversation state as an outbox.

  Reactions remain on this worker's durable claim, but use Slack's set-like
  `reactions.add` after an immediate source-freshness check. A lost response is
  verified by Slack's `already_reacted` result before the fenced settlement.

  Protocol anchors: `tla/salix/TriageProductEffect.tla`,
  `tla/salix/TriageReactionEffect.tla`, and
  `tla/salix/TriageContextOutcome.tla`. Separate primary and companion worker
  lanes are modeled in `tla/salix/TriageCompoundCommunication.tla`.
  """

  use GenServer

  require Logger

  alias SalixIM.Triage.DelegationEffect
  alias SalixStore.TriageProductRuntime

  @default_interval_ms 2_000
  @default_batch_size 5
  @default_lease_ms 30_000
  @default_max_attempts 3
  @max_interval_ms 300_000

  def child_spec(opts) do
    id = Keyword.get(opts, :id, __MODULE__)
    %{id: id, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :permanent}
  end

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Executes one bounded batch; exposed for release checks and focused tests."
  def process_once(opts \\ []) when is_list(opts) do
    with {:ok, config} <- normalize_config(opts),
         {:ok, claims} <- config.claim_fun.(config.holder, claim_opts(config)) do
      summary = Enum.reduce(claims, empty_summary(), &process_claim(&1, config, &2))
      {:ok, Map.put(summary, :claimed, length(claims))}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unavailable}
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
        {:ok, config}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:tick, config) do
    case process_once(config.raw_opts) do
      {:ok, _summary} ->
        :ok

      {:error, reason} ->
        Logger.warning("triage product effect batch unavailable reason=#{inspect(reason)}")
    end

    schedule_tick(config.interval_ms)
    {:noreply, config}
  end

  defp process_claim(claim, config, summary) do
    effect =
      claim
      |> invoke_adapter(config)
      |> apply_delegations(claim, config)

    case config.settle_fun.(claim, effect) do
      {:ok, %{status: :duplicate}} -> increment(summary, :duplicates)
      {:ok, %{state: :pending}} -> increment(summary, :retried)
      {:ok, %{state: :applied}} -> increment(summary, :applied)
      {:ok, %{state: :stale}} -> increment(summary, :stale)
      {:ok, %{state: :failed}} -> increment(summary, :failed)
      {:error, _reason} -> increment(summary, :settlement_errors)
      _other -> increment(summary, :settlement_errors)
    end
  end

  defp apply_delegations(%{outcome: :applied} = effect, claim, config) do
    case config.delegation_effect.apply(claim, config.delegation_opts) do
      {:ok, results} ->
        Map.update(effect, :metadata, %{"delegations" => results}, fn metadata ->
          Map.put(metadata, "delegations", results)
        end)

      {:error, reason, retryable?, results} ->
        retry? = retryable? and claim.attempt < config.max_attempts

        %{
          adapter: effect.adapter,
          outcome: :failed,
          external_writes: effect.external_writes,
          communication: effect.communication,
          metadata:
            (effect[:metadata] || %{})
            |> Map.put("delegations", results)
            |> Map.put("delegation_error", safe_reason(reason)),
          error: safe_reason(reason),
          retry: retry?
        }
    end
  end

  defp apply_delegations(effect, _claim, _config), do: effect

  defp invoke_adapter(claim, config) do
    case config.adapter.apply(claim, config.adapter_opts) do
      {:ok, effect} when is_map(effect) ->
        effect

      {:error, reason, retryable?} when is_boolean(retryable?) ->
        failed_effect(claim, config, reason, retryable?)

      {:error, reason, retryable?, external_writes}
      when is_boolean(retryable?) and is_integer(external_writes) and external_writes >= 0 ->
        failed_effect(claim, config, reason, retryable?, external_writes)

      _other ->
        failed_effect(claim, config, :invalid_adapter_result, false)
    end
  rescue
    _exception -> failed_effect(claim, config, :adapter_exception, true)
  catch
    :exit, _reason -> failed_effect(claim, config, :adapter_exit, true)
  end

  defp failed_effect(claim, config, reason, retryable?, external_writes \\ 0) do
    kind = get_in(claim, [:payload, "communication", "kind"])
    retry? = retryable? and claim.attempt < config.max_attempts

    %{
      adapter: adapter_name(config.adapter),
      outcome: :failed,
      external_writes: external_writes,
      communication: %{
        "kind" => if(kind in ["reply", "reaction", "silence"], do: kind, else: "unknown"),
        "status" => if(retry?, do: "retry_scheduled", else: "failed")
      },
      metadata: %{"attempt" => claim.attempt},
      error: safe_reason(reason),
      retry: retry?
    }
  end

  defp normalize_config(opts) do
    adapter = Keyword.get(opts, :adapter, SalixIM.Triage.SlackEffectAdapter)
    holder = Keyword.get(opts, :holder, default_holder())
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    initial_delay_ms = Keyword.get(opts, :initial_delay_ms, interval_ms)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)
    delegation_effect = Keyword.get(opts, :delegation_effect, DelegationEffect)

    claim_fun =
      Keyword.get(opts, :claim_fun, &TriageProductRuntime.claim_obligations/2)

    settle_fun = Keyword.get(opts, :settle_fun, &TriageProductRuntime.settle_claim/2)

    if is_atom(adapter) and Code.ensure_loaded?(adapter) and
         function_exported?(adapter, :apply, 2) and
         is_binary(holder) and holder != "" and byte_size(holder) <= 200 and
         is_integer(interval_ms) and interval_ms in 100..@max_interval_ms and
         is_integer(initial_delay_ms) and initial_delay_ms in 0..@max_interval_ms and
         is_integer(batch_size) and batch_size in 1..50 and
         is_integer(lease_ms) and lease_ms in 1_000..300_000 and
         is_integer(max_attempts) and max_attempts in 1..20 and
         is_atom(delegation_effect) and Code.ensure_loaded?(delegation_effect) and
         function_exported?(delegation_effect, :apply, 2) and
         is_function(claim_fun, 2) and is_function(settle_fun, 2) do
      {:ok,
       %{
         adapter: adapter,
         adapter_opts: Keyword.get(opts, :adapter_opts, []),
         holder: holder,
         interval_ms: interval_ms,
         initial_delay_ms: initial_delay_ms,
         batch_size: batch_size,
         lease_ms: lease_ms,
         max_attempts: max_attempts,
         delegation_effect: delegation_effect,
         delegation_opts: Keyword.get(opts, :delegation_opts, []),
         claim_fun: claim_fun,
         settle_fun: settle_fun,
         raw_opts: opts
       }}
    else
      {:error, :invalid_configuration}
    end
  end

  defp claim_opts(config), do: [limit: config.batch_size, lease_ms: config.lease_ms]

  defp default_holder do
    node_name = node() |> Atom.to_string() |> String.slice(0, 120)
    "#{node_name}:#{System.unique_integer([:positive])}"
  end

  defp adapter_name(SalixIM.Triage.AuditSink), do: :audit_sink
  defp adapter_name(_adapter), do: :slack

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "adapter_unavailable"

  defp empty_summary do
    %{
      claimed: 0,
      applied: 0,
      stale: 0,
      retried: 0,
      failed: 0,
      duplicates: 0,
      settlement_errors: 0
    }
  end

  defp increment(summary, key), do: Map.update!(summary, key, &(&1 + 1))
  defp schedule_tick(delay_ms), do: Process.send_after(self(), :tick, delay_ms)
end
