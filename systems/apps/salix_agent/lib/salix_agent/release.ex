defmodule SalixAgent.Release do
  @moduledoc """
  Release-native maintenance and inspection entrypoints.

  Durable-state maintenance functions are intended for the exclusive release
  phase or explicit `bin/comma eval` use and start only their documented owner
  boundaries. Inspection and live operator commands do not start applications.
  """

  @spec backfill_session_work(keyword()) :: map()
  # Published release migrations retain this call. The retired discovery
  # projection has no writer and this no-op does not mint a completion marker.
  def backfill_session_work(_opts \\ []), do: %{retired: true}

  @doc "Inspect one bounded S source page. No import progress or data is written."
  def inventory_pg_authority(cursor \\ nil, opts \\ []) do
    SalixStore.PGAuthorityImport.with_dependencies(fn ->
      SalixAgent.PGImport.inventory(cursor, opts)
    end)
  end

  @doc "Import bounded S pages after the release runner has stopped all old S writers."
  def import_pg_authority(opts \\ []) do
    unless Keyword.get(opts, :confirm_no_writers, false),
      do: raise(ArgumentError, "PG authority import requires confirm_no_writers: true")

    SalixStore.PGAuthorityImport.with_dependencies(fn -> SalixAgent.PGImport.run(opts) end)
  end

  @doc "Print a complete system prompt built from the offline emulated configuration."
  @spec dump_system_prompt(keyword()) :: :ok
  def dump_system_prompt(opts \\ []) do
    SalixAgent.SystemPromptDump.print(opts)
  end
end
