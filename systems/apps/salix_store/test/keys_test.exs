defmodule SalixStore.TriageKeysTest do
  use ExUnit.Case, async: true

  alias SalixStore.{Crypto, TriageKeys}

  test "triage engine state uses a dedicated PostgreSQL address family" do
    logical_namespace = "staging-triage"
    legacy_hash = Crypto.hex(logical_namespace)
    engine_hash = Crypto.hex("engine-v2:" <> logical_namespace)

    assert TriageKeys.ctl_im_triage_buckets_prefix(logical_namespace) ==
             "triage/engine-v2/#{engine_hash}/buckets/"

    refute String.contains?(
             TriageKeys.ctl_im_triage_buckets_prefix(logical_namespace),
             "triage/engine-v2/#{legacy_hash}/"
           )

    for key <- [
          TriageKeys.ctl_im_triage_projection_marker(logical_namespace, "receipt"),
          TriageKeys.ctl_im_triage_bucket_seals_prefix(logical_namespace),
          TriageKeys.ctl_im_triage_ledger_runs_prefix(logical_namespace),
          TriageKeys.ctl_im_triage_replay(logical_namespace, "run"),
          TriageKeys.ctl_im_triage_receipt_recovery_lease(logical_namespace)
        ] do
      assert String.starts_with?(key, "triage/engine-v2/#{engine_hash}/")
    end
  end
end
