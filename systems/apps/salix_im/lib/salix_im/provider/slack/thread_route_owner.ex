defmodule SalixIM.Provider.Slack.ThreadRouteOwner do
  @moduledoc """
  Canonical Slack thread owner CAS.

  The initial ownership, generation fencing, retry, and recovery protocol is
  modeled in `tla/salix/SlackThreadRouteOwner.tla`. Explicit Task handover and
  the final-effect reservation extend that owner record and are modeled
  together in `tla/salix/SlackTriageTaskOwnership.tla`, with executable CAS
  race regressions beside this module.
  """

  alias SalixIM.ProviderConnects
  alias SalixStore.{CasRecord, Crypto, Keys, ULID}

  @schema "comma.slack-thread-route-owner.v4"
  @legacy_schema "comma.slack-thread-route-owner.v2"
  @scope_keys ~w(tenant_id group_id connect_id connect_generation workspace_id channel_id root_thread_ts)
  @shared_scope_keys ~w(tenant_id group_id workspace_id channel_id root_thread_ts)
  @legacy_record_keys ["schema", "owner", "claim_identity", "claimed_at_ms" | @scope_keys]
  @record_keys ["effect", "schema", "owner", "claim_identity", "claimed_at_ms" | @scope_keys]
  @effect_keys ~w(schema identity reservation_identity state reserved_at_ms)
  @effect_schema "comma.slack-thread-route-effect.v2"
  @effect_states ~w(reserved inflight)
  @verified_root_callback_keys ~w(provider_event_id callback_app_id workspace_id channel_id root_thread_ts)
  @owners %{
    "legacy" => :legacy,
    "assistant" => :assistant,
    "triage" => :triage,
    "task" => :task
  }
  @lower_hex_64 ~r/\A[0-9a-f]{64}\z/
  @slack_ts ~r/\A[0-9]+\.[0-9]{6}\z/

  def lookup(scope) do
    with {:ok, scope} <- validate_scope(scope),
         {:ok, record} <- CasRecord.get(route_key(scope)),
         {:ok, owner, _claim_identity, winner_scope, _effect} <-
           validate_record(record, scope) do
      if winner_scope == scope do
        {:ok, owner}
      else
        case winner_status(winner_scope) do
          # The winner's own authority is gone (rotation, disable,
          # reprovision), so the physical thread is claimable again under the
          # current generation, subject to the owner-kind fence in `claim/3`.
          :stale ->
            :unbound

          # The physical thread is durably held by ANOTHER scope's still
          # current winner — a different connect, or a different generation of
          # this one. That is a settled decision, not a storage fault: the
          # caller must converge inert instead of retrying a route that will
          # never become available to it.
          :current ->
            {:owned_elsewhere, owner}

          :unavailable ->
            :unavailable
        end
      end
    else
      {:error, :not_found} -> :unbound
      _other -> :unavailable
    end
  end

  @doc """
  Reads the exact owner AND claim identity durably held for THIS scope.

  `lookup/1` answers which family owns the physical thread; this answers with
  what identity it owns it, so a continuation of an existing conversation can
  re-verify the owner it is joining without minting a new claim of its own. Any
  answer that is not this exact scope's own current record — a foreign or
  stale winner, an invalid record, an unreadable store — is `:unavailable`:
  there is no claim here for a caller to pin against.
  """
  def lookup_claim(scope) do
    with {:ok, scope} <- validate_scope(scope),
         {:ok, record} <- CasRecord.get(route_key(scope)),
         {:ok, owner, claim_identity, ^scope, _effect} <- validate_record(record, scope) do
      {:ok, owner, claim_identity}
    else
      _other -> :unavailable
    end
  end

  def verify_claim(scope, expected_owner, claim_identity)
      when expected_owner in [:legacy, :assistant, :triage, :task] do
    with {:ok, scope} <- validate_scope(scope),
         true <- valid_claim_identity?(claim_identity),
         {:ok, record} <- CasRecord.get(route_key(scope)),
         {:ok, owner, current_claim_identity, winner_scope, _effect} <-
           validate_record(record, scope) do
      if winner_scope == scope and owner == expected_owner and
           current_claim_identity == claim_identity,
         do: {:ok, owner},
         else: {:conflict, owner}
    else
      _other -> :unavailable
    end
  end

  def verify_claim(_scope, _expected_owner, _claim_identity), do: :unavailable

  def claim_triage(scope, claim_identity), do: claim(scope, claim_identity, "triage")
  def claim_legacy(scope, claim_identity), do: claim(scope, claim_identity, "legacy")

  @doc "Derives the stable explicit-Task handover identity for one thread and Task."
  def task_claim_identity(scope, conversation_id) when is_binary(conversation_id) do
    with {:ok, scope} <- validate_scope(scope),
         true <- canonical_nonblank?(conversation_id) do
      {:ok,
       [
         "comma.slack-task-thread-owner-claim.v1",
         scope["tenant_id"],
         scope["group_id"],
         scope["connect_id"],
         scope["connect_generation"],
         scope["workspace_id"],
         scope["channel_id"],
         scope["root_thread_ts"],
         conversation_id
       ]
       |> Enum.join(<<0>>)
       |> Crypto.hex()}
    else
      _invalid -> {:error, :invalid_task_thread_owner}
    end
  end

  def task_claim_identity(_scope, _conversation_id),
    do: {:error, :invalid_task_thread_owner}

  @doc "Atomically hands one route owner to an explicit Task without waiting for Triage."
  def claim_task(scope, claim_identity) do
    with {:ok, scope} <- validate_scope(scope),
         true <- valid_claim_identity?(claim_identity) do
      key = route_key(scope)
      desired = owner_record(scope, "task", claim_identity)

      case CasRecord.create(key, desired) do
        {:ok, _record} ->
          {:ok, :task}

        {:error, :exists} ->
          resolve_task_claim(key, scope, claim_identity)

        {:error, _reason} ->
          :unavailable
      end
    else
      _invalid -> :unavailable
    end
  end

  @doc "Serializes one final Triage provider effect without delaying Task handover."
  def with_triage_effect(scope, claim_identity, effect_identity, fun)
      when is_function(fun, 1) do
    case reserve_triage_effect(scope, claim_identity, effect_identity) do
      {:ok, reservation} ->
        case begin_triage_effect(reservation) do
          :ok ->
            try do
              result = fun.(reservation)

              case release_triage_effect(reservation) do
                :ok -> result
                :unavailable -> {:error, :slack_route_unavailable}
              end
            rescue
              exception ->
                _ = release_triage_effect(reservation)
                reraise exception, __STACKTRACE__
            catch
              kind, reason ->
                _ = release_triage_effect(reservation)
                :erlang.raise(kind, reason, __STACKTRACE__)
            end

          other ->
            other
        end

      other ->
        other
    end
  end

  def with_triage_effect(_scope, _claim_identity, _effect_identity, _fun), do: :unavailable

  def verified_root_claim_identity(scope, callback) do
    with {:ok, scope} <- validate_scope(scope),
         {:ok, callback} <- validate_verified_root_callback(callback, scope) do
      identity =
        [
          "comma.slack-root-callback-claim.v2",
          scope["tenant_id"],
          scope["group_id"],
          scope["connect_id"],
          scope["connect_generation"],
          scope["workspace_id"],
          scope["channel_id"],
          scope["root_thread_ts"],
          callback["provider_event_id"],
          callback["callback_app_id"]
        ]
        |> Enum.join(<<0>>)
        |> Crypto.hex()

      {:ok, identity}
    else
      _other -> {:error, :invalid_verified_root_callback}
    end
  end

  @doc "Derives the stable root-owner claim used by the ClickHouse ambient source."
  def clickhouse_root_claim_identity(scope, message_ts_us) when is_integer(message_ts_us) do
    with {:ok, scope} <- validate_scope(scope),
         true <- message_ts_us >= 0 do
      {:ok,
       [
         "comma.slack-clickhouse-root-claim.v1",
         scope["tenant_id"],
         scope["group_id"],
         scope["connect_id"],
         scope["connect_generation"],
         scope["workspace_id"],
         scope["channel_id"],
         scope["root_thread_ts"],
         Integer.to_string(message_ts_us)
       ]
       |> Enum.join(<<0>>)
       |> Crypto.hex()}
    else
      _invalid -> {:error, :invalid_clickhouse_root}
    end
  end

  def clickhouse_root_claim_identity(_scope, _message_ts_us),
    do: {:error, :invalid_clickhouse_root}

  defp claim(scope, claim_identity, owner) do
    with {:ok, scope} <- validate_scope(scope),
         true <- valid_claim_identity?(claim_identity) do
      record = owner_record(scope, owner, claim_identity)

      key = route_key(scope)

      case CasRecord.create(key, record) do
        {:ok, _record} -> {:ok, Map.fetch!(@owners, owner)}
        {:error, :exists} -> resolve_existing_claim(key, scope, owner, claim_identity)
        {:error, _reason} -> :unavailable
      end
    else
      _other -> :unavailable
    end
  end

  defp resolve_existing_claim(key, scope, owner, claim_identity) do
    with {:ok, record} <- CasRecord.get(key),
         {:ok, current_owner, current_claim_identity, winner_scope, _effect} <-
           validate_record(record, scope) do
      cond do
        winner_scope == scope and record["owner"] == owner and
            current_claim_identity == claim_identity ->
          {:ok, current_owner}

        winner_scope == scope ->
          {:conflict, current_owner}

        true ->
          case winner_status(winner_scope) do
            :current ->
              {:conflict, current_owner}

            # The physical thread's owner kind is decided exactly once. A
            # stale winner (rotation, disable, reprovision) lets the SAME
            # kind renew under the current generation, but never lets a
            # delayed or reclassified copy flip the kind: after an identity
            # rotation the original explicit mention is no longer
            # recognizable, and without this fence a targeted legacy root
            # would be re-admitted as an ambient triage effect.
            :stale ->
              if record["owner"] == owner do
                replace_stale_winner(key, record, scope, owner, claim_identity)
              else
                {:conflict, current_owner}
              end

            :unavailable ->
              :unavailable
          end
      end
    else
      _other -> :unavailable
    end
  end

  defp validate_scope(scope) when is_map(scope) do
    if Enum.sort(Map.keys(scope)) == Enum.sort(@scope_keys) and
         Enum.all?(@scope_keys, &canonical_nonblank?(scope[&1])) and
         valid_generation?(scope["connect_generation"]) and
         Regex.match?(@slack_ts, scope["root_thread_ts"]) do
      {:ok, scope}
    else
      {:error, :invalid_scope}
    end
  end

  defp validate_scope(_scope), do: {:error, :invalid_scope}

  defp validate_verified_root_callback(callback, scope) when is_map(callback) do
    if Enum.sort(Map.keys(callback)) == Enum.sort(@verified_root_callback_keys) and
         Enum.all?(@verified_root_callback_keys, &canonical_nonblank?(callback[&1])) and
         callback["workspace_id"] == scope["workspace_id"] and
         callback["channel_id"] == scope["channel_id"] and
         callback["root_thread_ts"] == scope["root_thread_ts"] do
      {:ok, callback}
    else
      {:error, :invalid_verified_root_callback}
    end
  end

  defp validate_verified_root_callback(_callback, _scope),
    do: {:error, :invalid_verified_root_callback}

  defp validate_record(record, scope) when is_map(record) do
    owner = @owners[record["owner"]]
    winner_scope = Map.take(record, @scope_keys)
    effect = Map.get(record, "effect")

    valid_shape? =
      (record["schema"] == @legacy_schema and
         Enum.sort(Map.keys(record)) == Enum.sort(@legacy_record_keys)) or
        (record["schema"] == @schema and
           Enum.sort(Map.keys(record)) == Enum.sort(@record_keys) and
           valid_effect?(effect))

    if valid_shape? and not is_nil(owner) and
         Map.take(record, @shared_scope_keys) == Map.take(scope, @shared_scope_keys) and
         validate_scope(winner_scope) == {:ok, winner_scope} and
         valid_claim_identity?(record["claim_identity"]) and
         is_integer(record["claimed_at_ms"]) and record["claimed_at_ms"] >= 0 do
      {:ok, owner, record["claim_identity"], winner_scope, effect}
    else
      {:error, :invalid_record}
    end
  end

  defp replace_stale_winner(key, observed, scope, owner, claim_identity) do
    replacement = owner_record(scope, owner, claim_identity)

    case CasRecord.update(
           key,
           fn current ->
             if current == observed,
               do: replacement,
               else: {:error, :slack_thread_route_conflict}
           end,
           create: false
         ) do
      {:ok, ^replacement} -> {:ok, Map.fetch!(@owners, owner)}
      {:error, _reason} -> :unavailable
    end
  end

  defp winner_status(scope) do
    case CasRecord.get(Keys.ctl_im_connect(scope["group_id"], scope["connect_id"])) do
      {:ok, _record} ->
        case ProviderConnects.get_slack_triage_authority(
               scope["tenant_id"],
               scope["group_id"],
               scope["connect_id"],
               scope["channel_id"]
             ) do
          {:ok, authority} ->
            if authority["connect_generation"] == scope["connect_generation"] and
                 authority["workspace_id"] == scope["workspace_id"],
               do: :current,
               else: :stale

          {:error, :slack_triage_authority_ineligible} ->
            :stale

          {:error, :slack_triage_authority_unavailable} ->
            :unavailable
        end

      {:error, :not_found} ->
        :stale

      _unavailable ->
        :unavailable
    end
  end

  defp route_key(scope) do
    Keys.ctl_im_slack_thread_route_owner(
      scope["group_id"],
      scope["workspace_id"],
      scope["channel_id"],
      scope["root_thread_ts"]
    )
  end

  defp valid_claim_identity?(value),
    do: is_binary(value) and Regex.match?(@lower_hex_64, value)

  defp valid_generation?(value),
    do: ULID.valid?(value) or valid_claim_identity?(value)

  defp owner_record(scope, owner, claim_identity) do
    scope
    |> Map.merge(%{
      "schema" => @schema,
      "owner" => owner,
      "claim_identity" => claim_identity,
      "claimed_at_ms" => System.system_time(:millisecond),
      "effect" => nil
    })
  end

  defp resolve_task_claim(key, scope, claim_identity) do
    with {:ok, record} <- CasRecord.get(key),
         {:ok, current_owner, _current_claim_identity, winner_scope, _effect} <-
           validate_record(record, scope) do
      if winner_scope == scope do
        replace_current_scope_with_task(key, scope, claim_identity)
      else
        case winner_status(winner_scope) do
          :current -> {:conflict, current_owner}
          :stale -> replace_owner(key, record, scope, "task", claim_identity)
          :unavailable -> :unavailable
        end
      end
    else
      _invalid -> :unavailable
    end
  end

  defp replace_current_scope_with_task(key, scope, claim_identity) do
    case CasRecord.update(
           key,
           fn current ->
             case validate_record(current, scope) do
               {:ok, :task, ^claim_identity, ^scope, _effect} ->
                 {:unchanged, current}

               {:ok, :task, _other_claim_identity, ^scope, _effect} ->
                 {:error, :slack_thread_route_task_conflict}

               {:ok, _owner, _current_claim_identity, ^scope, _effect} ->
                 owner_record(scope, "task", claim_identity)

               _drift ->
                 {:error, :slack_thread_route_conflict}
             end
           end,
           create: false
         ) do
      {:ok, record} ->
        case validate_record(record, scope) do
          {:ok, :task, ^claim_identity, ^scope, nil} -> {:ok, :task}
          _drift -> :unavailable
        end

      {:error, :slack_thread_route_task_conflict} ->
        {:conflict, :task}

      {:error, _reason} ->
        :unavailable
    end
  end

  defp reserve_triage_effect(scope, expected_claim_identity, effect_identity) do
    with {:ok, scope} <- validate_scope(scope),
         true <- valid_claim_identity?(expected_claim_identity),
         true <- valid_claim_identity?(effect_identity),
         key <- route_key(scope),
         {:ok, record} <- CasRecord.get(key),
         {:ok, owner, claim_identity, winner_scope, effect} <-
           validate_record(record, scope) do
      cond do
        winner_scope != scope or owner != :triage or
            claim_identity != expected_claim_identity ->
          {:conflict, owner}

        is_map(effect) ->
          {:busy, :triage}

        true ->
          reservation_identity =
            Crypto.hex([
              "comma.slack-triage-effect-reservation.v1",
              effect_identity,
              ULID.generate()
            ])

          reserved =
            record
            |> Map.put("schema", @schema)
            |> Map.put("effect", %{
              "schema" => @effect_schema,
              "identity" => effect_identity,
              "reservation_identity" => reservation_identity,
              "state" => "reserved",
              "reserved_at_ms" => System.system_time(:millisecond)
            })

          case CasRecord.update(
                 key,
                 fn current ->
                   if current == record,
                     do: reserved,
                     else: {:error, :slack_thread_route_conflict}
                 end,
                 create: false
               ) do
            {:ok, ^reserved} ->
              {:ok,
               reservation(
                 scope,
                 claim_identity,
                 effect_identity,
                 reservation_identity
               )}

            {:error, _reason} ->
              :unavailable
          end
      end
    else
      {:error, :not_found} -> {:conflict, :unbound}
      _invalid -> :unavailable
    end
  end

  defp begin_triage_effect(%{
         scope: scope,
         claim_identity: claim_identity,
         effect_identity: effect_identity,
         reservation_identity: reservation_identity
       }) do
    key = route_key(scope)

    case CasRecord.update(
           key,
           fn current ->
             case validate_record(current, scope) do
               {:ok, :triage, ^claim_identity, ^scope,
                %{
                  "identity" => ^effect_identity,
                  "reservation_identity" => ^reservation_identity,
                  "state" => "reserved"
                }} ->
                 put_in(current, ["effect", "state"], "inflight")

               {:ok, :task, _task_claim_identity, ^scope, nil} ->
                 {:error, :slack_thread_route_task_owner}

               _drift ->
                 {:error, :slack_thread_route_conflict}
             end
           end,
           create: false
         ) do
      {:ok, _record} -> :ok
      {:error, :slack_thread_route_task_owner} -> {:conflict, :task}
      {:error, _reason} -> :unavailable
    end
  end

  defp release_triage_effect(%{
         scope: scope,
         claim_identity: claim_identity,
         effect_identity: effect_identity,
         reservation_identity: reservation_identity
       }) do
    key = route_key(scope)

    case CasRecord.update(
           key,
           fn current ->
             case validate_record(current, scope) do
               {:ok, :triage, ^claim_identity, ^scope,
                %{
                  "identity" => ^effect_identity,
                  "reservation_identity" => ^reservation_identity,
                  "state" => "inflight"
                }} ->
                 Map.put(current, "effect", nil)

               {:ok, :triage, ^claim_identity, ^scope, nil} ->
                 {:unchanged, current}

               {:ok, :triage, ^claim_identity, ^scope, _newer_effect} ->
                 {:unchanged, current}

               {:ok, :task, _task_claim_identity, ^scope, nil} ->
                 {:unchanged, current}

               _drift ->
                 {:error, :slack_thread_route_conflict}
             end
           end,
           create: false
         ) do
      {:ok, _record} -> :ok
      {:error, _reason} -> :unavailable
    end
  end

  defp replace_owner(key, observed, scope, owner, claim_identity) do
    replacement = owner_record(scope, owner, claim_identity)

    case CasRecord.update(
           key,
           fn current ->
             if current == observed,
               do: replacement,
               else: {:error, :slack_thread_route_conflict}
           end,
           create: false
         ) do
      {:ok, ^replacement} -> {:ok, Map.fetch!(@owners, owner)}
      {:error, _reason} -> :unavailable
    end
  end

  defp reservation(scope, claim_identity, effect_identity, reservation_identity) do
    %{
      scope: scope,
      claim_identity: claim_identity,
      effect_identity: effect_identity,
      reservation_identity: reservation_identity
    }
  end

  defp valid_effect?(nil), do: true

  defp valid_effect?(effect) when is_map(effect) do
    Enum.sort(Map.keys(effect)) == Enum.sort(@effect_keys) and
      effect["schema"] == @effect_schema and
      valid_claim_identity?(effect["identity"]) and
      valid_claim_identity?(effect["reservation_identity"]) and
      effect["state"] in @effect_states and
      is_integer(effect["reserved_at_ms"]) and effect["reserved_at_ms"] >= 0
  end

  defp valid_effect?(_effect), do: false

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, <<0>>)
end
