defmodule SalixAgent.SessionActivity do
  @moduledoc """
  Canonical, runtime-independent activity projection for one session.

  `state` is the only display authority: `active` and `error` are visible,
  while `stopped` clears the surface. `status` is presentation text and must
  never be interpreted as a lifecycle enum by consumers.
  """

  alias SalixAgent.Notifier

  @typedoc "One of `active`, `stopped`, or `error`."
  @type state :: String.t()
  @type t :: map()

  @spec project(map()) :: t()
  # A retired Session (`SalixAgent.RetiredSessions`) is read-only history.
  def project(%{"runtime_kind" => "retired"} = session), do: activity(session, "stopped", "")
  def project(session) when is_map(session), do: internal(session)

  @doc "Notify subscribers that this session's canonical activity changed."
  @spec notify(String.t(), String.t()) :: :ok
  def notify(agent_id, session_id) when is_binary(agent_id) and is_binary(session_id) do
    Notifier.notify(agent_id, {:session_activity_updated, session_id})
  end

  defp internal(session) do
    cond do
      value(session, "status") == "failed" or
          value(session, "activity_status") == "failed" ->
        error(session, "runtime_failed")

      is_map(value(session, "wait")) or value(session, "activity_status") == "waiting" ->
        waiting(session)

      value(session, "status") == "active" and
          value(session, "activity_status") in ["thinking", "execution", "messaging"] ->
        activity(session, "active", internal_status(value(session, "activity_status")))

      value(session, "status") == "idle" and
          value(session, "activity_status") == "paused" ->
        activity(session, "stopped", "")

      true ->
        error(session, "session_activity_unknown")
    end
  end

  defp internal_status("thinking"), do: "is thinking..."
  defp internal_status("execution"), do: "is executing a tool..."
  defp internal_status("messaging"), do: "is composing a message..."
  defp internal_status(_status), do: "is working..."

  defp waiting(session) do
    wait = value(session, "wait")
    reason = if is_map(wait), do: text(value(wait, "reason")), else: ""
    status = if reason == "", do: "is waiting...", else: "is waiting: #{reason}"

    session
    |> activity("active", status)
    |> put_optional("wait", minimal_wait(wait))
  end

  defp error(session, default_issue) do
    issue = text(value(session, "issue"))
    issue = if issue == "", do: default_issue, else: issue

    message = error_text(issue)

    session
    |> activity("error", "error: #{message}")
    |> Map.put("issue", issue)
    |> put_optional("issue_detail", issue_detail(issue, session))
  end

  # Structured facts for a funding stop, so clients can name what to fix
  # without parsing `status`: the provider source and Profile behind a
  # member's own key, or when a runtime's own subscription resets.
  defp issue_detail("provider_quota_exhausted", session) do
    funding = value(session, "funding")

    if is_map(funding) do
      %{
        "source" => bounded_text(funding["source"]),
        "profile_id" => bounded_text(funding["profile_id"]),
        "profile_name" => bounded_text(funding["profile_name"])
      }
      |> compact_detail()
    end
  end

  # A Comma-run Agent whose own subscriptions all reached their limit names
  # the one that refills first (`SalixAgent.AccountPool`).
  defp issue_detail("quota_exhausted", %{"funding" => %{} = funding}) do
    reset_at = funding["reset_at"]

    %{
      "source" => bounded_text(funding["source"]),
      "profile_id" => bounded_text(funding["profile_id"]),
      "profile_name" => bounded_text(funding["profile_name"]),
      "reset_at" => if(is_integer(reset_at) and reset_at > 0, do: reset_at)
    }
    |> compact_detail()
  end

  defp issue_detail(issue, session) when issue in ~w(quota_exhausted rate_limited) do
    reset_at = value(session, "reset_at")

    %{
      "source" => bounded_text(value(session, "runtime_provider")),
      "reset_at" => if(is_integer(reset_at) and reset_at > 0, do: reset_at)
    }
    |> compact_detail()
  end

  # A model request failure names what started its round when that was not a
  # person's message: a voice call, or system, provider-system or agent work in
  # the background.
  defp issue_detail("model_connection_failed", session) do
    case value(session, "failure_trigger") do
      trigger when trigger in ["voice_call", "background"] -> %{"trigger" => trigger}
      _other -> nil
    end
  end

  defp issue_detail(_issue, _session), do: nil

  defp bounded_text(value) when is_binary(value) and byte_size(value) <= 200 do
    value = String.trim(value)
    if value == "" or not String.valid?(value), do: nil, else: value
  end

  defp bounded_text(_value), do: nil

  defp compact_detail(detail) do
    detail = detail |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
    if detail == %{}, do: nil, else: detail
  end

  defp activity(session, state, status) do
    %{
      "session_id" => text(value(session, "session_id")),
      "state" => state,
      "status" => status,
      "updated_at" => updated_at(session)
    }
    |> put_optional("version", revision(session))
  end

  # A wait on a running tool call names that tool, and every wait says when it
  # began. Both are runtime facts, never model text.
  defp minimal_wait(wait) when is_map(wait) do
    wait
    |> Map.take(["reason"])
    |> put_optional("remaining_seconds", remaining_seconds(wait))
    |> put_optional("tool_name", wait_tool_name(wait))
    |> put_optional("started_at_ms", started_at_ms(wait))
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  # Waiting is a structured fact even when the runtime supplies no details.
  # Presentation consumers must not parse the localized status text to avoid
  # showing a working/typing animation while the session is actually waiting.
  defp minimal_wait(_wait), do: %{}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp error_text("native_start_unconfirmed"), do: "native start was not confirmed"
  defp error_text("runtime_observation_lost"), do: "runtime observation was lost"
  defp error_text("runtime_status_unknown"), do: "runtime status is unknown"
  defp error_text("runtime_failed"), do: "runtime failed"

  defp error_text("visible_reply_repair_exhausted"),
    do: "the session could not produce a visible reply"

  defp error_text("insufficient_credits"),
    do: "out of Comma credits; add credits, then send again"

  defp error_text("account_inactive"), do: "the billing account is unavailable"
  defp error_text("missing_account"), do: "this operation has no billing account"

  defp error_text("provider_quota_exhausted"),
    do: "your own model provider account or subscription has run out"

  defp error_text("model_connection_failed"), do: "the model request failed"

  defp error_text("session_activity_unknown"), do: "session activity is unknown"
  defp error_text(issue), do: String.replace(issue, "_", " ")

  defp remaining_seconds(wait) do
    cond do
      is_integer(value(wait, "remaining_seconds")) ->
        max(value(wait, "remaining_seconds"), 0)

      is_integer(value(wait, "deadline_ms")) ->
        milliseconds_until(value(wait, "deadline_ms"), SystemsClock.system_time(:millisecond))

      is_integer(value(wait, "deadline_at")) and value(wait, "deadline_at") > 10_000_000_000 ->
        milliseconds_until(value(wait, "deadline_at"), SystemsClock.system_time(:millisecond))

      is_integer(value(wait, "deadline_at")) ->
        max(value(wait, "deadline_at") - SystemsClock.system_time(:second), 0)

      true ->
        nil
    end
  end

  defp wait_tool_name(wait) do
    case value(wait, "tool_name") do
      name when is_binary(name) -> bounded_text(name)
      _other -> nil
    end
  end

  # Waits.build sets the deadline from the moment the wait began.
  defp started_at_ms(wait) do
    with deadline_ms when is_integer(deadline_ms) <- value(wait, "deadline_ms"),
         timeout_seconds when is_integer(timeout_seconds) <- value(wait, "timeout_seconds") do
      deadline_ms - timeout_seconds * 1_000
    else
      _other -> nil
    end
  end

  defp milliseconds_until(deadline, now), do: max(div(deadline - now + 999, 1_000), 0)

  defp updated_at(session) do
    value(session, "activity_status_updated_at") ||
      value(session, "status_updated_at") ||
      value(session, "last_activity_at") || 0
  end

  defp revision(session) do
    case value(session, "activity_revision") do
      revision when is_binary(revision) ->
        case String.trim(revision) do
          "" -> nil
          revision -> revision
        end

      _missing ->
        nil
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_value), do: ""
end
