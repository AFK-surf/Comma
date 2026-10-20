defmodule SalixAgent.Release do
  @moduledoc """
  Release-native maintenance and inspection entrypoints.

  Durable-state maintenance functions are intended for the exclusive release
  phase or explicit `bin/comma eval` use and start only their documented owner
  boundaries. Inspection and live operator commands do not start applications.
  """

  @spec backfill_session_work(keyword()) :: map()
  def backfill_session_work(opts \\ []) do
    unless Keyword.get(opts, :confirm_no_writers, false) do
      raise "refusing Session work backfill without confirm_no_writers: true"
    end

    ensure_started = Keyword.get(opts, :ensure_started, &Application.ensure_all_started/1)
    {:ok, _} = ensure_started.(:salix_store)

    case SalixAgent.SessionWorkBackfill.run(opts) do
      {:ok, result} -> result
      {:error, reason} -> raise "Session work backfill failed: #{inspect(reason)}"
    end
  end

  @doc "Print a complete system prompt built from the offline emulated configuration."
  @spec dump_system_prompt(keyword()) :: :ok
  def dump_system_prompt(opts \\ []) do
    SalixAgent.SystemPromptDump.print(opts)
  end
end
