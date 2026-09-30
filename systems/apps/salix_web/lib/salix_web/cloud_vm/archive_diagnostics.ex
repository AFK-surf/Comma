defmodule SalixWeb.CloudVM.ArchiveDiagnostics do
  @moduledoc "Bounded, best-effort archive observations. These are not recovery checkpoints."

  alias SalixStore.Compute
  @limit 8
  @measurements ~w(total_ms pack_ms put_ms_sum encoder_wait_ms get_ms_sum decoder_wait_ms download_ms extract_ms salix_duration_ms bytes parts)
  @outcomes ~w(ok error cancelled)
  @connector_outcomes ~w(starting exported restored failed cancelled)

  def observe(group, operation, direction, details)
      when is_binary(operation) and byte_size(operation) in 1..128 and
             direction in ["export", "restore"] and is_map(details) do
    record =
      Map.take(details, @measurements)
      |> Map.filter(fn {_key, value} ->
        is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807
      end)
      |> Map.merge(%{
        "operation" => operation,
        "direction" => direction,
        "observed_at" => System.system_time(:millisecond)
      })
      |> put_outcome(details, "outcome", @outcomes)
      |> put_outcome(details, "connector_outcome", @connector_outcomes)

    Task.Supervisor.start_child(SalixWeb.CloudVM.ArchiveDiagnosticsSupervisor, fn ->
      persist(group, record)
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def observe(_, _, _, _), do: :ok

  def list(group) do
    with {:ok, record} <- Compute.group_workload(group),
         do: {:ok, record["archive_diagnostics"] || []}
  end

  defp put_outcome(record, details, key, allowed) do
    if details[key] in allowed, do: Map.put(record, key, details[key]), else: record
  end

  defp persist(group, record) do
    Compute.update_group_workload(group, fn current ->
      records = current["archive_diagnostics"] || []

      {matching, others} =
        Enum.split_with(
          records,
          &(&1["operation"] == record["operation"] and &1["direction"] == record["direction"])
        )

      previous = List.first(matching) || %{}

      merged =
        if (previous["observed_at"] || 0) > record["observed_at"],
          do: Map.merge(record, previous),
          else: Map.merge(previous, record)

      records = [merged | others] |> Enum.sort_by(& &1["observed_at"], :desc) |> Enum.take(@limit)
      Map.put(current, "archive_diagnostics", records)
    end)

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
