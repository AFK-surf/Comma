defmodule SalixIM.Ports.TriageContext do
  @moduledoc """
  Read-only M2 port that freezes Slack context, Team/Project Memory projections,
  and the fresh answered recheck for one sealed Triage input.

  The adapter returns product facts and source references. It has no delivery,
  Worker, or Memory-write authority.
  """

  @type frozen_context :: %{String.t() => term()}

  @callback freeze(input_snapshot :: map(), opts :: keyword()) ::
              {:ok, frozen_context()} | {:error, term()}
end
