defmodule SalixAgent.AsyncToolResults do
  @moduledoc false

  alias SalixAgent.ToolResultProjection

  @internal_operation_source "async-tool-result"
  @external_operation_source "external-async-tool-result"
  @reader_tool "tool_call.get_result"
  @notification_result_preview_chars 16_000
  @notification_error_message_chars 4_000
  @notification_error_class_chars 256
  @result_response_max_bytes ToolResultProjection.model_envelope_max_bytes()

  def operation_source(:internal), do: @internal_operation_source
  def operation_source(:external), do: @external_operation_source

  @doc false
  def result_response_max_bytes, do: @result_response_max_bytes

  # Modeled in tla/salix/InternalToolCompletionOwner.tla. Internal Round
  # ownership appends a wake; direct poll ownership terminalizes and clears
  # the wait without manufacturing model work.
  def internal_events(pending, result) do
    internal_events(pending, result, [])
  end

  @doc false
  def internal_events(pending, result, opts) when is_list(opts) do
    id = tool_call_id(pending)
    name = tool_name(pending)
    status = status(result)

    notification =
      internal_runtime_notification(
        session_id(pending),
        id,
        name,
        result,
        status,
        pending,
        opts
      )

    internal_terminal_events(pending, result, opts) ++ [notification]
  end

  @doc false
  def internal_terminal_events(pending, result) do
    internal_terminal_events(pending, result, [])
  end

  defp internal_terminal_events(pending, result, opts) do
    status = status(result)

    side_effects(result) ++
      [completion_event(pending, result, status, Keyword.get(opts, :completed_at_ms))]
  end

  @doc false
  def internal_poll_events(pending, result) do
    internal_terminal_events(pending, result) ++
      [wait_clear(session_id(pending), tool_call_id(pending))]
  end

  def external_events(pending, result, message_id \\ nil) do
    id = tool_call_id(pending)
    name = tool_name(pending)
    status = status(result)

    completion = completion_event(pending, result, status)
    summary = completion_summary(status, name, id)
    runtime_message_id = "tool-call-result:" <> id
    source_refs = tool_completion_source_refs(id, name, status, result)

    notification =
      %{
        "type" => "delivery",
        "session_id" => session_id(pending),
        "source_message_id" => runtime_message_id,
        "role" => "runtime",
        "kind" => "runtime_message",
        "runtime_message_id" => runtime_message_id,
        "runtime_message_type" => runtime_message_type(status),
        "source_tool_call_id" => id,
        "summary" => summary,
        "source_refs" => source_refs,
        "content" =>
          SalixAgent.Waits.async_completion_content(
            %{"tool_call_id" => id, "tool_name" => name},
            result
          ),
        "created_at" => System.system_time(:second)
      }
      |> put_optional("visible_reply_origin", field(result, :visible_reply_origin))
      |> put_optional("message_id", message_id)
      |> put_optional("trusted_origin", raw_field(pending, :trusted_origin))
      |> put_optional("trusted_origins", raw_field(pending, :trusted_origins))
      |> put_optional(
        "trusted_origin_source_message_ids",
        raw_field(pending, :trusted_origin_source_message_ids)
      )

    # Modeled in tla/salix/ExternalRuntimeToolWake.tla. External deliveries
    # clear the durable wait when they enter the input queue. Make that same
    # transition explicit so the separately persisted ExternalSessionStatus
    # projection cannot retain the old auto-wait after the connector has
    # consumed this completion and reported `settled`.
    side_effects(result) ++ [completion, wait_clear(session_id(pending)), notification]
  end

  def completion_summary(status, tool_name, tool_call_id) do
    case status do
      "failed" -> "async tool #{tool_name || "tool"} failed for #{tool_call_id}"
      _ -> "async tool #{tool_name || "tool"} completed for #{tool_call_id}"
    end
  end

  def tool_call_id(record), do: field(record, :tool_call_id)
  def tool_name(record), do: field(record, :tool_name)
  def session_id(record), do: field(record, :session_id)

  def status(result), do: if(error?(result), do: "failed", else: "completed")
  defp runtime_message_type("failed"), do: "tool_call_failed"
  defp runtime_message_type(_status), do: "tool_call_completed"

  def side_effects(result) do
    case result[:events] || result["events"] do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp wait_clear(session_id), do: %{"type" => "wait_clear", "session_id" => session_id}

  defp wait_clear(session_id, tool_call_id) do
    wait_clear(session_id)
    |> Map.put("tool_call_id", tool_call_id)
  end

  defp completion_event(pending, result, status, completed_at_ms \\ nil) do
    id = tool_call_id(pending)
    type = if status == "failed", do: "async_tool_call_failed", else: "async_tool_call_completed"
    now = completed_at_ms || System.system_time(:millisecond)

    %{
      "type" => type,
      "session_id" => session_id(pending),
      "tool_call_id" => id,
      "result" => stored_result(result),
      "error" => error?(result),
      "error_class" => result[:error_class] || result["error_class"],
      "error_message" => result[:error_message] || result["error_message"],
      "diagnostic_visibility" =>
        result[:diagnostic_visibility] || result["diagnostic_visibility"],
      "public_summary" => result[:public_summary] || result["public_summary"],
      "visible_reply_origin" =>
        field(result, :visible_reply_origin) || field(pending, :visible_reply_origin),
      "duration_ms" => result[:duration_ms] || result["duration_ms"],
      "completed_at" => now
    }
    |> SalixAgent.ToolCallProvenance.inherit(pending)
  end

  defp internal_runtime_notification(
         session_id,
         tool_call_id,
         tool_name,
         result,
         status,
         pending,
         opts
       ) do
    result_payload = Keyword.get(opts, :notification_result_payload)

    %{
      "type" => "queue_append",
      "session_id" => session_id,
      "kind" => "runtime_message",
      "dedupe_key" => "tool-call-result:" <> tool_call_id,
      "wake" => true,
      "created_at" => Keyword.get(opts, :created_at) || System.system_time(:second),
      "payload" =>
        %{
          "runtime_message_id" => "tool-call-result:" <> tool_call_id,
          "type" => if(status == "failed", do: "tool_call_failed", else: "tool_call_completed"),
          "summary" => completion_summary(status, tool_name, tool_call_id),
          "content" =>
            SalixAgent.Waits.async_completion_content(
              %{"tool_call_id" => tool_call_id, "tool_name" => tool_name},
              result,
              result_payload
            ),
          "source_tool_call_id" => tool_call_id,
          "source_refs" => tool_completion_source_refs(tool_call_id, tool_name, status, result),
          "diagnostic_visibility" => field(result, :diagnostic_visibility),
          "public_summary" => field(result, :public_summary),
          "visible_reply_origin" => field(result, :visible_reply_origin),
          "trusted_origin" => raw_field(pending, :trusted_origin),
          "trusted_origins" => raw_field(pending, :trusted_origins),
          "trusted_origin_source_message_ids" =>
            raw_field(pending, :trusted_origin_source_message_ids)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  defp tool_completion_source_refs(tool_call_id, tool_name, status, result) do
    %{
      "tool_call_id" => tool_call_id,
      "tool_name" => tool_name,
      "status" => status
    }
    |> Map.merge(bounded_error_refs(result))
  end

  @doc false
  def stored_result(result) do
    result
    |> Map.drop([
      :events,
      "events",
      :tool_observations,
      "tool_observations",
      :_tool_result_projection,
      "_tool_result_projection"
    ])
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> drop_duplicate_output()
  end

  @doc false
  def notification_result_payload(result) do
    result_payload(result, 0, @notification_result_preview_chars)
  end

  @doc false
  def notification_result_payload(result, @reader_tool) do
    case direct_reader_page(result) do
      {:ok, page} -> %{"result_page" => page}
      :error -> notification_result_payload(result)
    end
  end

  def notification_result_payload(result, _tool_name),
    do: notification_result_payload(result)

  @doc false
  def result_diagnostic_contract(record) when is_map(record) do
    result = raw_field(record, :result)
    result = if is_map(result), do: result, else: %{}
    failed? = status_value(record) in ["failed", :failed] or error?(record) or error?(result)

    visibility =
      raw_field(record, :diagnostic_visibility) ||
        raw_field(result, :diagnostic_visibility)

    public_summary =
      raw_field(record, :public_summary) || raw_field(result, :public_summary)

    repair_origin? =
      raw_field(record, :visible_reply_origin) == "repair" or
        raw_field(result, :visible_reply_origin) == "repair"

    error_class =
      raw_field(record, :error_class) || raw_field(result, :error_class) ||
        "async_tool_failure"

    cond do
      failed? and visibility == "user_reportable" and present_string(public_summary) != nil ->
        {:user_reportable, to_string(error_class), present_string(public_summary)}

      failed? ->
        {:model_only, to_string(error_class)}

      repair_origin? ->
        {:model_only, "repair_context"}

      true ->
        :none
    end
  end

  def result_diagnostic_contract(_record), do: :none

  @doc false
  def result_payload(result, offset, limit, force_page \\ false)
      when is_integer(offset) and offset >= 0 and is_integer(limit) and limit > 0 do
    encoded = Jason.encode!(result)
    total_chars = String.length(encoded)

    if not force_page and offset == 0 and total_chars <= limit do
      %{"result" => result}
    else
      content = String.slice(encoded, offset, limit)
      content_chars = String.length(content)
      next_offset = offset + content_chars

      %{
        "result_page" =>
          %{
            "encoding" => "json",
            "offset" => offset,
            "content" => content,
            "content_chars" => content_chars,
            "total_chars" => total_chars,
            "truncated" => offset > 0 or next_offset < total_chars
          }
          |> put_optional(
            "next_offset",
            if(next_offset < total_chars, do: next_offset)
          )
      }
    end
  end

  @doc """
  Builds one byte-bounded page over the exact JSON stored for a tool result.

  `offset` and `limit` are Unicode-codepoint coordinates. The returned page can
  therefore be concatenated with later pages without splitting UTF-8, while
  the byte budget is measured over the fully JSON-serialized response (page
  metadata and escaped `content` included).
  """
  def result_page_envelope(record, offset, limit, max_bytes \\ @result_response_max_bytes)
      when is_map(record) and is_integer(offset) and offset >= 0 and is_integer(limit) and
             limit > 0 and is_integer(max_bytes) and max_bytes > 0 do
    result_json = canonical_result_json(record)
    total_chars = canonical_result_chars(record, result_json)
    total_bytes = canonical_result_bytes(record, result_json)
    sha256 = canonical_result_sha256(record, result_json)
    remaining_chars = max(total_chars - offset, 0)
    requested_chars = min(limit, remaining_chars)
    metadata = result_page_metadata(record)

    build = fn content_chars ->
      content = String.slice(result_json, offset, content_chars)
      actual_chars = String.length(content)
      next_offset = offset + actual_chars

      page =
        %{
          "encoding" => "json",
          "offset" => offset,
          "content" => content,
          "content_chars" => actual_chars,
          "total_chars" => total_chars,
          "total_bytes" => total_bytes,
          "sha256" => sha256,
          "truncated" => offset > 0 or next_offset < total_chars
        }
        |> put_optional("result_ref", raw_field(record, :result_ref))
        |> put_optional(
          "next_offset",
          if(next_offset < total_chars, do: next_offset)
        )

      Map.put(metadata, "result_page", page)
    end

    content_chars = largest_fitting_page_chars(build, requested_chars, max_bytes)
    envelope = build.(content_chars)

    if content_chars == 0 and remaining_chars > 0 do
      raise ArgumentError,
            "result page metadata leaves no room for one UTF-8 character within #{max_bytes} bytes"
    end

    envelope
  end

  @doc false
  def canonical_result_json(record) when is_map(record) do
    case raw_field(record, :result_json) do
      result_json when is_binary(result_json) -> result_json
      _ -> Jason.encode!(raw_field(record, :result))
    end
  end

  @doc false
  def bounded_error_refs(result) do
    {error_class, class_truncated?} =
      bounded_text(result[:error_class] || result["error_class"], @notification_error_class_chars)

    {error_message, message_truncated?} =
      bounded_text(
        result[:error_message] || result["error_message"],
        @notification_error_message_chars
      )

    %{
      "error_class" => error_class,
      "error_message" => error_message
    }
    |> put_optional(
      "error_class_truncated",
      if(class_truncated?, do: true)
    )
    |> put_optional(
      "error_message_truncated",
      if(message_truncated?, do: true)
    )
  end

  defp error?(result),
    do: error_value(result) in [true, "true", 1] or status_value(result) in ["failed", :failed]

  defp error_value(result),
    do: result[:error] || result["error"] || result[:is_error] || result["is_error"] || false

  defp status_value(result), do: result[:status] || result["status"]

  defp field(record, key) when is_map(record) do
    value = Map.get(record, key) || Map.get(record, to_string(key))
    if is_nil(value), do: nil, else: to_string(value)
  end

  defp raw_field(record, key) when is_map(record),
    do: Map.get(record, key) || Map.get(record, to_string(key))

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp present_string(_value), do: nil

  defp bounded_text(nil, _limit), do: {nil, false}

  defp bounded_text(value, limit) do
    value = if is_binary(value), do: value, else: inspect(value)
    {String.slice(value, 0, limit), String.length(value) > limit}
  end

  defp drop_duplicate_output(%{"content" => content, "output" => output} = result)
       when content == output,
       do: Map.delete(result, "output")

  defp drop_duplicate_output(result), do: result

  # A reader result already is a page over the canonical stored JSON. Returning
  # it through the ordinary async preview path would page the JSON encoding of
  # that page a second time and hide its result_ref/offset/hash metadata. Keep
  # only the page itself here; the compaction context projection sizes its body
  # against the complete, materialized runtime message sent to the model.
  defp direct_reader_page(result) do
    with content when is_binary(content) <- raw_field(result, :content),
         {:ok, %{"result_page" => page}} when is_map(page) <- Jason.decode(content),
         "json" <- page["encoding"],
         offset when is_integer(offset) and offset >= 0 <- page["offset"],
         page_content when is_binary(page_content) <- page["content"],
         content_chars when is_integer(content_chars) and content_chars >= 0 <-
           page["content_chars"],
         true <- content_chars == String.length(page_content),
         total_chars when is_integer(total_chars) and total_chars >= offset + content_chars <-
           page["total_chars"] do
      {:ok, page}
    else
      _ -> :error
    end
  end

  defp canonical_result_chars(record, result_json) do
    case raw_field(record, :result_chars) do
      value when is_integer(value) and value >= 0 -> value
      _ -> String.length(result_json)
    end
  end

  defp canonical_result_bytes(record, result_json) do
    case raw_field(record, :result_bytes) do
      value when is_integer(value) and value >= 0 -> value
      _ -> byte_size(result_json)
    end
  end

  defp canonical_result_sha256(record, result_json) do
    case raw_field(record, :result_sha256) do
      value when is_binary(value) and byte_size(value) == 64 ->
        String.downcase(value)

      _ ->
        :crypto.hash(:sha256, result_json)
        |> Base.encode16(case: :lower)
    end
  end

  defp result_page_metadata(record) do
    record
    |> Map.take([
      "tool_call_id",
      "tool_name",
      "status",
      "started_at",
      "updated_at",
      "completed_at",
      "cancelled_at",
      "duration_ms",
      "error",
      "is_error"
    ])
    |> Map.merge(bounded_error_refs(record))
  end

  defp largest_fitting_page_chars(build, requested_chars, max_bytes) do
    if encoded_size(build.(requested_chars)) <= max_bytes do
      requested_chars
    else
      unless encoded_size(build.(0)) <= max_bytes do
        raise ArgumentError, "result page metadata exceeds #{max_bytes} bytes"
      end

      largest_fitting_page_chars(build, 0, requested_chars, max_bytes)
    end
  end

  defp largest_fitting_page_chars(_build, low, high, _max_bytes) when high - low <= 1,
    do: low

  defp largest_fitting_page_chars(build, low, high, max_bytes) do
    mid = div(low + high, 2)

    if encoded_size(build.(mid)) <= max_bytes do
      largest_fitting_page_chars(build, mid, high, max_bytes)
    else
      largest_fitting_page_chars(build, low, mid, max_bytes)
    end
  end

  defp encoded_size(value), do: value |> Jason.encode!() |> byte_size()

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
