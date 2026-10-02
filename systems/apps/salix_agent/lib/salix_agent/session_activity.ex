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
  def project(%{"runtime_kind" => "external"} = session), do: external(session)
  def project(session) when is_map(session), do: internal(session)

  @doc "Notify subscribers that this session's canonical activity changed."
  @spec notify(String.t(), String.t()) :: :ok
  def notify(agent_id, session_id) when is_binary(agent_id) and is_binary(session_id) do
    Notifier.notify(agent_id, {:session_activity_updated, session_id})
  end

  defp external(session) do
    case value(session, "status") do
      "idle" -> activity(session, "stopped", "")
      "starting" -> activity(session, "active", "is starting...")
      "running" -> activity(session, "active", "is working...")
      "waiting" -> waiting(session)
      "failed" -> error(session, "runtime_failed")
      "unknown" -> error(session, "runtime_status_unknown")
      _other -> error(session, "session_activity_unknown")
    end
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

    message =
      if value(session, "runtime_kind") == "external",
        do: text(value(session, "message")),
        else: ""

    message = if message == "", do: error_text(issue), else: message

    session
    |> activity("error", "error: #{message}")
    |> Map.put("issue", issue)
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

  defp minimal_wait(wait) when is_map(wait) do
    wait
    |> Map.take(["reason"])
    |> put_optional("remaining_seconds", remaining_seconds(wait))
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

  defp error_text("insufficient_credits"), do: "not enough credits; add credits and try again"
  defp error_text("account_inactive"), do: "the billing account is unavailable"
  defp error_text("missing_account"), do: "this operation has no billing account"

  defp error_text("model_connection_failed"), do: "the model could not be reached"

  defp error_text("session_activity_unknown"), do: "session activity is unknown"
  defp error_text(issue), do: String.replace(issue, "_", " ")

  defp remaining_seconds(wait) do
    cond do
      is_integer(value(wait, "remaining_seconds")) ->
        max(value(wait, "remaining_seconds"), 0)

      is_integer(value(wait, "deadline_ms")) ->
        milliseconds_until(value(wait, "deadline_ms"), System.system_time(:millisecond))

      is_integer(value(wait, "deadline_at")) and value(wait, "deadline_at") > 10_000_000_000 ->
        milliseconds_until(value(wait, "deadline_at"), System.system_time(:millisecond))

      is_integer(value(wait, "deadline_at")) ->
        max(value(wait, "deadline_at") - System.system_time(:second), 0)

      true ->
        nil
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
