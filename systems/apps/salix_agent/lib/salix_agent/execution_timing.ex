defmodule SalixAgent.ExecutionTiming do
  @moduledoc """
  Observational execution intervals, anchored to epoch milliseconds with a
  measured elapsed duration. Never used for ownership, deadlines or ordering.
  Version 1 distinguishes these measurements from legacy commit-time stamps.
  """

  def start, do: {System.system_time(:millisecond), System.monotonic_time(:millisecond)}

  def finish({epoch, monotonic}, first_token_at \\ nil) do
    finish_at({epoch, monotonic}, System.monotonic_time(:millisecond), first_token_at)
  end

  def finish_at({epoch, monotonic}, completed_at, first_token_at \\ nil) do
    interval(epoch, max(completed_at - monotonic, 0), true)
    |> Map.put("first_token_at_ms", if(first_token_at, do: epoch + first_token_at - monotonic))
  end

  def running(started, first_token_at \\ nil) do
    finish(started, first_token_at) |> Map.put("completed_at_ms", nil)
  end

  def from_tool(result) do
    started = result[:started_at] || result["started_at"]
    duration = result[:duration_ms] || result["duration_ms"]
    status = result[:status] || result["status"]
    terminal = status in ["completed", "success", "error", "failed", "cancelled", "canceled"]

    interval(started, duration, terminal)
  end

  defp interval(started, duration, terminal)
       when is_integer(started) and started >= 1_000_000_000_000 and
              is_integer(duration) and duration >= 0 do
    %{
      "version" => 1,
      "started_at_ms" => started,
      "observed_at_ms" => started + duration,
      "duration_ms" => duration,
      "completed_at_ms" => if(terminal, do: started + duration)
    }
  end

  defp interval(_, _, _), do: nil
end
