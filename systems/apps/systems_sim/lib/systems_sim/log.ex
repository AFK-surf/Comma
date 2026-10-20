defmodule SystemsSim.Log do
  @moduledoc """
  The node's log during a run. The default `:logger` handler hands each
  event to a process outside the world, in a way that depends on that
  process's real-time load (it turns to synchronous calls when it lags), so a
  world that logs would wait on it at real times. During a run this handler
  takes its place: it keeps each event in a table, in the calling process,
  with no message to anyone. `events/0` returns them, oldest first.
  """

  @handler :default
  @table __MODULE__

  @doc false
  # Puts this handler in the default handler's place; returns what restores it.
  def capture do
    saved =
      case :logger.get_handler_config(@handler) do
        {:ok, config} ->
          :ok = :logger.remove_handler(@handler)
          config

        {:error, _not_found} ->
          nil
      end

    if SystemsRuntime.ETS.whereis(@table) == :undefined,
      do: SystemsRuntime.ETS.new(@table, [:named_table, :public, :ordered_set]),
      else: SystemsRuntime.ETS.delete_all_objects(@table)

    :ok =
      :logger.add_handler(@handler, __MODULE__, %{level: :all, filters: [], filter_default: :log})

    saved
  end

  @doc false
  def release(saved) do
    :ok = :logger.remove_handler(@handler)

    if saved do
      %{module: module} = saved
      :ok = :logger.add_handler(@handler, module, Map.drop(saved, [:id, :module]))
    end

    :ok
  end

  @doc "The events logged during the current or last run, oldest first, as text."
  @spec events() :: [String.t()]
  def events do
    if SystemsRuntime.ETS.whereis(@table) == :undefined,
      do: [],
      else: for({_n, line} <- SystemsRuntime.ETS.tab2list(@table), do: line)
  end

  @doc false
  # The `:logger` handler callback; runs in the process that logs.
  def log(%{level: level, msg: msg, meta: meta}, _config) do
    text =
      case msg do
        {:string, chardata} -> IO.chardata_to_string(chardata)
        {:report, report} -> inspect(report)
        {format, args} -> :io_lib.format(format, args) |> IO.chardata_to_string()
      end

    SystemsRuntime.ETS.insert(@table, {System.unique_integer([:monotonic]), "[#{level}] #{text}#{where(meta)}"})
  catch
    _kind, _reason -> :ok
  end

  defp where(%{mfa: {m, f, a}}), do: " (#{inspect(m)}.#{f}/#{a})"
  defp where(_meta), do: ""
end
