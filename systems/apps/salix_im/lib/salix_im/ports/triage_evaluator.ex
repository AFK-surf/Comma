defmodule SalixIM.Ports.TriageEvaluator do
  @moduledoc """
  Evaluator seam for an immutable Triage input snapshot.

  Ordinary intake is assigned by Pipeline without invoking this port. Its
  worker-assignment metadata records zero provider requests.

  M1 adapters may return opaque evaluator metadata. Native legacy evaluation
  returns proof v1 for a direct request or v2 for one authorized read followed
  by a final request. Product evaluation returns `comma.triage-model-proof.v3`:
  two requests select and render a contribution; one optional read before
  selection makes three requests. The render phase has no tools.

  The core validates every observed request, frozen input, completed read and
  selected communication/investigation scope before accepting the final product
  decision. Historical v1/v2 records retain their original validation. These
  records are adapter observations, not independent transport attestations.
  The existing 150-second Runtime settlement lease does not cancel an in-flight
  provider request; a late result cannot publish an effect.
  """

  @callback evaluate(map(), keyword()) :: {:ok, map(), map()} | {:error, term()}
end
