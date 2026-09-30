defmodule BridgeForTeams.SourcedContext.Processor do
  @moduledoc """
  Versioned interpretation boundary for a frozen sourced-context snapshot.

  Implementations receive only product-owned snapshot data. They cannot move a
  Slack cursor, change source authority, publish context, or mutate Slack. The
  caller records the exact model, prompt, policy, schema, and processor
  configuration evidence separately from the immutable source snapshot.

  `stable_key` is the versioned extraction schema's product-context identity,
  not an import-run-local row key. A processor must emit the same key for the
  same People, Project, Decision, or context concept across runs and collapse
  duplicate evidence within one snapshot. Runtime projection then merges
  repeated active supports by `{kind, stable_key}` while retaining every run's
  immutable provenance and independent rollback boundary.
  """

  @type source_object :: %{
          required(:id) => Ecto.UUID.t(),
          required(:source) => map(),
          required(:payload) => map()
        }

  @type request :: %{
          required(:run_id) => Ecto.UUID.t(),
          required(:agent_id) => String.t(),
          required(:snapshot) => map(),
          required(:objects) => [source_object()],
          required(:evidence) => map(),
          required(:processor_config) => map()
        }

  @type artifact :: %{
          required(:kind) => String.t() | atom(),
          required(:stable_key) => String.t(),
          required(:payload) => map(),
          required(:confidence_millis) => 0..1000,
          required(:source_object_ids) => [Ecto.UUID.t()],
          optional(:mapped_user_id) => Ecto.UUID.t() | nil,
          optional(:mapped_project_id) => Ecto.UUID.t() | nil
        }

  @type result :: %{
          required(:artifacts) => [artifact()],
          optional(:warnings) => map()
        }

  @callback derive(request()) :: {:ok, result()} | {:error, term()}
  @callback prepare_evidence(Ecto.UUID.t(), map()) :: {:ok, map()} | {:error, term()}
  @optional_callbacks prepare_evidence: 2
end
