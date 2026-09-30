defmodule SalixStore.LocalFileRefsTest do
  use ExUnit.Case, async: false

  alias SalixStore.{LocalFileRefs, Repo}

  setup do
    Repo.query!("TRUNCATE local_file_refs")
    :ok
  end

  test "registered route transitions once to its exact message and then to revoked" do
    ref = local_ref()
    now = 1_900_000_000_000
    registration = registration(ref, now + 100)

    assert {:ok, %{"state" => "registered"}} =
             LocalFileRefs.insert_registration(registration)

    assert :ok =
             LocalFileRefs.bind(
               ref,
               "grp1_store",
               "cnv1_store",
               "msg1_store",
               "user_store",
               now + 1,
               now + 604_800_000
             )

    assert :ok =
             LocalFileRefs.bind(
               ref,
               "grp1_store",
               "cnv1_store",
               "msg1_store",
               "user_store",
               now + 2,
               now + 604_800_000
             )

    assert {:error, :local_file_ref_conflict} =
             LocalFileRefs.bind(
               ref,
               "grp1_store",
               "cnv1_store",
               "msg2_store",
               "user_store",
               now + 2,
               now + 604_800_000
             )

    assert :ok =
             LocalFileRefs.revoke(ref, "grp1_store", "user_store", "dev_store", now + 3)

    assert {:ok, %{"state" => "revoked", "message_id" => "msg1_store"}} =
             LocalFileRefs.get(ref)
  end

  test "cleanup is bounded and retires expired refs without permitting reuse" do
    now = 1_900_000_000_000

    expired_refs =
      for offset <- 1..3 do
        ref = local_ref()
        assert {:ok, _} = LocalFileRefs.insert_registration(registration(ref, now - offset - 1))
        ref
      end

    live_ref = local_ref()

    assert {:ok, _} =
             LocalFileRefs.insert_registration(registration(live_ref, now + 60_000))

    assert {:ok, 2} = LocalFileRefs.cleanup_expired(now, limit: 2)
    assert Repo.aggregate(LocalFileRefs.Row, :count) == 4
    assert {:ok, 1} = LocalFileRefs.cleanup_expired(now, limit: 2)
    assert {:ok, %{"state" => "registered"}} = LocalFileRefs.get(live_ref)

    for ref <- expired_refs do
      assert {:ok,
              %{
                "state" => "retired",
                "tenant_id" => "",
                "group_id" => "",
                "owner_user_id" => "",
                "stable_device_id" => ""
              }} = LocalFileRefs.get(ref)

      assert {:error, :local_file_ref_conflict} =
               LocalFileRefs.insert_registration(registration(ref, now + 60_000))
    end
  end

  test "cleanup expiry walk excludes permanent retired tombstones from its index" do
    now = 1_900_000_000_000

    Repo.query!("""
    INSERT INTO local_file_refs (
      ref_digest, version, tenant_id, group_id, owner_user_id, stable_device_id,
      state, created_at, expires_at, retired_at
    )
    SELECT
      md5(series::text), 1, '', '', '', '', 'retired',
      to_timestamp(1), to_timestamp(2), to_timestamp(3)
    FROM generate_series(1, 5000) AS series
    """)

    expired_ref = local_ref()

    assert {:ok, _} =
             LocalFileRefs.insert_registration(registration(expired_ref, now - 1))

    Repo.query!("ANALYZE local_file_refs")

    %{rows: plan_rows} =
      Repo.query!(
        """
        EXPLAIN (COSTS OFF)
        SELECT ref_digest
        FROM local_file_refs
        WHERE state IN ('registered', 'bound', 'revoked')
          AND expires_at <= to_timestamp($1::double precision / 1000)
        ORDER BY expires_at, ref_digest
        LIMIT 1000
        FOR UPDATE SKIP LOCKED
        """,
        [now]
      )

    plan = plan_rows |> List.flatten() |> Enum.join("\n")
    assert plan =~ "Index Scan using local_file_refs_active_expiry_idx"

    assert {:ok, 1} = LocalFileRefs.cleanup_expired(now)
    assert {:ok, 0} = LocalFileRefs.cleanup_expired(now)
  end

  defp registration(ref, expires_at) do
    %{
      "version" => 1,
      "local_file_ref" => ref,
      "tenant_id" => "tnt1_store",
      "group_id" => "grp1_store",
      "owner_user_id" => "user_store",
      "stable_device_id" => "dev_store",
      "state" => "registered",
      "created_at" => expires_at - 100,
      "expires_at" => expires_at
    }
  end

  defp local_ref,
    do: "lfi1_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
