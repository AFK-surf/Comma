defmodule ProductAnalytics do
  @moduledoc """
  Shared parts of product analytics export: a bounded attempt and the
  deterministic event UUID. Queueing is `ProductAnalytics.Queue`; delivery is
  `ProductAnalytics.PostHog`. A product owns its events, identities and exporter.
  """

  @doc "Runs one export attempt, bounded to 15 seconds including a peer that never ends a body."
  def attempt(fun) do
    task = SystemsRuntime.Task.async(fn -> safely(fun) end)

    case SystemsRuntime.Task.yield(task, 15_000) ||
           SystemsRuntime.Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :retryable}
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :retryable}
  catch
    _, _ -> {:error, :retryable}
  end

  @doc """
  A deterministic UUID v8 for `key`, a term that names one source fact.
  It is a retry/deduplication key, never an authenticity check.
  """
  def event_uuid(key) do
    <<a::32, b::16, c::12, d::62, _::bitstring>> =
      :crypto.hash(:sha256, :erlang.term_to_binary(key))

    Ecto.UUID.load!(<<a::32, b::16, 8::4, c::12, 2::2, d::62>>)
  end
end
