defmodule SalixIM.ProviderIdentityAudit do
  @moduledoc """
  Operator audit of the IM provider-identity authority keys
  (`ctl/im_provider_identities/...`) against the canonical connect
  corpus (`ctl/im_connects/...`).

  Certification uses `SalixIM.ProviderIdentity` — the SAME
  physical-address contract the fast path executes — so a certified key
  is exactly a key the runtime honors (round-10). A key is CERTIFIED
  only when:

    * its body round-trips to its own storage key with a trim-stable,
      exact identity (`ProviderIdentity.reachable_identity/3`);
    * exactly one live canonical record carries that (provider,
      identity) — the same census the read path's lazy repair requires;
    * the key's coordinates address that record's PHYSICAL storage key
      (`ProviderIdentity.authority_target/3` vs the LIST key, not body
      claims); and
    * the record's `app_id` matches the identity EXACTLY (the fast
      path's canonical revalidation).

  Every other key is deprecated debris: `:dangling` (no live carrier),
  `:duplicate` (uniqueness unprovable; request order must never elect an
  owner), `:mismatched` (a unique live record exists but the key does
  not address it), or `:malformed` (undecodable, incomplete,
  mis-addressed, or non-trim-stable body).

  Canonical records whose OWN body coordinates do not round-trip to
  their physical key are reported as `misaddressed_records`: they still
  answer read-only inbound scans, but the lazy repair refuses to key
  them (a key built from lying coordinates would point at nothing and
  squat forever) and the mutation-capable reserved reader refuses to
  return them at all (round-12 — materialization derives its write key
  from the answer's body coordinates). Unkeyed, they scan on every
  inbound lookup until the operator repairs the record; the clean gate
  fails while any remain.

  Deleting a deprecated key — every class EXCEPT `:duplicate`, which
  `fix/2` preserves — is safe by construction because EVERY
  authority-key reader — inbound resolution and the
  reserved-materialization lookup alike — rides the same authority-key
  accelerator plus canonical fallback contract in `SalixIM.ProviderIdentity`:
  keys are genuinely advisory, a missing key falls back to the
  compatibility scan, and the lazy repair re-certifies unique
  identities on the next miss. Duplicate GROUPS are reported but never
  auto-resolved — which record survives is an operator decision on the
  canonical records.

  The audit is fail-closed: any LIST/GET storage fault halts the run,
  so a verdict is never computed from a partially readable corpus. And
  because a foreground release/reservation can replace a key between the
  verdict and the delete, `fix/2` deletes CONDITIONALLY on the etag
  observed at classification and requires the caller to assert an
  explicit no-writer maintenance gate: a key that changed under the
  audit is skipped (reported `changed`), never clobbered — and a
  `changed > 0` result means the no-writer assertion was violated, so
  the operator procedure must re-run rather than proceed.
  """

  alias SalixIM.ProviderIdentity
  alias SalixStore.{Keys, S3}

  @providers ~w(slack feishu)

  @doc """
  Classify every authority key against the canonical corpus. Returns
  `{:ok, report}` where `report.deprecated` entries each carry the etag
  observed here, for a later conditional `fix/2`.
  """
  def audit do
    with {:ok, census, malformed_records, misaddressed} <- canonical_census(),
         {:ok, keys} <- audit_keys(census) do
      {certified, deprecated} = Enum.split_with(keys, &(&1.status == :certified))

      {:ok,
       %{
         certified: certified,
         deprecated: deprecated,
         duplicate_groups:
           census
           |> Enum.filter(fn {_identity, entries} -> length(entries) > 1 end)
           |> Map.new(),
         malformed_records: malformed_records,
         misaddressed_records: misaddressed
       }}
    end
  end

  @doc """
  Delete the deprecated keys from `report` — every class except
  `:duplicate` owners — conditional on the etag
  observed at classification. Requires `no_writer_gate: true` — the
  operator's assertion that the run happens in a maintenance window with
  no active writers, since on a non-atomic backend the conditional
  delete narrows but cannot fully close the verdict→delete window.
  `:duplicate` keys are NOT deleted (see above); they are counted in
  `preserved_duplicates`. Returns
  `{:ok, %{deleted: n, changed: n, preserved_duplicates: n}}`; `changed` counts keys that
  a writer replaced (etag moved) and were therefore left intact — any
  nonzero value disproves the no-writer assertion and the procedure
  must re-run from a fresh audit.
  """
  def fix(report, opts \\ []) do
    if Keyword.get(opts, :no_writer_gate, false) do
      # :duplicate keys are deprecated but NEVER auto-deleted (round-12):
      # an explicit key naming the intended record among duplicates is
      # the only thing steering the mutation-capable reserved reader at
      # that record instead of "first physical sibling" — destroying it
      # before the operator settles the duplicates trades a durable
      # election problem for a mutation-targeting one. The clean gate
      # still fails while any duplicate group exists.
      {deletable, preserved} = Enum.split_with(report.deprecated, &(&1.status != :duplicate))

      with {:ok, counts} <- delete_deprecated(deletable) do
        {:ok, Map.put(counts, :preserved_duplicates, length(preserved))}
      end
    else
      {:error, :no_writer_gate_required}
    end
  end

  @doc """
  Convenience for the operator entrypoints: `audit/0`, then (when
  `fix: true`) `fix/2` with the remaining options. Merges the fix
  counts into the report.
  """
  def run(opts \\ []) do
    with {:ok, report} <- audit() do
      if Keyword.get(opts, :fix, false) do
        with {:ok, counts} <- fix(report, opts) do
          {:ok, Map.merge(report, counts)}
        end
      else
        {:ok, report}
      end
    end
  end

  @doc """
  Inspect-safe one-line rendering of a duplicate group entry — canonical
  bodies are untrusted data and may carry non-binary coordinates.
  """
  def format_duplicate({{provider, identity}, entries}) do
    carriers =
      entries
      |> Enum.map(fn {physical_key, _rec} -> physical_key end)
      |> Enum.sort()
      |> Enum.join(", ")

    "duplicate identity #{provider}:#{identity} carried by #{carriers}"
  end

  # {provider, trimmed app_id} => [{physical_key, rec}], live records
  # only — the write protocol's own conflict definition
  # (`ProviderIdentity.ensure_available/3`), carrying each record's LIST key so
  # certification judges physical addresses, never body claims.
  defp canonical_census do
    walk_prefix(Keys.ctl_im_connects_all_prefix(), {%{}, 0, []}, fn key,
                                                                    {census, malformed, mis} ->
      case S3.get(key) do
        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, rec} when is_map(rec) ->
              {census, mis} = add_to_census(census, mis, key, rec)
              {:ok, {census, malformed, mis}}

            _ ->
              {:ok, {census, malformed + 1, mis}}
          end

        {:error, :not_found} ->
          {:ok, {census, malformed, mis}}

        {:error, reason} ->
          {:error, {:audit_scan_failed, key, reason}}
      end
    end)
    |> case do
      {:ok, {census, malformed, mis}} -> {:ok, census, malformed, Enum.reverse(mis)}
      {:error, _} = error -> error
    end
  end

  defp add_to_census(census, mis, key, rec) do
    provider = rec["provider"]
    app_id = rec["app_id"]

    if provider in @providers and is_binary(app_id) and String.trim(app_id) != "" and
         is_nil(rec["deleted_at"]) do
      census =
        Map.update(census, {provider, String.trim(app_id)}, [{key, rec}], &[{key, rec} | &1])

      mis =
        case ProviderIdentity.repair_coordinates(rec, key) do
          {:ok, _group, _connect} -> mis
          :misaddressed -> [key | mis]
        end

      {census, mis}
    else
      {census, mis}
    end
  end

  defp audit_keys(census) do
    Enum.reduce_while(@providers, {:ok, []}, fn provider, {:ok, acc} ->
      case audit_provider_keys(provider, census) do
        {:ok, keys} -> {:cont, {:ok, acc ++ keys}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp audit_provider_keys(provider, census) do
    walk_prefix(Keys.ctl_im_provider_identities_prefix(provider), [], fn key, acc ->
      case S3.get(key) do
        {:ok, %{body: body, etag: etag}} ->
          {:ok, [classify_key(provider, key, body, etag, census) | acc]}

        {:error, :not_found} ->
          {:ok, acc}

        {:error, reason} ->
          {:error, {:audit_scan_failed, key, reason}}
      end
    end)
  end

  defp classify_key(provider, key, body, etag, census) do
    with {:ok, obj} when is_map(obj) <- Jason.decode(body),
         {:ok, identity} <- ProviderIdentity.reachable_identity(provider, key, obj),
         {:ok, target} <- ProviderIdentity.authority_target(provider, identity, obj) do
      status = classify_status(provider, identity, target, census)
      key_entry(key, etag, provider, identity, status)
    else
      _ -> key_entry(key, etag, provider, nil, :malformed)
    end
  end

  # Certified iff the fast path would two-GET-hit through this key: the
  # sole live carrier's PHYSICAL storage key is what the key addresses,
  # and its app_id survives the exact canonical revalidation.
  defp classify_status(provider, identity, target, census) do
    case Map.get(census, {provider, identity}, []) do
      [] ->
        :dangling

      [{physical_key, rec}] ->
        if target == physical_key and rec["app_id"] == identity,
          do: :certified,
          else: :mismatched

      _many ->
        :duplicate
    end
  end

  defp key_entry(key, etag, provider, identity, status) do
    %{key: key, etag: etag, provider: provider, identity: identity, status: status}
  end

  defp delete_deprecated(deprecated) do
    Enum.reduce_while(deprecated, {:ok, %{deleted: 0, changed: 0}}, fn entry, {:ok, acc} ->
      case S3.delete(entry.key, if_match: entry.etag) do
        :ok ->
          {:cont, {:ok, %{acc | deleted: acc.deleted + 1}}}

        {:error, :not_found} ->
          {:cont, {:ok, %{acc | deleted: acc.deleted + 1}}}

        # The object was replaced by a foreground writer between the
        # verdict and now: leave the new live object intact.
        {:error, :precondition_failed} ->
          {:cont, {:ok, %{acc | changed: acc.changed + 1}}}

        {:error, reason} ->
          {:halt, {:error, {:audit_fix_failed, entry.key, reason}}}
      end
    end)
  end

  defp walk_prefix(prefix, acc, fun), do: walk_prefix(prefix, nil, acc, fun)

  defp walk_prefix(prefix, token, acc, fun) do
    opts = if token, do: [continuation_token: token], else: []

    case S3.list(prefix, opts) do
      {:ok, %{objects: objects, next: next}} ->
        case reduce_objects(objects, acc, fun) do
          {:ok, acc} when is_binary(next) -> walk_prefix(prefix, next, acc, fun)
          {:ok, acc} -> {:ok, acc}
          {:error, _} = error -> error
        end

      {:error, reason} ->
        {:error, {:audit_scan_failed, prefix, reason}}
    end
  end

  defp reduce_objects(objects, acc, fun) do
    Enum.reduce_while(objects, {:ok, acc}, fn %{key: key}, {:ok, acc} ->
      case fun.(key, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
