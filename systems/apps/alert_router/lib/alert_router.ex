defmodule AlertRouter do
  @moduledoc "Comma notification router entrypoint."

  alias AlertRouter.CanonicalEvent

  @spec ingest(CanonicalEvent.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ingest(%CanonicalEvent{} = event, opts \\ []), do: AlertRouter.Ingest.accept(event, opts)
end
