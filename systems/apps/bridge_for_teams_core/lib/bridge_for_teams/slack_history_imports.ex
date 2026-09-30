defmodule BridgeForTeams.SlackHistoryImports do
  @moduledoc """
  Durable BFT owner for bounded Slack-history import runs.

  A run's workspace, connection generation, selected channels, and absolute
  time range are immutable. Slack connection liveness owns acquisition only;
  reconnect creates a separate run instead of rebinding this record.
  """

  import Ecto.Query

  alias BridgeForTeams.{ContextLifecycle, Memberships, Repo}
  alias BridgeForTeams.SlackHistoryImport.StateMachine

  alias BridgeForTeams.Schema.{
    Organization,
    Project,
    SlackHistoryImportChannel,
    SlackHistoryImportCommandReceipt,
    SlackHistoryImportRun,
    SourcedContextSnapshot
  }

  @max_selected_channels 100

  @spec create_run(map()) :: {:ok, SlackHistoryImportRun.t()} | {:error, term()}
  def create_run(attrs) when is_map(attrs) do
    run_attrs = create_attrs(attrs)

    with :ok <- feature_enabled(:discovery),
         :ok <- reject_replacement(attrs),
         {:ok, channels} <- normalize_channels(value(attrs, :selected_channels)),
         :ok <- validate_run_attrs(run_attrs),
         :ok <- validate_scope(run_attrs) do
      case Repo.transaction(fn -> persist_run(run_attrs, channels) end) do
        {:ok, %SlackHistoryImportRun{} = run} -> {:ok, run}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def create_run(_attrs), do: {:error, :invalid_run}

  @spec get_run(Ecto.UUID.t()) :: {:ok, SlackHistoryImportRun.t()} | {:error, :not_found}
  def get_run(id) do
    case Repo.get(SlackHistoryImportRun, id) do
      nil -> {:error, :not_found}
      run -> {:ok, preload_channels(run)}
    end
  end

  @doc "Read one idempotent creation result without re-contacting its source."
  @spec get_run_by_request(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, SlackHistoryImportRun.t()} | {:error, :not_found | :invalid_request_id}
  def get_run_by_request(org_id, user_id, client_request_id) do
    with {:ok, org_id} <- cast_uuid(org_id),
         {:ok, user_id} <- cast_uuid(user_id),
         {:ok, client_request_id} <- cast_uuid(client_request_id) do
      case Repo.get_by(SlackHistoryImportRun,
             org_id: org_id,
             requested_by_user_id: user_id,
             client_request_id: client_request_id
           ) do
        nil -> {:error, :not_found}
        run -> {:ok, preload_channels(run)}
      end
    else
      :error -> {:error, :invalid_request_id}
    end
  end

  @spec start_acquisition(Ecto.UUID.t(), non_neg_integer()) :: transition_result()
  def start_acquisition(run_id, expected_generation) do
    with :ok <- feature_enabled(:acquisition) do
      transition_run(run_id, &StateMachine.start_acquisition(&1, expected_generation))
    end
  end

  @spec complete_acquisition(Ecto.UUID.t(), non_neg_integer(), Ecto.UUID.t()) ::
          transition_result()
  def complete_acquisition(run_id, expected_generation, snapshot_id) do
    with :ok <- feature_enabled(:acquisition) do
      transition_run(
        run_id,
        fn run ->
          if snapshot_belongs_to_run?(snapshot_id, run.id) do
            StateMachine.complete_acquisition(run, expected_generation, snapshot_id)
          else
            {:error, :snapshot_not_found}
          end
        end
      )
    end
  end

  @spec source_disconnected(Ecto.UUID.t(), non_neg_integer()) :: transition_result()
  def source_disconnected(run_id, expected_generation) do
    transition_run(run_id, &StateMachine.source_disconnected(&1, expected_generation))
  end

  @spec pause(Ecto.UUID.t(), non_neg_integer(), atom(), DateTime.t() | nil) ::
          transition_result()
  def pause(run_id, expected_generation, reason, retry_not_before)
      when reason in [
             :rate_limited,
             :provider_unavailable,
             :processor_unavailable,
             :bound_reached
           ] do
    transition_run(
      run_id,
      &StateMachine.pause(&1, expected_generation, reason, retry_not_before)
    )
  end

  def pause(_run_id, _expected_generation, _reason, _retry_not_before),
    do: {:error, :invalid_pause_reason}

  @doc "Persist a classified non-retryable import failure without requiring an enabled read path."
  @spec fail_terminal(Ecto.UUID.t(), non_neg_integer(), atom()) :: transition_result()
  def fail_terminal(run_id, expected_generation, reason) when is_atom(reason) do
    transition_run(run_id, &StateMachine.fail_terminal(&1, expected_generation, reason))
  end

  @spec resume(Ecto.UUID.t(), non_neg_integer()) :: transition_result()
  def resume(run_id, expected_generation) do
    with :ok <- feature_enabled(:acquisition) do
      transition_run(run_id, fn run ->
        with :ok <- retry_window_open?(run) do
          StateMachine.resume(run, expected_generation)
        end
      end)
    end
  end

  @spec restart_after_reconnect(Ecto.UUID.t(), map()) ::
          {:ok, SlackHistoryImportRun.t(), map()} | {:error, term()}
  def restart_after_reconnect(old_run_id, attrs) when is_map(attrs) do
    with :ok <- feature_enabled(:discovery),
         {:ok, channels} <- normalize_channels(value(attrs, :selected_channels)) do
      case Repo.transaction(fn -> persist_replacement(old_run_id, attrs, channels) end) do
        {:ok, {%SlackHistoryImportRun{} = run, event}} -> {:ok, run, event}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def restart_after_reconnect(_old_run_id, _attrs), do: {:error, :invalid_run}

  @type transition_result :: {:ok, SlackHistoryImportRun.t(), map()} | {:error, term()}

  @doc false
  @spec transition_in_transaction(Ecto.UUID.t(), (StateMachine.Run.t() ->
                                                    StateMachine.transition_result())) ::
          {SlackHistoryImportRun.t(), map()} | no_return()
  def transition_in_transaction(run_id, transition) when is_function(transition, 1) do
    if Repo.in_transaction?() do
      persist_transition(run_id, transition)
    else
      raise ArgumentError, "Slack history transition requires an existing Repo transaction"
    end
  end

  defp persist_run(run_attrs, channels) do
    lock_idempotency_key(run_attrs)

    case find_idempotent_run(run_attrs) do
      nil -> insert_run(run_attrs, channels)
      existing -> validate_idempotent_run(existing, run_attrs, channels)
    end
  end

  defp transition_run(run_id, transition) do
    case Repo.transaction(fn -> persist_transition(run_id, transition) end) do
      {:ok, {%SlackHistoryImportRun{} = run, event}} -> {:ok, run, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_transition(run_id, transition) do
    with {:ok, stored_run} <- lock_run(run_id),
         {:ok, protocol_run, event} <- transition.(to_protocol(stored_run)) do
      {persist_protocol!(stored_run, protocol_run), event}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp snapshot_belongs_to_run?(snapshot_id, run_id) do
    Ecto.UUID.cast(snapshot_id) != :error and
      Repo.exists?(
        from(snapshot in SourcedContextSnapshot,
          where: snapshot.id == ^snapshot_id and snapshot.run_id == ^run_id
        )
      )
  end

  defp retry_window_open?(%{retry_not_before: nil}), do: :ok

  defp retry_window_open?(%{retry_not_before: retry_not_before}) do
    if DateTime.compare(DateTime.utc_now(), retry_not_before) in [:eq, :gt],
      do: :ok,
      else: {:error, {:retry_not_before, retry_not_before}}
  end

  defp persist_replacement(old_run_id, attrs, channels) do
    with {:ok, old_run} <- lock_run(old_run_id),
         :ok <- check_expected_generation(old_run, value(attrs, :expected_generation)),
         :ok <- authorize_replacement(old_run, value(attrs, :requested_by_user_id)) do
      run_attrs = replacement_attrs(old_run, attrs)

      with :ok <- validate_run_attrs(run_attrs) do
        lock_idempotency_key(run_attrs)

        case find_idempotent_run(run_attrs) do
          nil -> insert_replacement(old_run, run_attrs, channels)
          existing -> replay_replacement(old_run, existing, run_attrs, channels)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_replacement(old_run, run_attrs, channels) do
    new_run_id = Ecto.UUID.generate()

    case StateMachine.restart_after_reconnect(
           to_protocol(old_run),
           new_run_id,
           connect_id: run_attrs.connect_id,
           connect_generation: run_attrs.connect_generation,
           source_workspace_id: run_attrs.source_workspace_id
         ) do
      {:ok, _protocol_run, event} ->
        run = insert_run(Map.put(run_attrs, :id, new_run_id), channels)
        {run, event}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp replay_replacement(old_run, existing, run_attrs, channels) do
    existing = preload_channels(existing)

    if same_run_request?(existing, run_attrs, channels) and
         existing.replaces_run_id == old_run.id do
      {existing,
       %{
         command: :restart_after_reconnect,
         replaces_run_id: old_run.id,
         old_connect_generation: old_run.connect_generation,
         new_connect_generation: existing.connect_generation,
         replayed?: true
       }}
    else
      Repo.rollback(:idempotency_conflict)
    end
  end

  defp lock_run(run_id) do
    case Repo.one(
           from(run in SlackHistoryImportRun,
             where: run.id == ^run_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp persist_protocol!(stored_run, protocol_run) do
    stored_run
    |> SlackHistoryImportRun.transition_changeset(%{
      state: Atom.to_string(protocol_run.state),
      generation: protocol_run.generation,
      resume_phase: encode_reason(protocol_run.resume_phase),
      paused_reason: encode_reason(protocol_run.paused_reason),
      retry_not_before: protocol_run.retry_not_before,
      snapshot_id: protocol_run.snapshot_id,
      derivation_id: protocol_run.derivation_id,
      review_revision_id: protocol_run.review_revision_id,
      publication_id: protocol_run.publication_id,
      commit_base_generation: protocol_run.commit_base_generation,
      failure_reason: encode_reason(protocol_run.failure_reason),
      context_bundle_id: stored_run.context_bundle_id
    })
    |> Repo.update!()
    |> preload_channels()
  end

  defp to_protocol(run) do
    %StateMachine.Run{
      id: run.id,
      connect_id: run.connect_id,
      connect_generation: run.connect_generation,
      source_workspace_id: run.source_workspace_id,
      replaces_run_id: run.replaces_run_id,
      state: StateMachine.state_from_storage!(run.state),
      generation: run.generation,
      resume_phase: decode_phase(run.resume_phase),
      paused_reason: decode_reason(run.paused_reason),
      retry_not_before: run.retry_not_before,
      snapshot_id: run.snapshot_id,
      derivation_id: run.derivation_id,
      review_revision_id: run.review_revision_id,
      publication_id: run.publication_id,
      commit_base_generation: run.commit_base_generation,
      failure_reason: decode_reason(run.failure_reason),
      command_receipts: load_command_receipts(run.id)
    }
  end

  defp load_command_receipts(run_id) do
    Repo.all(
      from(receipt in SlackHistoryImportCommandReceipt,
        where: receipt.run_id == ^run_id,
        order_by: [asc: receipt.created_at, asc: receipt.id]
      )
    )
    |> Map.new(fn receipt ->
      result = %{
        command_id: receipt.command_id,
        kind: receipt_kind(receipt.kind),
        publication_id: receipt.result["publication_id"]
      }

      {receipt.command_id, result}
    end)
  end

  defp receipt_kind("committed"), do: :committed
  defp receipt_kind("canceled"), do: :canceled
  defp receipt_kind("rolled_back_after_late_cancel"), do: :rolled_back_after_late_cancel
  defp receipt_kind("rolled_back"), do: :rolled_back

  defp insert_run(run_attrs, channels) do
    case %SlackHistoryImportRun{}
         |> SlackHistoryImportRun.create_changeset(run_attrs)
         |> Repo.insert() do
      {:ok, run} ->
        Enum.each(channels, fn channel ->
          %SlackHistoryImportChannel{}
          |> SlackHistoryImportChannel.changeset(%{
            run_id: run.id,
            channel_id: channel.id,
            channel_name: channel.name,
            visibility: channel.visibility,
            authority_revision: channel.authority_revision
          })
          |> Repo.insert!()
        end)

        case register_run_bundle(run) do
          {:ok, bundle} ->
            run
            |> SlackHistoryImportRun.transition_changeset(%{
              state: run.state,
              generation: run.generation,
              context_bundle_id: bundle.id
            })
            |> Repo.update!()
            |> preload_channels()

          {:error, reason} ->
            Repo.rollback(reason)
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp find_idempotent_run(run_attrs) do
    Repo.one(
      from(run in SlackHistoryImportRun,
        where:
          run.org_id == ^run_attrs.org_id and
            run.requested_by_user_id == ^run_attrs.requested_by_user_id and
            run.client_request_id == ^run_attrs.client_request_id
      )
    )
  end

  defp validate_idempotent_run(existing, run_attrs, channels) do
    existing = preload_channels(existing)

    if same_run_request?(existing, run_attrs, channels) do
      existing
    else
      Repo.rollback(:idempotency_conflict)
    end
  end

  defp lock_idempotency_key(attrs) do
    key =
      Enum.join(
        [
          "slack_history_import_run",
          attrs.org_id,
          attrs.requested_by_user_id,
          attrs.client_request_id
        ],
        ":"
      )

    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
  end

  defp same_run_request?(run, attrs, channels) do
    run.project_id == attrs.project_id and
      run.salix_tenant_id == attrs.salix_tenant_id and
      run.salix_group_id == attrs.salix_group_id and
      run.source_workspace_id == attrs.source_workspace_id and
      run.source_app_id == attrs.source_app_id and
      run.connect_id == attrs.connect_id and
      run.connect_generation == attrs.connect_generation and
      run.replaces_run_id == attrs.replaces_run_id and
      DateTime.compare(run.range_start, attrs.range_start) == :eq and
      DateTime.compare(run.range_end, attrs.range_end) == :eq and
      run.policy_revision == attrs.policy_revision and
      run.coverage_profile == attrs.coverage_profile and
      run.audience_scope == attrs.audience_scope and
      Enum.map(run.channels, &channel_key/1) == Enum.map(channels, &channel_key/1)
  end

  defp preload_channels(run) do
    query = from(channel in SlackHistoryImportChannel, order_by: [asc: channel.channel_id])
    Repo.preload(run, channels: query)
  end

  defp create_attrs(attrs) do
    %{
      org_id: value(attrs, :org_id),
      project_id: value(attrs, :project_id),
      requested_by_user_id: value(attrs, :requested_by_user_id),
      client_request_id: normalize_string(value(attrs, :client_request_id)),
      salix_tenant_id: normalize_string(value(attrs, :salix_tenant_id)),
      salix_group_id: normalize_string(value(attrs, :salix_group_id)),
      source_workspace_id: normalize_string(value(attrs, :source_workspace_id)),
      source_app_id: normalize_string(value(attrs, :source_app_id)),
      connect_id: normalize_string(value(attrs, :connect_id)),
      connect_generation: normalize_string(value(attrs, :connect_generation)),
      replaces_run_id: value(attrs, :replaces_run_id),
      range_start: value(attrs, :range_start),
      range_end: value(attrs, :range_end),
      policy_revision: normalize_string(value(attrs, :policy_revision)),
      coverage_profile: normalize_string(value(attrs, :coverage_profile)),
      audience_scope: normalize_string(value(attrs, :audience_scope))
    }
  end

  defp replacement_attrs(old_run, attrs) do
    %{
      org_id: old_run.org_id,
      project_id: old_run.project_id,
      requested_by_user_id: value(attrs, :requested_by_user_id),
      client_request_id: normalize_string(value(attrs, :client_request_id)),
      salix_tenant_id: old_run.salix_tenant_id,
      salix_group_id: old_run.salix_group_id,
      source_workspace_id: normalize_string(value(attrs, :source_workspace_id)),
      source_app_id: normalize_string(value(attrs, :source_app_id)),
      connect_id: normalize_string(value(attrs, :connect_id)),
      connect_generation: normalize_string(value(attrs, :connect_generation)),
      replaces_run_id: old_run.id,
      range_start: value(attrs, :range_start),
      range_end: value(attrs, :range_end),
      policy_revision: normalize_string(value(attrs, :policy_revision)),
      coverage_profile: normalize_string(value(attrs, :coverage_profile)),
      audience_scope: normalize_string(value(attrs, :audience_scope))
    }
  end

  defp normalize_channels(channels) when is_list(channels) do
    with true <- channels != [] and length(channels) <= @max_selected_channels,
         {:ok, normalized} <- normalize_channel_entries(channels),
         true <- length(normalized) == length(Enum.uniq_by(normalized, & &1.id)),
         true <- Enum.all?(normalized, &eligible_channel?/1) do
      {:ok, Enum.sort_by(normalized, & &1.id)}
    else
      false -> {:error, :invalid_channels}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_channels(_channel_ids), do: {:error, :invalid_channels}

  defp normalize_channel_entries(channels) do
    channels
    |> Enum.reduce_while({:ok, []}, fn channel, {:ok, acc} ->
      normalized = %{
        id: normalize_string(value(channel, :id)),
        name: normalize_optional_string(value(channel, :name)),
        visibility: normalize_string(value(channel, :visibility)),
        authority_revision: normalize_string(value(channel, :authority_revision))
      }

      if normalized.id == "" or normalized.authority_revision == "" or
           normalized.visibility not in ["public", "private"] do
        {:halt, {:error, :invalid_channels}}
      else
        {:cont, {:ok, [normalized | acc]}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp eligible_channel?(channel), do: channel.visibility == "public"

  defp channel_key(%SlackHistoryImportChannel{} = channel) do
    {channel.channel_id, channel.channel_name, channel.visibility, channel.authority_revision}
  end

  defp channel_key(channel) when is_map(channel) do
    {channel.id, channel.name, channel.visibility, channel.authority_revision}
  end

  defp register_run_bundle(run) do
    ContextLifecycle.register_bundle(%{
      org_id: run.org_id,
      project_id: run.project_id,
      source_type: "slack_history_import",
      source_ref: run.id,
      classification: "project_context",
      policy_ref: run.policy_revision,
      subjects: [
        %{kind: "organization", ref: run.org_id},
        %{kind: "project", ref: run.project_id},
        %{kind: "user", ref: run.requested_by_user_id}
      ]
    })
  end

  defp validate_scope(attrs) do
    case {Repo.get(Project, attrs.project_id), Repo.get(Organization, attrs.org_id)} do
      {%Project{
         org_id: org_id,
         salix_group_id: salix_group_id,
         status: "active",
         archived_at: nil
       }, %Organization{salix_tenant_id: salix_tenant_id}}
      when org_id == attrs.org_id and salix_group_id == attrs.salix_group_id and
             salix_tenant_id == attrs.salix_tenant_id ->
        Memberships.authorize(attrs.requested_by_user_id, :write, %{
          project_id: attrs.project_id,
          min_project_role: "admin"
        })

      {nil, _org} ->
        {:error, :project_not_found}

      {_project, nil} ->
        {:error, :org_not_found}

      {%Project{}, %Organization{}} ->
        {:error, :project_outside_org}
    end
  end

  defp validate_run_attrs(attrs) do
    changeset = SlackHistoryImportRun.create_changeset(%SlackHistoryImportRun{}, attrs)
    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp authorize_replacement(old_run, user_id) do
    Memberships.authorize(user_id, :write, %{
      project_id: old_run.project_id,
      min_project_role: "admin"
    })
  end

  defp check_expected_generation(%SlackHistoryImportRun{generation: generation}, generation),
    do: :ok

  defp check_expected_generation(_run, _expected_generation),
    do: {:error, :stale_run_generation}

  defp reject_replacement(attrs) do
    if is_nil(value(attrs, :replaces_run_id)),
      do: :ok,
      else: {:error, :replacement_requires_reconnect}
  end

  defp feature_enabled(feature) do
    if get_in(
         Application.get_env(:bridge_for_teams_core, :sourced_context_features, []),
         [feature]
       ) == true,
       do: :ok,
       else: {:error, {:feature_disabled, feature}}
  end

  defp encode_reason(nil), do: nil
  defp encode_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp encode_reason(reason) when is_binary(reason), do: reason

  defp decode_phase(nil), do: nil
  defp decode_phase("acquiring"), do: :acquiring
  defp decode_phase("deriving"), do: :deriving

  defp decode_reason(nil), do: nil
  defp decode_reason("source_disconnected"), do: :source_disconnected
  defp decode_reason("rate_limited"), do: :rate_limited
  defp decode_reason("provider_unavailable"), do: :provider_unavailable
  defp decode_reason("processor_unavailable"), do: :processor_unavailable
  defp decode_reason("bound_reached"), do: :bound_reached
  defp decode_reason(reason), do: reason

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(_value), do: ""

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(value), do: normalize_string(value)

  defp cast_uuid(value), do: Ecto.UUID.cast(value)
end
