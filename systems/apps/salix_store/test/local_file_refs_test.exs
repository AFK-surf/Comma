defmodule SalixStore.LocalFileRefsTest do
  use SystemsClock.Case, async: false

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
    do: "lfi1_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(32), padding: false)
end
