defmodule SalixAgent.Waits do
  @moduledoc false

  alias SalixAgent.Tools.AsyncPolicy

  @spec build(String.t(), pos_integer(), String.t(), map()) :: map()
  def build(reason, timeout_seconds, source, extra \\ %{}) do
    timeout_seconds = clamp_timeout(timeout_seconds)
    deadline_ms = System.system_time(:millisecond) + timeout_seconds * 1_000

    %{
      "wait_id" => "wait-" <> random_id(),
      "reason" => String.trim(to_string(reason)),
      "timeout_seconds" => timeout_seconds,
      "deadline_ms" => deadline_ms,
      "source" => source
    }
    |> Map.merge(extra)
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  @doc "Validate the optional durable deadline shared by timer and recovery consumers."
  @spec validate(term()) :: :ok | {:error, :invalid_wait}
  def validate(wait) when is_map(wait) do
    wait = stringify(wait)

    with :ok <- validate_deadline(wait),
         {:ok, _identity} <- identity(wait) do
      :ok
    end
  end

  def validate(_wait), do: {:error, :invalid_wait}

  @spec event(String.t(), map()) :: map()
  def event(session_id, wait) do
    %{"type" => "wait_set", "session_id" => session_id, "wait" => stringify(wait)}
  end

  @spec register_timers_from_events(String.t(), [map()]) :: :ok | {:error, term()}
  def register_timers_from_events(agent_id, events)
      when is_binary(agent_id) and is_list(events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case timer_record(agent_id, event) do
        nil ->
          {:cont, :ok}

        record ->
          case SalixStore.Timers.register(record) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  @spec register_timer_for_wait(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def register_timer_for_wait(agent_id, session_id, wait)
      when is_binary(agent_id) and is_binary(session_id) and is_map(wait) do
    register_timers_from_events(agent_id, [event(session_id, wait)])
  end

  @spec timeout_delivery(String.t(), map()) :: {:ok, map()} | {:error, :invalid_wait}
  def timeout_delivery(session_id, wait) when is_binary(session_id) and is_map(wait) do
    wait = stringify(wait)

    with :ok <- validate(wait),
         {:ok, wait_id} <- identity(wait),
         deadline_ms when is_integer(deadline_ms) and deadline_ms > 0 <- wait["deadline_ms"] do
      source_message_id = timeout_source_message_id(session_id, wait)

      {:ok,
       %{
         "source_message_id" => source_message_id,
         "payload" => %{
           "content" => timeout_content(wait),
           "session_id" => session_id,
           "kind" => "wait_timeout",
           "role" => "runtime",
           "type" => "wait_expired",
           "runtime_message_id" => source_message_id,
           "wait_id" => wait_id,
           "wait" => wait
         }
       }}
    else
      _ -> {:error, :invalid_wait}
    end
  end

  def timeout_delivery(_session_id, _wait), do: {:error, :invalid_wait}

  @doc false
  @spec timeout_source_message_id(String.t(), map()) :: String.t()
  def timeout_source_message_id(session_id, wait)
      when is_binary(session_id) and is_map(wait) do
    wait = stringify(wait)
    {:ok, wait_id} = identity(wait)
    "wait-timeout:#{session_id}:#{wait_id}"
  end

  @doc false
  @spec identity(map()) :: {:ok, String.t()} | {:error, :invalid_wait}
  def identity(wait) when is_map(wait) do
    wait = stringify(wait)

    case wait["wait_id"] do
      wait_id when is_binary(wait_id) ->
        if String.trim(wait_id) == "" do
          {:ok, "fingerprint-#{wait_fingerprint(wait)}"}
        else
          {:ok, wait_id}
        end

      nil ->
        {:ok, "fingerprint-#{wait_fingerprint(wait)}"}

      _other ->
        {:error, :invalid_wait}
    end
  end

  def identity(_wait), do: {:error, :invalid_wait}

  @doc false
  @spec identity_matches?(map(), term()) :: boolean()
  def identity_matches?(wait, candidate) when is_map(wait) and is_binary(candidate) do
    identity(wait) == {:ok, candidate}
  end

  def identity_matches?(_wait, _candidate), do: false

  @spec timeout_content(map()) :: String.t()
  def timeout_content(wait) when is_map(wait) do
    facts = timeout_facts(wait)

    Jason.encode!(%{
      "type" => "wait_expired",
      "wait_id" => facts["wait_id"],
      "reason" => facts["reason"],
      "timeout_seconds" => facts["timeout_seconds"],
      "deadline_ms" => facts["deadline_ms"],
      "elapsed_ms" => facts["elapsed_ms"],
      "overdue_ms" => facts["overdue_ms"],
      "source" => facts["source"],
      "tool_call_id" => facts["tool_call_id"],
      "tool_call_ids" => facts["tool_call_ids"],
      "summary" => "wait timeout reached",
      "message" =>
        "wait timeout reached with no new input; if you still wait for a delegated Task or a running tool, call wait_for again and let its report wake you instead of reading the conversation"
    })
  end

  @doc """
  Consecutive `wait_expired` runtime wakeups at the tail of a transcript,
  counting back from the newest message until any genuine external input
  (a user message, a non-timeout runtime notification other than an outbound
  Message receipt, or any unknown role).
  Assistant/tool turns in between do not break the streak — they are the
  agent's own reaction to the timeout, not new input. This is the
  self-wake-loop measure behind the wait_for activation budget. Completion or
  failure of the agent's own internal.send_message is also its own activity;
  the recipient's reply is the new input. Modeled in tla/salix/WaitBudget.tla.
  """
  @spec consecutive_timeouts([map()]) :: non_neg_integer()
  def consecutive_timeouts(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn msg, count ->
      role = field(msg, :role)

      cond do
        role in ["assistant", "tool"] -> {:cont, count}
        role == "runtime" and field(msg, :type) == "wait_expired" -> {:cont, count + 1}
        role == "runtime" and outbound_message_receipt?(msg) -> {:cont, count}
        true -> {:halt, count}
      end
    end)
  end

  defp outbound_message_receipt?(msg) do
    refs = field(msg, :source_refs) || %{}

    field(msg, :type) in ["tool_call_completed", "tool_call_failed"] and
      field(refs, :tool_name) == "im_api.internal.send_message"
  end

  defp field(msg, key) when is_map(msg), do: msg[key] || msg[Atom.to_string(key)]

  @spec timeout_facts(map()) :: map()
  def timeout_facts(wait) when is_map(wait) do
    wait = stringify(wait)

    wait_id =
      case identity(wait) do
        {:ok, value} -> value
        _ -> nil
      end

    now_ms = System.system_time(:millisecond)
    deadline_ms = wait["deadline_ms"]
    timeout_seconds = wait["timeout_seconds"]

    started_ms =
      cond do
        is_integer(deadline_ms) and is_integer(timeout_seconds) ->
          deadline_ms - timeout_seconds * 1_000

        true ->
          nil
      end

    %{
      "wait_id" => wait_id,
      "reason" => wait["reason"],
      "timeout_seconds" => timeout_seconds,
      "deadline_ms" => deadline_ms,
      "elapsed_ms" => if(is_integer(started_ms), do: max(0, now_ms - started_ms), else: nil),
      "overdue_ms" => if(is_integer(deadline_ms), do: max(0, now_ms - deadline_ms), else: nil),
      "source" => wait["source"],
      "tool_call_id" => wait["tool_call_id"],
      "tool_call_ids" => wait["tool_call_ids"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  @spec async_completion_content(map(), map()) :: String.t()
  def async_completion_content(record, result) do
    async_completion_content(record, result, nil)
  end

  @doc false
  @spec async_completion_content(map(), map(), map() | nil) :: String.t()
  def async_completion_content(record, result, result_payload_override)
      when is_nil(result_payload_override) or is_map(result_payload_override) do
    status = result[:status] || result["status"] || "completed"
    error? = result[:error] || result["error"] || status == "failed"
    type = if error?, do: "tool_call_failed", else: "tool_call_completed"
    tool_call_id = record["tool_call_id"] || record[:tool_call_id]
    tool_name = record["tool_name"] || record[:tool_name]
    stored_result = SalixAgent.AsyncToolResults.stored_result(result)

    result_payload =
      result_payload_override ||
        SalixAgent.AsyncToolResults.notification_result_payload(stored_result, tool_name)

    paged? = Map.has_key?(result_payload, "result_page")
    stored? = result_payload["stored_result"] == true

    message =
      cond do
        stored? and error? ->
          "tool call failed after returning early; the complete result is stored under result_ref; use tool_call.get_result to read it"

        stored? ->
          "tool call completed after returning early; the complete result is stored under result_ref; use tool_call.get_result to read it"

        paged? and error? ->
          "tool call failed after returning early; the error result preview is included as result_page; use tool_call.get_result with next_offset to read the remaining stored result"

        paged? ->
          "tool call completed after returning early; the result preview is included as result_page; use tool_call.get_result with next_offset to read the remaining stored result"

        error? ->
          "tool call failed after returning early; short error details are included in this notification; use the tool call result/status tool only if you need the stored full result or current status"

        true ->
          "tool call completed after returning early; short result is included in this notification; use the tool call result/status tool only if you need the stored full result or current status"
      end

    %{
      "type" => type,
      "tool_call_id" => tool_call_id,
      "tool_name" => tool_name,
      "status" => status,
      "error" => error?,
      "summary" =>
        SalixAgent.AsyncToolResults.completion_summary(status, tool_name, tool_call_id),
      "source_refs" =>
        %{
          "tool_call_id" => tool_call_id,
          "tool_name" => tool_name,
          "status" => status
        }
        |> Map.merge(SalixAgent.AsyncToolResults.bounded_error_refs(result)),
      "message" => message
    }
    |> Map.merge(result_payload)
    |> Jason.encode!()
  end

  defp clamp_timeout(timeout_seconds) when is_integer(timeout_seconds) do
    timeout_seconds
    |> max(1)
    |> min(AsyncPolicy.wait_for_max_seconds())
  end

  defp event_type(event), do: event["type"] || event[:type]

  defp timer_record(agent_id, event) do
    with "wait_set" <- event_type(event),
         session_id when is_binary(session_id) <- event["session_id"] || event[:session_id],
         %{} = wait <- event["wait"] || event[:wait],
         wait <- stringify(wait),
         :ok <- validate(wait),
         {:ok, wait_id} <- identity(wait),
         deadline_ms when is_integer(deadline_ms) and deadline_ms > 0 <- wait["deadline_ms"],
         {:ok, delivery} <- timeout_delivery(session_id, wait) do
      %{
        "timer_id" => wait_id,
        "kind" => "wait_timeout",
        "agent_id" => agent_id,
        "session_id" => session_id,
        "deadline_ms" => deadline_ms,
        "source_message_id" => delivery["source_message_id"],
        "payload" => delivery["payload"]
      }
    else
      _ -> nil
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp validate_deadline(wait) do
    case Map.fetch(wait, "deadline_ms") do
      :error -> :ok
      {:ok, deadline_ms} when is_integer(deadline_ms) and deadline_ms > 0 -> :ok
      {:ok, _deadline_ms} -> {:error, :invalid_wait}
    end
  end

  defp wait_fingerprint(wait) do
    payload =
      :erlang.term_to_binary({
        wait["reason"],
        wait["deadline_ms"],
        wait["timeout_seconds"],
        wait["source"],
        wait["tool_call_id"],
        wait["tool_call_ids"]
      })

    :crypto.hash(:sha256, payload)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp random_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
