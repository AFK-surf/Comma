defmodule SalixStore.TriageKeys do
  @moduledoc """
  Logical PostgreSQL record addresses for native Triage.

  These are not S3 object keys. `SalixStore.TriageRecordStore` resolves each
  closed key shape to its protocol-owned typed PostgreSQL table; the
  slash-separated form preserves deterministic cursor contracts without
  creating a generic key/value persistence boundary.
  """

  alias SalixStore.Crypto

  @prefix "triage/engine-v2/"
  @default_namespace "bft-native-triage"

  @doc "Product-owned namespace for the native Triage runtime and read model."
  @spec default_namespace() :: String.t()
  def default_namespace, do: @default_namespace

  def owned?(key) when is_binary(key), do: String.starts_with?(key, @prefix)
  def owned?(_key), do: false

  @doc "Stable PostgreSQL partition identity for one logical Triage namespace."
  @spec namespace_key(String.t()) :: String.t()
  def namespace_key(namespace) when is_binary(namespace),
    do: Crypto.hex("engine-v2:" <> namespace)

  def ctl_im_triage_projection_marker(namespace, receipt_ref),
    do: namespace_prefix(namespace) <> "projections/#{Crypto.hex(receipt_ref)}.json"

  def ctl_im_triage_source_alias(namespace, source_message_ref),
    do: namespace_prefix(namespace) <> "source_aliases/#{Crypto.hex(source_message_ref)}.json"

  def ctl_im_triage_buckets_prefix(namespace), do: namespace_prefix(namespace) <> "buckets/"

  def ctl_im_triage_bucket(namespace, bucket_identity),
    do: ctl_im_triage_buckets_prefix(namespace) <> "#{Crypto.hex(bucket_identity)}.json"

  def ctl_im_triage_bucket_seal(namespace, bucket_identity, generation),
    do:
      namespace_prefix(namespace) <>
        "seals/#{Crypto.hex(bucket_identity)}/#{Crypto.hex(generation)}.json"

  def ctl_im_triage_bucket_seals_prefix(namespace), do: namespace_prefix(namespace) <> "seals/"

  def ctl_im_triage_ledger_run(namespace, run_id),
    do: namespace_prefix(namespace) <> "ledger/runs/#{run_id}.json"

  def ctl_im_triage_ledger_runs_prefix(namespace),
    do: namespace_prefix(namespace) <> "ledger/runs/"

  def ctl_im_triage_run_correlation(namespace, selector_kind, selector_sha256, run_id),
    do:
      ctl_im_triage_run_correlations_prefix(namespace, selector_kind, selector_sha256) <>
        run_id <> ".json"

  def ctl_im_triage_run_correlations_prefix(namespace, selector_kind, selector_sha256),
    do:
      namespace_prefix(namespace) <>
        "ledger/correlations/#{selector_kind}/#{selector_sha256}/"

  def ctl_im_triage_run_time_index_entry(namespace, created_at, run_id),
    do: ctl_im_triage_run_time_index_prefix(namespace) <> "#{created_at}/#{run_id}.json"

  def ctl_im_triage_run_time_index_prefix(namespace),
    do: namespace_prefix(namespace) <> "ledger/by_time/"

  def ctl_im_triage_activity_index_entry(namespace, identity_scope_sha256, created_at, run_id),
    do:
      ctl_im_triage_activity_index_prefix(namespace, identity_scope_sha256) <>
        "#{created_at}/#{run_id}.json"

  def ctl_im_triage_activity_index_prefix(namespace, identity_scope_sha256),
    do: namespace_prefix(namespace) <> "ledger/activity/#{identity_scope_sha256}/"

  def ctl_im_triage_replay(namespace, run_id),
    do: namespace_prefix(namespace) <> "replay/#{run_id}.json"

  def ctl_im_triage_lifecycle_event(namespace, run_id, event_id),
    do: namespace_prefix(namespace) <> "lifecycle/#{run_id}/#{event_id}.json"

  def ctl_im_triage_lifecycle_events_prefix(namespace, run_id),
    do: namespace_prefix(namespace) <> "lifecycle/#{run_id}/"

  def ctl_im_triage_late_result(namespace, run_id, observation_id),
    do: namespace_prefix(namespace) <> "ledger/late/#{run_id}/#{observation_id}.json"

  def ctl_im_triage_late_results_prefix(namespace),
    do: namespace_prefix(namespace) <> "ledger/late/"

  def ctl_im_triage_receipt_recovery_lease(namespace),
    do: namespace_prefix(namespace) <> "receipt_recovery_lease.json"

  defp namespace_prefix(namespace),
    do: @prefix <> namespace_key(namespace) <> "/"
end
