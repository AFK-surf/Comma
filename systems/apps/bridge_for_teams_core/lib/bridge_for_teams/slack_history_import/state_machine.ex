defmodule BridgeForTeams.SlackHistoryImport.StateMachine do
  @moduledoc """
  Pure transition kernel for bounded Slack-history onboarding.

  Durable BFT repositories, the read-only Salix page adapter, and sourced
  context publication call this kernel while preserving immutable source
  identity, generation checks, and transactional commit/cancel/rollback.

  A Slack connection authorizes acquisition only. Once a complete source
  snapshot exists, disconnecting Slack does not revoke, hide, or delete the
  product-owned context derived from that snapshot. Reconnect creates a new
  run pinned to a fresh connect generation; it never rebinds the old run.

  The bidirectional protocol anchor is `tla/salix/SlackHistoryImport.tla`.
  """

  @cancellable_states [
    :created,
    :acquiring,
    :paused,
    :stale_source,
    :acquired,
    :deriving,
    :preview_ready
  ]

  @failable_states [:created, :acquiring, :paused, :stale_source, :acquired, :deriving]
  @frozen_snapshot_states [:acquired, :deriving, :preview_ready, :committed, :rolled_back]
  @refreshable_states [
    :stale_source,
    :acquired,
    :deriving,
    :preview_ready,
    :committed,
    :rolled_back
  ]

  defmodule Run do
    @moduledoc false

    @enforce_keys [:id, :connect_id, :connect_generation, :source_workspace_id]
    defstruct [
      :id,
      :connect_id,
      :connect_generation,
      :source_workspace_id,
      :replaces_run_id,
      :resume_phase,
      :paused_reason,
      :retry_not_before,
      :snapshot_id,
      :derivation_id,
      :review_revision_id,
      :publication_id,
      :commit_base_generation,
      :failure_reason,
      state: :created,
      generation: 0,
      command_receipts: %{}
    ]

    @type state ::
            :created
            | :acquiring
            | :paused
            | :stale_source
            | :acquired
            | :deriving
            | :preview_ready
            | :committed
            | :canceled
            | :rolled_back
            | :failed_terminal

    @type t :: %__MODULE__{
            id: String.t(),
            connect_id: String.t(),
            connect_generation: String.t(),
            source_workspace_id: String.t(),
            replaces_run_id: String.t() | nil,
            state: state(),
            generation: non_neg_integer(),
            resume_phase: :acquiring | :deriving | nil,
            paused_reason: atom() | nil,
            retry_not_before: DateTime.t() | nil,
            snapshot_id: String.t() | nil,
            derivation_id: String.t() | nil,
            review_revision_id: String.t() | nil,
            publication_id: String.t() | nil,
            commit_base_generation: non_neg_integer() | nil,
            failure_reason: atom() | nil,
            command_receipts: %{optional(String.t()) => map()}
          }
  end

  @storage_states %{
    "created" => :created,
    "acquiring" => :acquiring,
    "paused" => :paused,
    "stale_source" => :stale_source,
    "acquired" => :acquired,
    "deriving" => :deriving,
    "preview_ready" => :preview_ready,
    "committed" => :committed,
    "canceled" => :canceled,
    "rolled_back" => :rolled_back,
    "failed_terminal" => :failed_terminal
  }

  @doc false
  @spec state_from_storage!(String.t()) :: Run.state()
  def state_from_storage!(state), do: Map.fetch!(@storage_states, state)

  @spec new(String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def new(id, opts) do
    with :ok <- reject_replacement_option(opts),
         {:ok, id} <- require_non_empty_binary(id, :invalid_run_id),
         {:ok, connect_id} <-
           fetch_non_empty_option(opts, :connect_id, :invalid_connect_id),
         {:ok, connect_generation} <-
           fetch_non_empty_option(opts, :connect_generation, :invalid_connect_generation),
         {:ok, source_workspace_id} <-
           fetch_non_empty_option(opts, :source_workspace_id, :invalid_source_workspace_id) do
      {:ok, build_run(id, connect_id, connect_generation, source_workspace_id, nil)}
    end
  end

  @doc """
  Creates a fresh run after Slack reconnects to the same workspace.

  No source, snapshot, derivation, review, publication, or command receipt is
  copied. A different workspace is a different source and must start an
  unrelated run instead of using this replacement path.
  """
  @spec restart_after_reconnect(Run.t(), String.t(), keyword()) ::
          {:ok, Run.t(), map()} | {:error, term()}
  # TLA+ anchors: Reconnect and CreateReplacementRun.
  def restart_after_reconnect(%Run{} = old_run, new_run_id, opts) do
    with :ok <- check_reconnectable(old_run),
         {:ok, new_run_id} <- require_non_empty_binary(new_run_id, :invalid_run_id),
         {:ok, new_connect_id} <-
           fetch_non_empty_option(opts, :connect_id, :invalid_connect_id),
         {:ok, new_connect_generation} <-
           fetch_non_empty_option(opts, :connect_generation, :invalid_connect_generation),
         {:ok, source_workspace_id} <-
           fetch_non_empty_option(opts, :source_workspace_id, :invalid_source_workspace_id),
         :ok <- check_distinct_run_id(old_run, new_run_id),
         :ok <- check_workspace(old_run, source_workspace_id),
         :ok <- check_fresh_connect_generation(old_run, new_connect_generation) do
      run =
        build_run(
          new_run_id,
          new_connect_id,
          new_connect_generation,
          source_workspace_id,
          old_run.id
        )

      {:ok, run,
       %{
         command: :restart_after_reconnect,
         replaces_run_id: old_run.id,
         old_connect_generation: old_run.connect_generation,
         new_connect_generation: new_connect_generation
       }}
    end
  end

  @spec start_acquisition(Run.t(), non_neg_integer()) :: transition_result()
  # TLA+ anchor: StartAcquisition.
  def start_acquisition(%Run{} = run, expected_generation) do
    transition(run, expected_generation, :start_acquisition, [:created], :acquiring)
  end

  @spec complete_acquisition(Run.t(), non_neg_integer(), String.t()) :: transition_result()
  # TLA+ anchor: FinalizeSnapshot. Durable page/checkpoint acceptance lives in
  # BridgeForTeams.SourcedContext.Acquisition.
  def complete_acquisition(%Run{} = run, expected_generation, snapshot_id) do
    transition_with_identity(
      run,
      expected_generation,
      :complete_acquisition,
      [:acquiring],
      :acquired,
      :snapshot_id,
      snapshot_id,
      :invalid_snapshot_id
    )
  end

  @doc """
  Records that acquisition authority disappeared.

  Before a snapshot is complete, the old run becomes stale and cannot resume.
  After a snapshot is complete, the event is deliberately a no-op: derivation,
  preview, commit, and already committed context are independent of connection
  liveness.
  """
  @spec source_disconnected(Run.t(), non_neg_integer()) :: transition_result()
  # TLA+ anchor: Disconnect.
  def source_disconnected(%Run{} = run, expected_generation) do
    with :ok <- check_generation(run, expected_generation) do
      source_disconnect_effect(run)
    end
  end

  @spec start_derivation(Run.t(), non_neg_integer(), String.t()) :: transition_result()
  # TLA+ anchor: BeginDerivation.
  def start_derivation(%Run{} = run, expected_generation, derivation_id) do
    with :ok <- check_generation(run, expected_generation),
         :ok <- check_state(run, [:acquired, :preview_ready], :start_derivation),
         {:ok, derivation_id} <-
           require_non_empty_binary(derivation_id, :invalid_derivation_id) do
      finish_transition(
        run,
        :start_derivation,
        :deriving,
        &%{
          &1
          | derivation_id: derivation_id,
            review_revision_id: nil
        }
      )
    end
  end

  @spec complete_derivation(Run.t(), non_neg_integer(), String.t()) :: transition_result()
  # TLA+ anchor: FinishDerivation.
  def complete_derivation(%Run{} = run, expected_generation, review_revision_id) do
    transition_with_identity(
      run,
      expected_generation,
      :complete_derivation,
      [:deriving],
      :preview_ready,
      :review_revision_id,
      review_revision_id,
      :invalid_review_revision_id
    )
  end

  @spec revise_preview(Run.t(), non_neg_integer(), String.t()) :: transition_result()
  # TLA+ anchor: RevisePreview.
  def revise_preview(%Run{} = run, expected_generation, review_revision_id) do
    transition_with_identity(
      run,
      expected_generation,
      :revise_preview,
      [:preview_ready],
      :preview_ready,
      :review_revision_id,
      review_revision_id,
      :invalid_review_revision_id
    )
  end

  @spec pause(Run.t(), non_neg_integer(), atom(), DateTime.t() | nil) :: transition_result()
  # TLA+ anchors: PauseAcquisition and PauseDerivation.
  def pause(%Run{} = run, expected_generation, :source_disconnected, _retry_not_before) do
    source_disconnected(run, expected_generation)
  end

  def pause(%Run{} = run, expected_generation, reason, retry_not_before) do
    transition(
      run,
      expected_generation,
      :pause,
      [:acquiring, :deriving],
      :paused,
      &%{
        &1
        | resume_phase: run.state,
          paused_reason: reason,
          retry_not_before: retry_not_before
      }
    )
  end

  @spec resume(Run.t(), non_neg_integer()) :: transition_result()
  # TLA+ anchors: ResumeAcquisition and ResumeDerivation.
  def resume(
        %Run{resume_phase: :acquiring, paused_reason: :source_disconnected} = run,
        expected_generation
      ) do
    with :ok <- check_generation(run, expected_generation) do
      {:error, :source_generation_retired}
    end
  end

  def resume(%Run{resume_phase: resume_phase} = run, expected_generation)
      when resume_phase in [:acquiring, :deriving] do
    transition(
      run,
      expected_generation,
      :resume,
      [:paused],
      resume_phase,
      &%{&1 | resume_phase: nil, paused_reason: nil, retry_not_before: nil}
    )
  end

  def resume(%Run{} = run, expected_generation) do
    with :ok <- check_generation(run, expected_generation) do
      {:error, {:invalid_transition, run.state, :resume}}
    end
  end

  @spec fail_terminal(Run.t(), non_neg_integer(), atom()) :: transition_result()
  def fail_terminal(%Run{} = run, expected_generation, reason) do
    transition(
      run,
      expected_generation,
      :fail_terminal,
      @failable_states,
      :failed_terminal,
      &%{&1 | failure_reason: reason}
    )
  end

  @spec commit(Run.t(), non_neg_integer(), String.t(), map()) :: command_result()
  # TLA+ anchor: CommitTransaction. A durable adapter must make this one DB transaction.
  def commit(%Run{} = run, expected_generation, command_id, evidence) do
    with :miss <- receipt(run, command_id, :committed),
         :ok <- check_generation(run, expected_generation),
         :ok <- check_state(run, [:preview_ready], :commit),
         :ok <- check_preview_evidence(run, evidence),
         :ok <- check_authorization(evidence),
         :ok <- check_confirmation(evidence),
         {:ok, publication_id} <- fetch_non_empty_binary(evidence, :publication_id) do
      receipt = %{kind: :committed, command_id: command_id, publication_id: publication_id}

      run =
        run
        |> advance(:committed)
        |> Map.put(:publication_id, publication_id)
        |> Map.put(:commit_base_generation, expected_generation)
        |> put_receipt(command_id, receipt)

      {:ok, run, receipt}
    else
      {:replay, receipt} -> {:ok, run, Map.put(receipt, :replayed?, true)}
      error -> error
    end
  end

  @spec cancel(Run.t(), non_neg_integer(), String.t()) :: command_result()
  # TLA+ anchors: CancelIntent and LateCancelRollback.
  def cancel(%Run{} = run, expected_generation, command_id) do
    with :miss <- receipt(run, command_id, [:canceled, :rolled_back_after_late_cancel]),
         :ok <- check_cancel_generation(run, expected_generation),
         {:ok, next_state, kind} <- cancel_effect(run) do
      receipt = %{kind: kind, command_id: command_id}

      run =
        run
        |> advance(next_state)
        |> put_receipt(command_id, receipt)

      {:ok, run, receipt}
    else
      {:replay, receipt} -> {:ok, run, Map.put(receipt, :replayed?, true)}
      error -> error
    end
  end

  @spec rollback(Run.t(), non_neg_integer(), String.t()) :: command_result()
  # TLA+ anchor: RollbackTransaction. A durable adapter must make this one DB transaction.
  def rollback(%Run{} = run, expected_generation, command_id) do
    with :miss <- receipt(run, command_id, :rolled_back),
         :ok <- check_generation(run, expected_generation),
         :ok <- check_state(run, [:committed], :rollback) do
      receipt = %{kind: :rolled_back, command_id: command_id}

      run =
        run
        |> advance(:rolled_back)
        |> put_receipt(command_id, receipt)

      {:ok, run, receipt}
    else
      {:replay, receipt} -> {:ok, run, Map.put(receipt, :replayed?, true)}
      error -> error
    end
  end

  @spec effective_visible?(Run.t(), boolean()) :: boolean()
  # TLA+ anchor: EffectiveVisible. Slack connection state is intentionally absent.
  def effective_visible?(%Run{} = run, audience_authorized?) do
    run.state == :committed and non_empty_binary?(run.publication_id) and audience_authorized?
  end

  @type transition_result :: {:ok, Run.t(), map()} | {:error, term()}
  @type command_result :: {:ok, Run.t(), map()} | {:error, term()}

  defp source_disconnect_effect(%Run{state: :created} = run) do
    finish_transition(
      run,
      :source_disconnected,
      :stale_source,
      &%{
        &1
        | resume_phase: :acquiring,
          paused_reason: :source_disconnected,
          retry_not_before: nil
      }
    )
  end

  defp source_disconnect_effect(%Run{state: :acquiring} = run) do
    finish_transition(
      run,
      :source_disconnected,
      :stale_source,
      &%{
        &1
        | resume_phase: :acquiring,
          paused_reason: :source_disconnected,
          retry_not_before: nil
      }
    )
  end

  defp source_disconnect_effect(%Run{state: :paused, resume_phase: :acquiring} = run) do
    finish_transition(
      run,
      :source_disconnected,
      :stale_source,
      &%{
        &1
        | paused_reason: :source_disconnected,
          retry_not_before: nil
      }
    )
  end

  defp source_disconnect_effect(%Run{state: state} = run)
       when state in @frozen_snapshot_states or
              (state == :paused and run.resume_phase == :deriving) do
    {:ok, run, %{command: :source_disconnected, effect: :frozen_snapshot_unchanged}}
  end

  defp source_disconnect_effect(%Run{} = run) do
    {:ok, run, %{command: :source_disconnected, effect: :terminal_state_unchanged}}
  end

  defp transition(run, expected_generation, command, from_states, to_state, mutate \\ & &1) do
    with :ok <- check_generation(run, expected_generation),
         :ok <- check_state(run, from_states, command) do
      finish_transition(run, command, to_state, mutate)
    end
  end

  defp transition_with_identity(
         run,
         expected_generation,
         command,
         from_states,
         to_state,
         field,
         value,
         error
       ) do
    with :ok <- check_generation(run, expected_generation),
         :ok <- check_state(run, from_states, command),
         {:ok, value} <- require_non_empty_binary(value, error) do
      finish_transition(run, command, to_state, &Map.put(&1, field, value))
    end
  end

  defp finish_transition(run, command, to_state, mutate) do
    from_state = run.state
    from_generation = run.generation

    run =
      run
      |> mutate.()
      |> advance(to_state)

    {:ok, run,
     %{
       command: command,
       from: from_state,
       to: to_state,
       from_generation: from_generation,
       to_generation: run.generation
     }}
  end

  defp advance(run, state), do: %{run | state: state, generation: run.generation + 1}

  defp check_generation(%Run{generation: generation}, generation), do: :ok
  defp check_generation(%Run{}, _expected_generation), do: {:error, :stale_run_generation}

  defp check_state(%Run{state: state}, allowed_states, command) do
    if state in allowed_states,
      do: :ok,
      else: {:error, {:invalid_transition, state, command}}
  end

  defp check_reconnectable(%Run{state: state}) when state in @refreshable_states, do: :ok

  defp check_reconnectable(%Run{state: :paused, resume_phase: :deriving}), do: :ok

  defp check_reconnectable(%Run{}), do: {:error, :run_not_waiting_for_reconnect}

  defp check_distinct_run_id(%Run{id: id}, id), do: {:error, :replacement_run_id_reused}
  defp check_distinct_run_id(%Run{}, _new_run_id), do: :ok

  defp check_workspace(%Run{source_workspace_id: source_workspace_id}, source_workspace_id),
    do: :ok

  defp check_workspace(%Run{}, _source_workspace_id), do: {:error, :source_workspace_mismatch}

  defp check_fresh_connect_generation(
         %Run{connect_generation: connect_generation},
         connect_generation
       ),
       do: {:error, :connect_generation_not_advanced}

  defp check_fresh_connect_generation(%Run{}, _connect_generation), do: :ok

  defp check_preview_evidence(run, evidence) do
    with {:ok, snapshot_id} <- require_non_empty_binary(run.snapshot_id, :invalid_snapshot_id),
         {:ok, derivation_id} <-
           require_non_empty_binary(run.derivation_id, :invalid_derivation_id),
         {:ok, review_revision_id} <-
           require_non_empty_binary(run.review_revision_id, :invalid_review_revision_id) do
      expected = {snapshot_id, derivation_id, review_revision_id}

      actual =
        {Map.get(evidence, :snapshot_id), Map.get(evidence, :derivation_id),
         Map.get(evidence, :review_revision_id)}

      if expected == actual, do: :ok, else: {:error, :preview_evidence_mismatch}
    end
  end

  defp check_authorization(%{actor_authorized?: true, publication_scope_validated?: true}),
    do: :ok

  defp check_authorization(%{actor_authorized?: false}), do: {:error, :actor_unauthorized}
  defp check_authorization(_evidence), do: {:error, :publication_scope_invalid}

  defp check_confirmation(%{confirmed?: true}), do: :ok
  defp check_confirmation(_evidence), do: {:error, :explicit_confirmation_required}

  defp check_cancel_generation(%Run{state: :committed} = run, expected_generation) do
    if run.commit_base_generation == expected_generation,
      do: :ok,
      else: {:error, :stale_run_generation}
  end

  defp check_cancel_generation(run, expected_generation),
    do: check_generation(run, expected_generation)

  defp cancel_effect(%Run{state: state}) when state in @cancellable_states,
    do: {:ok, :canceled, :canceled}

  defp cancel_effect(%Run{state: :committed}),
    do: {:ok, :rolled_back, :rolled_back_after_late_cancel}

  defp cancel_effect(%Run{state: state}),
    do: {:error, {:invalid_transition, state, :cancel}}

  defp receipt(%Run{} = run, command_id, expected_kinds) do
    expected_kinds = List.wrap(expected_kinds)

    case Map.fetch(run.command_receipts, command_id) do
      {:ok, %{kind: kind} = receipt} ->
        if kind in expected_kinds,
          do: {:replay, receipt},
          else: {:error, :command_id_conflict}

      :error ->
        :miss
    end
  end

  defp put_receipt(run, command_id, receipt) do
    %{run | command_receipts: Map.put(run.command_receipts, command_id, receipt)}
  end

  defp fetch_non_empty_binary(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, :invalid_publication_id}
    end
  end

  defp fetch_non_empty_option(opts, key, error) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> require_non_empty_binary(value, error)
      :error -> {:error, error}
    end
  end

  defp reject_replacement_option(opts) do
    if Keyword.has_key?(opts, :replaces_run_id),
      do: {:error, :replacement_requires_reconnect},
      else: :ok
  end

  defp build_run(id, connect_id, connect_generation, source_workspace_id, replaces_run_id) do
    %Run{
      id: id,
      connect_id: connect_id,
      connect_generation: connect_generation,
      source_workspace_id: source_workspace_id,
      replaces_run_id: replaces_run_id
    }
  end

  defp require_non_empty_binary(value, _error) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp require_non_empty_binary(_value, error), do: {:error, error}

  defp non_empty_binary?(value), do: is_binary(value) and byte_size(value) > 0
end
