defmodule CommaWeb.RecommendationMemberRead do
  @moduledoc false

  # A member source reads independent relationships: mentions, direct messages,
  # assigned items and so on. Every request carries the source deadline, so a
  # slow request ends before the collector stops the source, and the source
  # keeps what it read. A relationship that could not be read becomes a
  # partial-source warning. Only a missing identity or a source with nothing
  # readable fails.

  alias Comma.RecommendationBudgets

  @doc "The deadline of a source read, keeping a tenth of its budget to assemble results."
  def deadline(timeout_ms \\ RecommendationBudgets.source_read_timeout_ms()),
    do: now() + timeout_ms - div(timeout_ms, 10)

  @doc "Runs one request, returning its result or a deadline error by the deadline."
  def within(deadline, fun) do
    task = SystemsRuntime.Task.async(fun)

    case SystemsClock.yield(task, max(deadline - now(), 0)) ||
           SystemsRuntime.Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
      nil -> {:error, :member_read_deadline}
    end
  end

  @doc """
  Runs one idempotent read by the deadline. A transient failure is retried once
  when the remaining time can hold another attempt of the same length. A
  throttled attempt first waits as long as it took.
  """
  def request(deadline, fun) do
    started = now()

    case within(deadline, fun) do
      {:error, reason} = error ->
        spent = now() - started
        remaining = deadline - now()

        cond do
          not transient?(reason) ->
            error

          throttled?(reason) and remaining > 3 * spent ->
            SystemsClock.sleep(spent)
            within(deadline, fun)

          remaining > 2 * spent ->
            within(deadline, fun)

          true ->
            error
        end

      result ->
        result
    end
  end

  @doc "Maps independent requests concurrently. Each result arrives by its own deadline."
  def map(items, fun, concurrency) do
    items
    |> SystemsClock.async_stream(fun, max_concurrency: concurrency, timeout: :infinity)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  @doc "Adds the first failed relationship to readable data as a partial-source warning."
  def warn(data, []), do: data
  def warn(data, [reason | _]), do: Map.put(data, :source_warnings, [reason])

  # Provider-specific error codes returned over HTTP 2xx/4xx that represent
  # temporary throttling or server faults (Feishu/Lark 99991400 frequency limit,
  # 99991429 rate limit, 99991500/99991503 internal errors; Slack ratelimited).
  @throttled_provider_codes ~w(99991400 99991429 ratelimited)
  @transient_provider_codes ~w(99991400 99991429 99991500 99991503 ratelimited)

  @doc """
  Whether a provider error is likely transient (throttling, server error,
  transport failure or deadline) rather than a permanent permission, missing
  record or malformed answer.
  """
  def transient?({kind, status})
      when kind in [:http, :member_provider_http, :oauth_provider_http] and is_integer(status),
      do: status == 429 or status >= 500

  def transient?({:member_provider_error, code}) when code in @transient_provider_codes, do: true
  def transient?({:transport, _reason}), do: true
  def transient?(:oauth_provider_unavailable), do: true
  def transient?(:member_read_deadline), do: true
  def transient?(_reason), do: false

  defp throttled?({_kind, 429}), do: true
  defp throttled?({:member_provider_error, code}) when code in @throttled_provider_codes, do: true
  defp throttled?(_reason), do: false

  defp now, do: SystemsClock.monotonic_time(:millisecond)
end
