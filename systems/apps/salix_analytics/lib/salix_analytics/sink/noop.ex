defmodule SalixAnalytics.Sink.Noop do
  @moduledoc """
  Acknowledging sink for local/dev billing flows that need ledger charging
  without a ClickHouse typed-usage backend.
  """

  @behaviour SalixAnalytics.Sink

  def enqueue(_rows, _opts), do: :ok

  @impl true
  def insert(rows) when is_list(rows), do: {:ok, length(rows)}
end
