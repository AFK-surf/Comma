defmodule SalixAgent.ToolTelemetry do
  @moduledoc false

  require Logger

  @terminal_statuses ~w(completed error guidance cancelled)

  def emit_tool_call(result, attrs) when is_map(result) and is_map(attrs) do
    case terminal_fact(result, attrs) do
      {:ok, fact} -> emit_fact(fact)
      :skip -> :ok
      {:error, _} = error -> error
    end
  rescue
    exception ->
      Logger.warning("tool telemetry build failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("tool telemetry build exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  def emit_fact(fact) when is_map(fact) do
    result = SalixAgent.Observability.tool_call(fact)

    Salix.Telemetry.emit_operation(
      "salix_mcp",
      if(fact.tool_source == "mcp", do: "mcp", else: "tool"),
      fact.surface,
      if(fact.status == "completed", do: "ok", else: "error"),
      System.convert_time_unit(fact.duration_ms || 0, :millisecond, :native)
    )

    result
  rescue
    exception ->
      Logger.warning("tool telemetry emit failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("tool telemetry emit exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  def terminal_fact(result, attrs) when is_map(result) and is_map(attrs) do
    fact = build_tool_call(result, attrs)

    if fact.status in @terminal_statuses do
      {:ok, fact}
    else
      :skip
    end
  rescue
    exception ->
      Logger.warning("tool telemetry build failed: #{Exception.message(exception)}")
      {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason ->
      Logger.warning("tool telemetry build exited: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  def build_tool_call(result, attrs) when is_map(result) and is_map(attrs) do
    billing_context = field(attrs, :billing_context) || %{}
    trace_ctx = field(attrs, :trace_ctx) || %{}
    tool_call_id = text(field(result, :id) || field(attrs, :tool_call_id))
    tool_name = text(field(result, :name) || field(attrs, :tool_name))
    status = status(result)

    %{
      source: "salix_agent.tool",
      source_key: tool_call_id || "tool:" <> random_id(),
      entrypoint: "tool_call",
      surface: nested(attrs, billing_context, :surface) || "unknown",
      tenant_id: field(attrs, :tenant_id) || "unknown",
      group_id: field(attrs, :group_id) || "unknown",
      actor_type: nested(attrs, billing_context, :actor_type) || "tool",
      tool_name: tool_name || "unknown",
      tool_source: tool_source(tool_name),
      status: status,
      error_type: error_type(status, result),
      guidance_reason: guidance_reason(status, result),
      duration_ms: measured_duration_ms(result) || derived_duration_ms(result, attrs),
      started_at: timestamp(field(result, :started_at) || field(attrs, :started_at)),
      metered_at: DateTime.utc_now(),
      args_fingerprint: fingerprint(decoded(field(result, :input) || field(attrs, :args))),
      result_fingerprint: fingerprint(decoded(field(result, :output) || field(result, :content))),
      call_index: int(field(result, :call_index) || field(attrs, :call_index)),
      async: field(attrs, :async) == true,
      trace_id: field(trace_ctx, :trace_id) || field(attrs, :trace_id),
      request_id: field(trace_ctx, :request_id) || field(attrs, :request_id),
      salix_agent_id: field(attrs, :salix_agent_id) || field(attrs, :agent_id),
      session_id: field(attrs, :session_id),
      round_id: field(trace_ctx, :round_id) || field(attrs, :round_id),
      app_revision: field(attrs, :app_revision) || SalixAgent.AppRevision.value(),
      charge_status: "unattributed"
    }
  end

  def fingerprint(nil), do: nil
  def fingerprint(""), do: nil

  def fingerprint(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Repair paths (tool_error_results) stamp a literal duration_ms: 0, which
  # is truthy in Elixir — only a positive measurement counts as measured.
  defp measured_duration_ms(result) do
    case int(field(result, :duration_ms)) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  # Surface/external async completions and DOWN repairs carry no measured
  # duration_ms; derive it from the recorded spawn time so async latency
  # stays real for Q2 instead of coercing to 0 in ClickHouse. attrs carries
  # the authoritative spawn time (pending / session record) when present.
  defp derived_duration_ms(result, attrs) do
    case timestamp(field(attrs, :started_at) || field(result, :started_at)) do
      %DateTime{} = started_at ->
        DateTime.utc_now() |> DateTime.diff(started_at, :millisecond) |> max(0)

      _ ->
        nil
    end
  end

  defp status(result) do
    value = field(result, :status)

    cond do
      value in ["completed", "guidance", "cancelled", "async_running"] -> value
      value in ["failed", "error"] -> "error"
      field(result, :error) in [true, "true", 1] -> "error"
      true -> "completed"
    end
  end

  defp error_type("error", result) do
    case text(field(result, :error_class)) do
      "unknown_tool" -> "unknown_tool"
      "timeout" -> "timeout"
      "crashed" -> "crashed"
      "exception" -> "exception"
      "capped" -> "capped"
      "tool_error" -> "tool_error"
      "vm_" <> _ -> "vm_error"
      nil -> "tool_error"
      _ -> "tool_error"
    end
  end

  defp error_type(_status, _result), do: nil

  defp guidance_reason("guidance", result) do
    output = decoded(field(result, :output) || field(result, :content))

    case text(
           field(result, :guidance_reason) ||
             field(output, :guidance_reason)
         ) do
      value
      when value in ~w(not_callable not_disclosed invalid_params envelope_misuse unauthorized_target) ->
        value

      _ ->
        nil
    end
  end

  defp guidance_reason(_status, _result), do: nil

  defp tool_source(nil), do: "other"
  defp tool_source("mcp." <> _), do: "mcp"
  defp tool_source("skill." <> _), do: "skill"
  defp tool_source("plugin." <> _), do: "plugin"
  defp tool_source("web." <> _), do: "web"
  defp tool_source("im." <> _), do: "im"
  defp tool_source("im_api." <> _), do: "im"
  defp tool_source("tool_call." <> _), do: "async_ops"
  defp tool_source("composio." <> _), do: "composio"

  defp tool_source(name)
       when name in ~w(help fs.write_file fs.read_file fs.list_files fs.delete_file script.run fs.edit_file fs.copy_file fs.move_file fs.grep fs.glob fs.stat_file) do
    "core"
  end

  defp tool_source(_name), do: "other"

  defp decoded(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decoded(value), do: value

  defp canonical_json(%DateTime{} = value), do: value |> DateTime.to_iso8601() |> Jason.encode!()

  defp canonical_json(%NaiveDateTime{} = value),
    do: value |> NaiveDateTime.to_iso8601() |> Jason.encode!()

  defp canonical_json(%Date{} = value), do: value |> Date.to_iso8601() |> Jason.encode!()

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, value} -> {to_string(key), canonical_json(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, encoded} -> Jason.encode!(key) <> ":" <> encoded end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> (value |> Enum.map(&canonical_json/1) |> Enum.join(",")) <> "]"
  end

  defp canonical_json(value) when is_atom(value) and value in [true, false, nil],
    do: Jason.encode!(value)

  defp canonical_json(value) when is_atom(value), do: value |> Atom.to_string() |> Jason.encode!()
  defp canonical_json(value), do: Jason.encode!(value)

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_map, _key), do: nil

  defp nested(attrs, context, key), do: field(attrs, key) || field(context, key)

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_integer(value), do: Integer.to_string(value)
  defp text(_), do: nil

  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp int(_), do: nil

  defp timestamp(%DateTime{} = value), do: value
  defp timestamp(nil), do: nil
  defp timestamp(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)

  defp timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> timestamp(int)
      _ -> value
    end
  end

  defp timestamp(value), do: value

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
