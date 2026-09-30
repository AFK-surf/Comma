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

  @doc """
  Run one explicit external Session migration command on the serving release.

  Use `bin/comma rpc`, with agent_id, tenant_id, operation_id and target in attrs.
  `step`, `cancel`, and `repair` each perform one bounded coordinator step.
  Repeat the same operation until complete. `status` reads one page of at most
  100 Sessions; pass its next cursor to inspect another page.

  `archive_unmigratable` is the explicit destructive fallback. It permanently
  archives the Worker before it deletes one exact Session's old
  connected-runtime records, managed workspace, workspace archive, and native
  resume files. It does not delete the Connector root or shared credentials.
  """
  def session_migration("status", %{"agent_id" => agent_id, "tenant_id" => tenant_id} = attrs) do
    with {:ok, agent} <- SalixAgent.AgentControl.get_including_archived(agent_id, tenant_id),
         {:ok, %{records: records, next: next}} <-
           SalixAgent.ExternalSessionStore.migration_page(agent_id, attrs["cursor"]) do
      sessions =
        Enum.map(records, fn record ->
          %{
            session_id: record["session_id"],
            binding: get_in(record, ["runtime", "binding"]),
            migration: record["migration"]
          }
        end)

      {:ok,
       %{
         agent_id: agent_id,
         binding: agent["runtime_config"],
         admission: agent["session_admission"],
         sessions: sessions,
         next: next
       }}
    end
  end

  def session_migration(action, %{
        "agent_id" => agent_id,
        "tenant_id" => tenant_id,
        "operation_id" => operation_id,
        "target" => target
      })
      when action in ~w(step cancel repair) do
    SalixAgent.ExternalSessionMigration.run(agent_id, tenant_id, target, operation_id,
      cancel: action == "cancel",
      repair: action == "repair"
    )
  end

  def session_migration("archive_unmigratable", %{
        "agent_id" => agent_id,
        "tenant_id" => tenant_id,
        "operation_id" => operation_id,
        "source" => source,
        "session_id" => session_id
      }) do
    SalixAgent.ExternalSessionMigration.archive_unmigratable(
      agent_id,
      tenant_id,
      source,
      session_id,
      operation_id
    )
  end

  def session_migration(_, _), do: {:error, :invalid_migration_command}

  @doc "Print a complete system prompt built from the offline emulated configuration."
  @spec dump_system_prompt(keyword()) :: :ok
  def dump_system_prompt(opts \\ []) do
    SalixAgent.SystemPromptDump.print(opts)
  end
end
