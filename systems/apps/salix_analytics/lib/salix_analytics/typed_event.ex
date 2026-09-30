defmodule SalixAnalytics.TypedEvent do
  @moduledoc false

  @required_common ~w(source source_key entrypoint surface tenant_id group_id actor_type resource_kind)a

  def build(resource_kind, attrs, resource_fields) do
    attrs = atomize(attrs)

    attrs
    |> Map.merge(%{
      resource_kind: to_string(resource_kind),
      event_date: date(attrs[:metered_at] || attrs[:started_at] || attrs[:created_at]),
      metered_at: timestamp(attrs[:metered_at] || attrs[:started_at] || attrs[:created_at]),
      created_at: timestamp(attrs[:created_at]),
      version: attrs[:version] || 1,
      source: attrs[:source] || "metering"
    })
    |> Map.merge(resource_fields)
    |> require_common!()
    |> stringify()
  end

  def atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {known_key(key), value}
      {key, value} -> {key, value}
    end)
  end

  def stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp require_common!(row) do
    required =
      if row[:charge_status] == "unattributed" do
        @required_common
      else
        [:billing_account_id | @required_common]
      end

    missing =
      Enum.reject(required, fn key ->
        value = row[key]
        not is_nil(value) and value != ""
      end)

    if missing == [] do
      row
    else
      raise ArgumentError,
            "missing typed usage fields: #{Enum.join(Enum.map(missing, &to_string/1), ", ")}"
    end
  end

  defp normalize(%Date{} = date), do: Date.to_iso8601(date)
  defp normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp normalize(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp normalize(value), do: value

  # event_date is the UTC calendar date of the fact's instant. Deriving it
  # from the zone-local date (or the first ten characters of an offset
  # timestamp string) put rows near midnight into the wrong partition/day:
  # `2026-07-09T17:30:00-07:00` is 2026-07-10 in UTC, and readers prune the
  # v2 tables by `event_date` against UTC windows.
  defp date(nil), do: Date.utc_today() |> Date.to_iso8601()

  defp date(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date() |> Date.to_iso8601()

  defp date(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.to_date() |> Date.to_iso8601()

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      # from_iso8601 already normalizes the instant to UTC.
      {:ok, dt, _offset} -> dt |> DateTime.to_date() |> Date.to_iso8601()
      _ -> String.slice(value, 0, 10)
    end
  end

  defp date(_), do: Date.utc_today() |> Date.to_iso8601()

  defp timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp timestamp(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp known_key(key) do
    case key do
      "activation_key" -> :activation_key
      "actor_type" -> :actor_type
      "app_revision" -> :app_revision
      "args_fingerprint" -> :args_fingerprint
      "async" -> :async
      "attempt" -> :attempt
      "attempts" -> :attempts
      "max_attempts" -> :max_attempts
      "outcome" -> :outcome
      "category" -> :category
      "reason" -> :reason
      "delay_ms" -> :delay_ms
      "billing_account_id" -> :billing_account_id
      "bytes" -> :bytes
      "cache_age_ms" -> :cache_age_ms
      "cache_hit" -> :cache_hit
      "cache_read_input_tokens" -> :cache_read_input_tokens
      "cache_ttl_ms" -> :cache_ttl_ms
      "cache_write_input_tokens" -> :cache_write_input_tokens
      "call_index" -> :call_index
      "charge_status" -> :charge_status
      "completion_tokens" -> :completion_tokens
      "created_at" -> :created_at
      "duration_ms" -> :duration_ms
      "entrypoint" -> :entrypoint
      "error_type" -> :error_type
      "entitlement_mode" -> :entitlement_mode
      "event_date" -> :event_date
      "usage_reported" -> :usage_reported
      "prompt_tokens_reported" -> :prompt_tokens_reported
      "completion_tokens_reported" -> :completion_tokens_reported
      "cache_read_tokens_reported" -> :cache_read_tokens_reported
      "reasoning_tokens" -> :reasoning_tokens
      "first_token_ms" -> :first_token_ms
      "first_body_ms" -> :first_body_ms
      "last_body_ms" -> :last_body_ms
      "received_bytes" -> :received_bytes
      "received_chunks" -> :received_chunks
      "first_content_ms" -> :first_content_ms
      "last_content_ms" -> :last_content_ms
      "content_deltas" -> :content_deltas
      "guidance_reason" -> :guidance_reason
      "phase" -> :phase
      "group_id" -> :group_id
      "http_status" -> :http_status
      "metered_at" -> :metered_at
      "model" -> :model
      "object_count" -> :object_count
      "platform" -> :platform
      "prefix" -> :prefix
      "product_owner_id" -> :product_owner_id
      "product_owner_type" -> :product_owner_type
      "prompt_tokens" -> :prompt_tokens
      "provider" -> :provider
      "quality" -> :quality
      "query_duration_ms" -> :query_duration_ms
      "query_performed" -> :query_performed
      "request_id" -> :request_id
      "resource_kind" -> :resource_kind
      "response_kind" -> :response_kind
      "result_fingerprint" -> :result_fingerprint
      "round_id" -> :round_id
      "salix_agent_id" -> :salix_agent_id
      "session_id" -> :session_id
      "sample_window_seconds" -> :sample_window_seconds
      "sku" -> :sku
      "source" -> :source
      "source_key" -> :source_key
      "source_schedule_id" -> :source_schedule_id
      "started_at" -> :started_at
      "status" -> :status
      "storage_tier" -> :storage_tier
      "surface" -> :surface
      "task_origin" -> :task_origin
      "tenant_id" -> :tenant_id
      "total_tokens" -> :total_tokens
      "tool_name" -> :tool_name
      "tool_source" -> :tool_source
      "trace_id" -> :trace_id
      "version" -> :version
      "would_block" -> :would_block
      "would_exceed" -> :would_exceed
      _ -> key
    end
  end
end
