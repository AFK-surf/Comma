defmodule SalixMeet.MeetingGroupProjectionAuditor do
  @moduledoc """
  Bounded, read-only drift detector for the sealed meeting group projection.

  Each tick checks at most one S3 LIST page and never repairs PostgreSQL. A
  mismatch therefore remains visible until a newly versioned online release
  backfill is deliberately run.
  """

  use GenServer

  require Logger

  alias SalixMeet.Release

  @default_interval_ms 300_000
  @default_page_size 50

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec audit_now(GenServer.server()) :: :ok | {:error, term()}
  def audit_now(server \\ __MODULE__), do: GenServer.call(server, :audit_now)

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      page_size: Keyword.get(opts, :page_size, @default_page_size),
      continuation_token: nil,
      projected_count: 0,
      timer_ref: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:audit_now, _from, state) do
    {result, state} = audit_page(state)
    observe(result)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:audit, state) do
    state = %{state | timer_ref: nil}
    {result, state} = audit_page(state)
    observe(result)
    {:noreply, schedule(state)}
  end

  defp audit_page(state) do
    opts =
      [page_size: state.page_size, projected_count: state.projected_count]
      |> maybe_put_continuation_token(state.continuation_token)

    case Release.audit_group_projection_page(opts) do
      {:ok, page} ->
        next_count = if is_nil(page.continuation_token), do: 0, else: page.projected_count

        {:ok,
         %{
           state
           | continuation_token: page.continuation_token,
             projected_count: next_count
         }}

      {:error, :meeting_source_unsealed} ->
        {:ok, %{state | continuation_token: nil, projected_count: 0}}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp schedule(%{timer_ref: nil, interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    %{state | timer_ref: Process.send_after(self(), :audit, interval_ms)}
  end

  defp maybe_put_continuation_token(opts, nil), do: opts

  defp maybe_put_continuation_token(opts, token),
    do: Keyword.put(opts, :continuation_token, token)

  defp observe(:ok) do
    :telemetry.execute(
      [:salix_meet, :meeting_group_projection, :audit],
      %{drift_count: 0},
      %{outcome: :ok}
    )
  end

  defp observe({:error, reason}) do
    Logger.error("meeting group projection audit detected drift: #{inspect(reason)}")

    :telemetry.execute(
      [:salix_meet, :meeting_group_projection, :audit],
      %{drift_count: 1},
      %{outcome: :error, reason: reason}
    )
  end
end
