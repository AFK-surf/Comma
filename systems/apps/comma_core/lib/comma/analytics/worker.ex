defmodule Comma.Analytics.Worker do
  @moduledoc """
  The Comma analytics export queue: one `ProductAnalytics.Queue` per Comma pod,
  exporting through `Comma.Analytics.Export`. Queue loss never changes a
  business result.
  """

  def child_spec(opts) do
    ProductAnalytics.Queue.child_spec(
      Keyword.merge(
        [
          name: __MODULE__,
          export: &Comma.Analytics.Export.entries/1,
          telemetry: [:comma_product, :analytics, :export]
        ],
        opts
      )
    )
  end

  def enqueue(entry), do: ProductAnalytics.Queue.enqueue(__MODULE__, entry)
end
