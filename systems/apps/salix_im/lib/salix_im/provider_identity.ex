defmodule SalixIM.ProviderIdentity do
  @moduledoc """
  Owns provider app identities, their authority keys, and connect resolution.

  Authority records are accelerators over the canonical connect corpus. The
  fallback scan, lazy repair, reservation, release, and address validation live
  together so readers and writers enforce one identity contract.
  """

  alias SalixIM.{ProviderConnects, ProviderIdentityBarrier, ProviderIdentityScanLimiter}
  alias SalixStore.{CasRecord, Keys, S3}

  def ensure_available(provider, identity, except_connect_id \\ nil) do
    provider = trim(provider)
    identity = trim(identity)
    except_connect_id = trim(except_connect_id)

    cond do
      provider == "" or identity == "" ->
        {:error, {:bad_request, "provider identity is required"}}

      true ->
        case conflict?(provider, identity, except_connect_id) do
          {:ok, true} ->
            {:error, {:bad_request, "#{provider} app_id is already used by another connect"}}

          {:ok, false} ->
            :ok

          {:error, reason} ->
            {:error, {:identity_census_unavailable, reason}}
        end
    end
  end

  def reserve(nil, _tenant_id, _group_id, _connect_id), do: :ok

  def reserve({provider, identity}, tenant_id, group_id, connect_id),
    do: reserve_provider(provider, identity, tenant_id, group_id, connect_id)

  def reserve_provider("wechat", identity, tenant_id, group_id, connect_id) do
    identity = trim(identity)
    connect_id = trim(connect_id)

    record = %{
      "provider" => "wechat",
      "identity" => identity,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "created_at" => now(),
      "updated_at" => now()
    }

    case CasRecord.update(Keys.ctl_im_provider_identity("wechat", identity), fn
           nil -> record
           %{"released_at" => released} when not is_nil(released) -> record
           %{"connect_id" => ^connect_id} = current -> {:unchanged, current}
           _ -> {:error, {:bad_request, "wechat app_id is already used by another connect"}}
         end) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  def reserve_provider(provider, identity, tenant_id, group_id, connect_id) do
    provider = trim(provider)
    identity = trim(identity)
    connect_id = trim(connect_id)

    rec = %{
      "provider" => provider,
      "identity" => identity,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "created_at" => now(),
      "updated_at" => now()
    }

    case CasRecord.create(Keys.ctl_im_provider_identity(provider, identity), rec) do
      {:ok, _record} ->
        :ok

      {:error, :exists} ->
        case CasRecord.get(Keys.ctl_im_provider_identity(provider, identity)) do
          {:ok, %{"connect_id" => ^connect_id}} ->
            :ok

          _ ->
            {:error, {:bad_request, "#{provider} app_id is already used by another connect"}}
        end

      other ->
        other
    end
  end

  def update(provider, tenant_id, group_id, connect_id, old_identity, new_identity, fun) do
    old_identity = trim(old_identity)
    new_identity = trim(new_identity)

    if old_identity == new_identity do
      with :ok <- reserve_provider(provider, new_identity, tenant_id, group_id, connect_id) do
        fun.()
      end
    else
      with :ok <- reserve_provider(provider, new_identity, tenant_id, group_id, connect_id),
           {:ok, result} <- fun.() do
        _ = release_provider(provider, old_identity, connect_id)
        {:ok, result}
      else
        other ->
          _ = release_provider(provider, new_identity, connect_id)
          other
      end
    end
  end

  @doc "Reservation identity of one bound voice caller number on one carrier line."
  def voice_number_identity(carrier, line, e164), do: "#{carrier}:#{line}:#{e164}"

  @doc "Reservation identity that elects the single voice connect of one Group."
  def voice_group_identity(group_id), do: "group:" <> trim(group_id)

  @doc """
  Reserves one voice identity for `connect_id`. See `reserve_indexed/6`.
  """
  def reserve_voice(identity, tenant_id, group_id, connect_id, stale?),
    do: reserve_indexed("voice", identity, tenant_id, group_id, connect_id, stale?)

  @doc "Reservation identity that elects the single Signal connect of one Group."
  def signal_group_identity(group_id), do: "group:" <> trim(group_id)

  @doc """
  Reservation identity of one Signal peer on one Signal account. `peer` is
  the sender's ACI for a private chat, or `group:<base64url group id>` for a
  Signal group.
  """
  def signal_peer_identity(account_id, peer), do: "peer:#{trim(account_id)}:#{trim(peer)}"

  @doc "Reservation identity of one pending Signal claim code on one account."
  def signal_claim_identity(account_id, code_digest),
    do: "claim:#{trim(account_id)}:#{trim(code_digest)}"

  @doc """
  Reserves one identity of an indexed provider (`voice`, `signal`) for
  `connect_id`.

  These reservations are the only index for their identities: every writer
  reserves before it lists the identity on the connect, so there is no legacy
  corpus to scan. `stale?` receives a reservation held by another connect and
  answers whether that holder no longer lists the identity; only then is the
  reservation taken over. A released (tombstoned) reservation is free. A
  live holder is
  `{:error, {:voice_identity_in_use, holder}}` for voice and
  `{:error, {:identity_in_use, holder}}` otherwise.
  """
  def reserve_indexed(provider, identity, tenant_id, group_id, connect_id, stale?)
      when provider in ["voice", "signal"] and is_function(stale?, 1) do
    identity = trim(identity)
    connect_id = trim(connect_id)

    record = %{
      "provider" => provider,
      "identity" => identity,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "created_at" => now(),
      "updated_at" => now()
    }

    in_use = if provider == "voice", do: :voice_identity_in_use, else: :identity_in_use

    case CasRecord.update(Keys.ctl_im_provider_identity(provider, identity), fn
           nil ->
             record

           %{"released_at" => released} when not is_nil(released) ->
             record

           %{"connect_id" => ^connect_id} = current ->
             {:unchanged, current}

           current ->
             if stale?.(current), do: record, else: {:error, {in_use, current}}
         end) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  def release(nil, _connect_id), do: :ok

  def release({provider, identity}, connect_id),
    do: release_provider(provider, identity, connect_id)

  # A voice connect holds its Group election plus one reservation per bound
  # number. Release all of them; each release is owner-checked.
  def release(%{"provider" => "voice", "connect_id" => connect_id, "group_id" => group_id} = rec) do
    numbers =
      rec
      |> Map.get("voice_numbers", [])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"carrier" => carrier, "line" => line, "e164" => e164} ->
          [voice_number_identity(carrier, line, e164)]

        _ ->
          []
      end)

    Enum.reduce_while([voice_group_identity(group_id) | numbers], :ok, fn identity, :ok ->
      case release_provider("voice", identity, connect_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A Signal connect holds its Group election, one reservation per bound peer
  # and one per pending claim code (SalixIM.SignalConnects).
  def release(%{"provider" => "signal", "connect_id" => connect_id, "group_id" => group_id} = rec) do
    identities =
      [signal_group_identity(group_id)] ++
        SalixIM.SignalConnects.reserved_identities(rec)

    Enum.reduce_while(identities, :ok, fn identity, :ok ->
      case release_provider("signal", identity, connect_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def release(%{"provider" => provider, "app_id" => app_id, "connect_id" => connect_id})
      when provider in ["slack", "feishu"],
      do: release_provider(provider, app_id, connect_id)

  def release(%{"provider" => "wechat", "bot_user_id" => bot_id, "connect_id" => connect_id}),
    do: release_provider("wechat", bot_id, connect_id)

  def release(_rec), do: :ok

  # WeChat and Signal release with an owner-checked CAS tombstone, not a
  # delete: a GET then an unconditional DELETE would let a delayed release
  # remove a reservation that another connect took over in between, and
  # S3's conditional delete is emulated non-atomically by default. Their
  # reservers and readers treat a tombstone as free.
  def release_provider(provider, identity, connect_id) when provider in ["wechat", "signal"] do
    connect_id = trim(connect_id)

    case CasRecord.update(
           Keys.ctl_im_provider_identity(provider, trim(identity)),
           fn
             %{"connect_id" => ^connect_id} = current -> Map.put(current, "released_at", now())
             current -> {:unchanged, current}
           end,
           create: false
         ) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  def release_provider(provider, identity, connect_id) do
    provider = trim(provider)
    identity = trim(identity)
    connect_id = trim(connect_id)
    key = Keys.ctl_im_provider_identity(provider, identity)

    case CasRecord.get(key) do
      {:ok, %{"connect_id" => ^connect_id}} -> S3.delete(key)
      {:ok, _other_owner} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp conflict?(provider, identity, except_connect_id) do
    eligible? = fn rec, _physical_key ->
      identity_candidate?(rec, provider, identity) and
        trim(rec["connect_id"]) != except_connect_id
    end

    case scan_connects_for_identity(provider, identity, eligible?, :strict) do
      {:ok, nil} -> {:ok, false}
      {:ok, {_record, _physical_key}, _proof} -> {:ok, true}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Return the coordinates the fast path can safely extract from an authority
  object. Group is used as stored, connect id is trimmed, and identity matches
  exactly.
  """
  def authority_coordinates(provider, identity, object) when is_map(object) do
    if is_binary(object["connect_id"]) and is_binary(object["group_id"]) and
         object["provider"] == provider and object["identity"] == identity do
      {:ok, object["group_id"], String.trim(object["connect_id"])}
    else
      :malformed
    end
  end

  def authority_coordinates(_provider, _identity, _object), do: :malformed

  def authority_target(provider, identity, object) do
    with {:ok, group_id, connect_id} <- authority_coordinates(provider, identity, object) do
      {:ok, Keys.ctl_im_connect(group_id, connect_id)}
    end
  end

  def reachable_identity(provider, key, object) when is_map(object) do
    identity = object["identity"]

    if is_binary(identity) and identity == String.trim(identity) and identity != "" and
         object["provider"] == provider and
         Keys.ctl_im_provider_identity(provider, identity) == key do
      {:ok, identity}
    else
      :malformed
    end
  end

  def reachable_identity(_provider, _key, _object), do: :malformed

  def repair_coordinates(record, physical_key) when is_map(record) do
    group_id = record["group_id"]
    connect_id = record["connect_id"]

    if is_binary(group_id) and is_binary(connect_id) and
         Keys.ctl_im_connect(group_id, String.trim(connect_id)) == physical_key do
      {:ok, group_id, String.trim(connect_id)}
    else
      :misaddressed
    end
  end

  def repair_coordinates(_record, _physical_key), do: :misaddressed

  def find_active_slack_im_connect_by_app_id(app_id) do
    find_inbound_connect("slack", app_id, fn rec ->
      is_nil(rec["deleted_at"]) and is_nil(rec["disabled_at"]) and
        (rec["oauth_completed_at"] || 0) > 0
    end)
  end

  # The reserved lookup (Slack materialization reuse) rides the SAME
  # accelerator + fallback contract as inbound resolution (round-11: no
  # authority-key reader may treat a key as its sole source), but with
  # its OWN answer semantics (round-12), because its caller MUTATES
  # through the answer's body coordinates:
  #
  #   * trim-lenient app_id match — the previous release's reserved
  #     reader trimmed, and a padded legacy record must stay reusable;
  #   * the record's body group/connect must ROUND-TRIP to the physical
  #     key it was read from — materialization derives the OAuth write
  #     key from those body fields, so a lying body must be invisible
  #     here (it still answers read-only inbound routing) rather than
  #     redirect the write into a different record;
  #   * pending (pre-OAuth) reservations are eligible — resuming one is
  #     the whole point.
  #
  # This lookup is not inbound webhook traffic: it does not emit the
  # inbound identity-resolution metric (surface: :reserved).
  def find_reserved_slack_connect_by_app_id(app_id) do
    trimmed = trim(app_id)

    find_connect_by_provider_identity("slack", trimmed, :reserved, fn rec, physical_key ->
      rec["provider"] == "slack" and is_binary(rec["app_id"]) and
        trim(rec["app_id"]) == trimmed and is_nil(rec["deleted_at"]) and
        match?({:ok, _, _}, repair_coordinates(rec, physical_key))
    end)
  end

  def find_slack_im_connect_by_app_id(app_id) do
    find_inbound_connect("slack", app_id, fn rec ->
      is_nil(rec["deleted_at"]) and (rec["oauth_completed_at"] || 0) > 0
    end)
  end

  def find_active_feishu_im_connect_by_app_id(app_id) do
    find_inbound_connect("feishu", app_id, fn rec ->
      rec["status"] == "connected" and is_nil(rec["deleted_at"]) and
        is_nil(rec["disabled_at"])
    end)
  end

  # Inbound webhook resolution: EXACT app_id answer match (the settled
  # inbound contract) plus the caller's liveness predicate; read-only,
  # so the answer's body coordinates are never dereferenced for writes.
  defp find_inbound_connect(provider, app_id, liveness?) do
    trimmed = trim(app_id)

    find_connect_by_provider_identity(provider, trimmed, :inbound, fn rec, _physical_key ->
      rec["provider"] == provider and rec["app_id"] == trimmed and liveness?.(rec)
    end)
  end

  # The authority key is an ACCELERATOR, not the sole read source
  # (docs/identity-security.md, Option B — owner
  # decision under the round-8 acceptance boundary). A key hit whose
  # canonical revalidates AND passes the caller's eligibility predicate
  # resolves in two point GETs. Anything else — missing, malformed, or
  # stale key, ineligible record, even a key-read storage fault — falls
  # back to the fail-closed compatibility scan, under a concurrency
  # permit so a burst of unknown app_ids cannot multiply into unbounded
  # concurrent full-prefix walks. A wrong key therefore costs one
  # bounded scan and can never lose a message or misroute; correctness
  # is carried entirely by the canonical records and the predicate,
  # exactly as on main. The write protocol is untouched; the read
  # path's only write is a lazy create-once repair, allowed ONLY when
  # the completed walk proved (provider, app_id) globally unique among
  # live records — a duplicate corpus is never cached, so request order
  # can never elect a durable key owner among duplicates.
  # `eligible?` is an arity-2 predicate `(rec, physical_key)`: each
  # caller owns its complete answer semantics — provider/app_id
  # matching (inbound: exact; reserved: trim-lenient) AND liveness AND,
  # for the mutation surface, the body-coordinates round-trip. The
  # `surface` distinguishes pre-auth inbound webhook traffic (which
  # emits the documented identity-resolution metric) from the
  # authenticated reserved/materialization reader (which does not).
  defp find_connect_by_provider_identity(provider, app_id, surface, eligible?) do
    cond do
      # A blank id is an invalid request shape, not an identity: it is
      # rejected before the key read and the scan, the census/repair
      # never runs for it (`ProviderIdentity.reachable_identity/3`
      # equally rejects blank authority bodies), and the audit
      # classifies any legacy blank key as malformed — one consistent
      # answer at every layer (round-11).
      app_id == "" ->
        {:error, :not_found}

      true ->
        case fast_path_connect(provider, app_id, eligible?) do
          {:ok, rec} ->
            emit_resolution(surface, provider, "fast_hit")
            {:ok, rec}

          :fallback ->
            fallback_under_permit(provider, app_id, surface, eligible?)
        end
    end
  end

  # The fallback scan is O(corpus) GETs against one shared prefix, and
  # the webhook routes reach it pre-authentication, so its concurrency
  # is bounded by a supervised, process-owned permit
  # (`SalixIM.ProviderIdentityScanLimiter`): over-permit requests fail with a
  # retryable error (the event routes answer 503; providers redeliver)
  # instead of queueing more walks, and a killed request's permit is
  # reclaimed by monitor rather than leaking. The bound is tunable via
  # `:salix_im, :identity_scan_max_concurrency` (config.json
  # `im.identity_scan_max_concurrency`).
  defp fallback_under_permit(provider, app_id, surface, eligible?) do
    case ProviderIdentityScanLimiter.acquire() do
      {:ok, permit} ->
        try do
          case scan_and_repair(provider, app_id, surface, eligible?) do
            {:ok, rec} ->
              emit_resolution(surface, provider, "fallback_hit")
              {:ok, rec}

            {:error, :not_found} = miss ->
              emit_resolution(surface, provider, "fallback_miss")
              miss

            {:error, _} = error ->
              emit_resolution(surface, provider, "error")
              error
          end
        after
          ProviderIdentityScanLimiter.release(permit)
        end

      {:error, :scan_capacity_exhausted} = rejected ->
        emit_resolution(surface, provider, "rejected")
        rejected
    end
  end

  # Finite path+outcome accounting for the webhook-critical resolver.
  # ONLY the pre-auth inbound surface emits: the metric is documented
  # (catalog/consumers/runbook) as the inbound scan-debt signal and the
  # #590 trigger, so authenticated reserved/materialization lookups
  # must not contaminate it (round-12). fallback_* always marks a full
  # compatibility scan.
  defp emit_resolution(:reserved, _provider, _resolution), do: :ok

  defp emit_resolution(:inbound, provider, resolution) do
    :telemetry.execute(
      [:salix, :im, :identity_resolution],
      %{count: 1},
      %{provider: provider, result: resolution}
    )
  end

  # Any unsatisfying outcome — including a storage fault on the key or
  # canonical read — degrades to the fallback scan rather than an error:
  # the key is an optimization, and the scan re-reads the canonical
  # anyway (failing closed itself if storage is truly down).
  defp fast_path_connect(provider, app_id, eligible?) do
    with {:ok, identity} when is_map(identity) <-
           CasRecord.get(Keys.ctl_im_provider_identity(provider, app_id)),
         {:ok, group_id, connect_id} <-
           authority_coordinates(provider, app_id, identity),
         physical_key = Keys.ctl_im_connect(group_id, connect_id),
         # Through the connect reader so the ingress re-read of this same
         # physical record inside one callback is served by the read scope.
         {:ok, rec} when is_map(rec) <- ProviderConnects.fetch_im_connect_by_key(physical_key),
         true <- eligible?.(rec, physical_key) do
      {:ok, with_physical_locator(rec, physical_key)}
    else
      _ -> :fallback
    end
  end

  # The answer carries the PHYSICAL key it was read from, as an opaque
  # locator. Ingress re-reads the canonical record before trusting it, and a
  # historical compatibility record's body coordinates may disagree with its
  # storage key (`repair_coordinates/2` refuses to key those, so they answer
  # the scan forever): without the locator that re-read would address a
  # different — usually nonexistent — record and turn a live connect into
  # :not_found. It is a read locator only; nothing derives a write target
  # from it (the mutation surface still proves the body round-trip itself).
  defp with_physical_locator(rec, physical_key),
    do: Map.put(rec, "physical_connect_key", physical_key)

  defp scan_and_repair(provider, app_id, surface, eligible?) do
    case scan_connects_for_identity(provider, app_id, eligible?) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, {rec, physical_key}, :unique} ->
        ProviderIdentityBarrier.hit(:identity_fallback_settle)
        _ = repair_authority(provider, app_id, rec, physical_key)
        {:ok, with_physical_locator(rec, physical_key)}

      # Without an explicit key the answer is whichever record sorted
      # first — physical LIST order. That is acceptable for read-only
      # inbound routing (it matches the previous release's first-match
      # answer), but a mutation target must never be chosen that way,
      # so the reserved surface requires a COMPLETE uniqueness proof
      # and refuses every other census outcome (round-13/14). A
      # validated fast-path key still wins — that is the operator's
      # explicit choice among the candidates.
      #
      # :duplicate is a permanent configuration state → conflict, the
      # previous release's outcome (its key-only reader missed and its
      # create path reported the identity conflict). :unproven means a
      # storage fault truncated the census → retryable, because a
      # clean walk may well prove uniqueness.
      {:ok, _answer, :duplicate} when surface == :reserved ->
        ProviderIdentityBarrier.hit(:identity_fallback_settle)
        {:error, :ambiguous_identity}

      {:ok, _answer, :unproven} when surface == :reserved ->
        ProviderIdentityBarrier.hit(:identity_fallback_settle)
        {:error, :identity_census_unavailable}

      # Inbound: :duplicate elects no key owner (every lookup keeps
      # scanning until the operator settles the duplicates — see the
      # identity audit); :unproven keeps the answer and defers the
      # repair to a clean walk.
      {:ok, {rec, physical_key}, _duplicate_or_unproven} ->
        ProviderIdentityBarrier.hit(:identity_fallback_settle)
        {:ok, with_physical_locator(rec, physical_key)}

      {:error, _} = error ->
        error
    end
  end

  # Best-effort, lazy: the ONLY write the read path performs, and only
  # ever called with a completed-walk uniqueness proof in hand. The
  # coordinates must round-trip to the record's PHYSICAL storage key
  # (`repair_coordinates/2`) — a record whose body lies
  # about its location still answers scans but is never keyed, because
  # the resulting authority would point at nothing and squat the
  # identity forever (round-10). The create-once may lose a race, hit a
  # squatting stale key, or fail on storage — all ignored; the next miss
  # simply scans again. It never deletes or overwrites, so it cannot
  # invalidate anything a foreground operation depends on.
  defp repair_authority(provider, app_id, rec, physical_key) do
    # The repair stays INBOUND-aligned regardless of which caller's
    # predicate selected the answer: only an exact-app_id record may be
    # keyed (a trim-lenient reserved answer over a padded legacy record
    # would mint a key the inbound fast path can never honor).
    with true <- rec["app_id"] == app_id,
         {:ok, group_id, connect_id} <- repair_coordinates(rec, physical_key) do
      ProviderIdentityBarrier.hit(:identity_fallback_reserve)
      reserve_provider(provider, app_id, rec["tenant_id"], group_id, connect_id)
    else
      _ -> :ok
    end
  end

  # The fallback scan is FAIL-CLOSED and answers with the previous
  # release's resolution order: the first record matching the caller's
  # predicate, in key order, returned only when every earlier record in
  # key order was readable — a LIST or per-record GET fault before the
  # answer halts with a retryable error instead of shrinking the corpus,
  # so "not found" (and which record wins) is never decided from a
  # partially readable prefix. Undecodable or non-map JSON is malformed
  # DATA, not a fault, and is skipped — one corrupt sibling must not
  # block a valid lookup.
  #
  # Unlike main's `Enum.find`, the walk continues past the answer to
  # census every live record whose trimmed app_id matches (the write
  # protocol's own conflict definition, `ProviderIdentity.ensure_available/3`):
  # the lazy repair may key the answer ONLY when that census proves it
  # globally unique. A second candidate ends the walk as :duplicate; a
  # fault after the answer degrades the proof (:unproven), never the
  # answer.
  defp scan_connects_for_identity(provider, app_id, eligible?, malformed \\ :skip) do
    scan_connect_pages(
      Keys.ctl_im_connects_all_prefix(),
      nil,
      provider,
      app_id,
      eligible?,
      {nil, 0},
      malformed
    )
  end

  defp scan_connect_pages(prefix, token, provider, app_id, eligible?, acc, malformed) do
    opts = [max_keys: scan_page_size()] ++ if token, do: [continuation_token: token], else: []

    case S3.list(prefix, opts) do
      {:ok, %{objects: objects, next: next}} ->
        case scan_connect_page(objects, provider, app_id, eligible?, acc, malformed) do
          {:cont, acc} when is_binary(next) ->
            scan_connect_pages(prefix, next, provider, app_id, eligible?, acc, malformed)

          {:cont, {nil, _census}} ->
            {:ok, nil}

          {:cont, {answer, census}} ->
            {:ok, answer, if(census == 1, do: :unique, else: :duplicate)}

          {:halt, result} ->
            result
        end

      # A LIST fault after an answer was already selected degrades only
      # the uniqueness proof, exactly like a per-record GET fault in the
      # tail: the main-compatible answer stands, the repair is
      # suppressed until a clean walk. With no answer yet, it is
      # fail-closed — no decision from a partially readable prefix.
      {:error, reason} ->
        case acc do
          {nil, _census} -> {:error, {:fallback_scan_failed, reason}}
          {answer, _census} -> {:ok, answer, :unproven}
        end
    end
  end

  defp scan_page_size, do: Application.get_env(:salix_im, :identity_scan_page_size, 1000)

  defp scan_connect_page(objects, provider, app_id, eligible?, acc, malformed) do
    Enum.reduce_while(objects, {:cont, acc}, fn %{key: key}, {:cont, acc} ->
      case scan_connect_record(key, provider, app_id, eligible?, acc, malformed) do
        {:cont, _} = cont -> {:cont, cont}
        {:halt, _} = halt -> {:halt, halt}
      end
    end)
  end

  defp scan_connect_record(key, provider, app_id, eligible?, {answer, census}, malformed) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, rec} when is_map(rec) ->
            census = if identity_candidate?(rec, provider, app_id), do: census + 1, else: census
            answer = answer || scan_answer(rec, key, eligible?)

            if answer != nil and census > 1 do
              {:halt, {:ok, answer, :duplicate}}
            else
              {:cont, {answer, census}}
            end

          _ when malformed == :skip ->
            {:cont, {answer, census}}

          _ ->
            {:halt, {:error, {:fallback_scan_failed, key, :invalid_connect_record}}}
        end

      # Deleted between LIST and GET.
      {:error, :not_found} ->
        {:cont, {answer, census}}

      {:error, reason} when answer == nil ->
        {:halt, {:error, {:fallback_scan_failed, key, reason}}}

      {:error, _reason} ->
        {:halt, {:ok, answer, :unproven}}
    end
  end

  # Census membership is matched WIDE (trimmed app_id, deleted excluded)
  # so it can only over-count relative to the answer's exact match: a
  # suppressed repair costs one more scan, a missed duplicate would
  # durably elect a wrong owner.
  defp identity_candidate?(rec, provider, app_id) do
    rec["provider"] == provider and is_binary(rec["app_id"]) and
      trim(rec["app_id"]) == app_id and is_nil(rec["deleted_at"])
  end

  # The answer carries its physical LIST key so the caller's predicate
  # can judge the full address and the repair can validate the record's
  # body coordinates against where it actually lives.
  defp scan_answer(rec, key, eligible?) do
    if eligible?.(rec, key), do: {rec, key}, else: nil
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
  defp now, do: System.system_time(:millisecond)
end
