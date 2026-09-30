defmodule SalixAgent.RoundConfigCache do
  @moduledoc """
  Owner-local configuration snapshots. A refresh is consumed only at a round
  boundary; a slow refresh never blocks a warm round or starts a second task.
  Dynamic activation authority is deliberately not part of this cache.
  """
  require Logger

  defstruct current: nil, task: nil, result: nil, built_at_ms: nil

  @prewarm_timeout_ms 30_000
  @refresh_min_age_ms 2_000

  def begin_round(cache, build) do
    cache = accept_ready(cache)

    case cache.current do
      nil ->
        # A cold boundary joins the prewarm started by the delivery when
        # there is one; otherwise this snapshot is built at the boundary
        # itself. A refresh started in the same instant would read identical
        # inputs; the next boundary starts the first refresh.
        case join_prewarm(cache) do
          {:ok, snapshot, cache} ->
            {:ok, snapshot, cache}

          {:build, cache} ->
            case build.() do
              {:ok, snapshot} -> {:ok, snapshot, install(cache, snapshot)}
              {:error, reason} -> {:error, reason, cache}
            end
        end

      snapshot ->
        {:ok, snapshot, maybe_refresh(cache, build)}
    end
  end

  # A snapshot this young was built from inputs a refresh would read again:
  # a burst of rounds (tool loops, several messages) reuses it. An older one
  # refreshes in the background as before; a committed configuration event
  # still invalidates immediately.
  defp maybe_refresh(%{built_at_ms: built_at} = cache, build) when is_integer(built_at) do
    if now_ms() - built_at < refresh_min_age_ms(),
      do: cache,
      else: refresh(cache, build)
  end

  defp maybe_refresh(cache, build), do: refresh(cache, build)

  defp refresh_min_age_ms do
    case Application.get_env(:salix_agent, :round_config_refresh_min_age_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> @refresh_min_age_ms
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  @doc """
  Starts the first build ahead of the round boundary. A delivery into a cold
  actor calls this right after its commit, so the catalog, skill and plugin
  reads overlap the activation commits instead of following them; the cold
  boundary then joins the task. A warm cache or a build in flight is left
  alone.
  """
  def prewarm(%{current: nil, task: nil, result: nil} = cache, build), do: refresh(cache, build)
  def prewarm(cache, _build), do: cache

  defp join_prewarm(%{task: %Task{} = task} = cache) do
    case Task.yield(task, prewarm_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, snapshot}} ->
        # The prewarm ran for this same delivery: its control reads serve
        # the boundary joining it. A later refresh keeps its reads to itself.
        snapshot = adopt_read_scope(snapshot)
        {:ok, snapshot, install(cache, snapshot)}

      _failed_or_late ->
        # Keep configuration/credentials and provider error details out of logs.
        Logger.warning("round configuration prewarm did not complete; building at the boundary")
        {:build, %{cache | task: nil, result: nil}}
    end
  end

  defp join_prewarm(cache), do: {:build, cache}

  defp prewarm_timeout_ms do
    case Application.get_env(:salix_agent, :round_config_prewarm_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @prewarm_timeout_ms
    end
  end

  @doc """
  Drops the snapshot and any refresh in flight. A refresh that started before
  a static configuration write (a committed skill event) would install the
  old catalog; the next boundary rebuilds from the inputs as committed.
  """
  def invalidate(cache) do
    _ = stop(cache)
    %__MODULE__{}
  end

  def completed(%{task: %Task{ref: ref}} = cache, ref, result) do
    Process.demonitor(ref, [:flush])
    %{cache | result: result}
  end

  def down(%{task: %Task{ref: ref}} = cache, ref, reason),
    do: %{cache | result: {:error, {:refresh_exit, reason}}}

  def stop(%{task: %Task{} = task}), do: Task.shutdown(task, :brutal_kill)
  def stop(_), do: :ok

  defp accept_ready(%{task: %Task{} = task, result: nil} = cache) do
    case Task.yield(task, 0) do
      nil -> cache
      {:ok, result} -> accept_ready(%{cache | result: result})
      {:exit, reason} -> accept_ready(%{cache | result: {:error, {:refresh_exit, reason}}})
    end
  end

  # A result adopted at a boundary this soon after its build (a prewarm the
  # delivery started) still describes this unit of work: the boundary
  # inherits what the build read. An older result keeps its reads to itself.
  defp accept_ready(%{result: {:ok, snapshot}} = cache) do
    snapshot =
      if young?(snapshot), do: adopt_read_scope(snapshot), else: drop_read_scope(snapshot)

    install(cache, snapshot)
  end

  defp accept_ready(%{result: {:error, _}} = cache) do
    # Keep configuration/credentials and provider error details out of logs.
    Logger.warning("round configuration refresh failed; retaining previous snapshot")
    %{cache | task: nil, result: nil}
  end

  defp accept_ready(cache), do: cache

  defp install(cache, snapshot) do
    built_at = if is_map(snapshot), do: snapshot[:built_at_ms], else: nil
    %{cache | current: snapshot, task: nil, result: nil, built_at_ms: built_at || now_ms()}
  end

  defp young?(%{built_at_ms: built_at}) when is_integer(built_at),
    do: now_ms() - built_at < refresh_min_age_ms()

  defp young?(_snapshot), do: false

  defp adopt_read_scope(%{read_scope: read_scope} = snapshot) do
    SalixStore.ReadScope.merge(read_scope)
    Map.delete(snapshot, :read_scope)
  end

  defp adopt_read_scope(snapshot), do: snapshot

  defp drop_read_scope(snapshot) when is_map(snapshot), do: Map.delete(snapshot, :read_scope)
  defp drop_read_scope(snapshot), do: snapshot

  defp refresh(%{task: nil} = cache, build) do
    context = SystemsObservability.Context.capture()

    task =
      Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn ->
        SystemsObservability.Context.run(context, fn ->
          started = System.monotonic_time()

          result =
            SalixStore.ReadScope.run(fn ->
              case build.() do
                {:ok, snapshot} when is_map(snapshot) ->
                  # What the build read (an adopted early build included),
                  # for a boundary that joins it.
                  SalixStore.ReadScope.merge(snapshot[:read_scope])

                  {:ok,
                   snapshot
                   |> Map.put(:read_scope, SalixStore.ReadScope.capture())
                   |> Map.put_new(:built_at_ms, now_ms())}

                other ->
                  other
              end
            end)

          emit_refresh(result, started)
          result
        end)
      end)

    %{cache | task: task}
  end

  defp refresh(cache, _), do: cache

  defp emit_refresh(result, started) do
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "round_config_refresh",
      SystemsObservability.Context.current_surface(),
      outcome,
      System.monotonic_time() - started
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
