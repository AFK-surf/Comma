defmodule Salix.Control.GroupApiKeysTest do
  @moduledoc """
  Agent group inbound API keys (docs/product-features.md):
  the record, its lifecycle, and what a presented key resolves to.
  """
  use ExUnit.Case, async: false

  alias Salix.Control.{GroupApiKeys, Groups, Tenants}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_store)
    end)

    {:ok, tenant} = Tenants.create(%{"name" => "Keys"})
    {:ok, group} = Groups.create(%{"name" => "Inbox"}, tenant["tenant_id"])

    {:ok, tenant_id: tenant["tenant_id"], group_id: group["group_id"]}
  end

  test "a key is minted once in plaintext and listed by its projection", ctx do
    assert {:ok, created} =
             GroupApiKeys.create(
               ctx.group_id,
               ctx.tenant_id,
               %{"name" => "Zendesk"},
               "tenant_api"
             )

    assert "salix_gk_" <> _ = created["key"]
    assert String.length(created["key"]) > 40
    assert "gak_" <> _ = created["key_id"]
    assert created["prefix"] == String.slice(created["key"], 0, 15)
    assert created["status"] == "active"
    assert created["created_by"] == "tenant_api"
    assert created["expires_at"] == nil
    refute Map.has_key?(created, "key_hash")

    assert {:ok, [listed]} = GroupApiKeys.list(ctx.group_id, ctx.tenant_id)
    refute Map.has_key?(listed, "key")
    refute Map.has_key?(listed, "key_hash")
    assert listed["key_id"] == created["key_id"]
    assert listed["name"] == "Zendesk"
  end

  test "a presented key resolves only while active, unexpired, and its group exists", ctx do
    {:ok, created} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "Zendesk"}, "salix_admin")

    raw = created["key"]
    key_id = created["key_id"]

    assert {:ok, %{"key_id" => ^key_id, "group_id" => group_id}} = GroupApiKeys.validate(raw)
    assert group_id == ctx.group_id

    assert GroupApiKeys.validate("salix_gk_nope") == {:error, :unauthorized}

    assert GroupApiKeys.validate("salix_" <> String.slice(raw, 9..-1//1)) ==
             {:error, :unauthorized}

    assert GroupApiKeys.validate(nil) == {:error, :unauthorized}

    assert {:ok, %{"status" => "disabled"}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{"status" => "disabled"})

    assert GroupApiKeys.validate(raw) == {:error, :unauthorized}

    assert {:ok, %{"status" => "active"}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{"status" => "active"})

    assert {:ok, _} = GroupApiKeys.validate(raw)

    # Expiry is validated against the clock at write time, so a past instant
    # cannot be stored; an expired row is simulated directly.
    assert {:error, {:bad_request, "expires_at must be in the future"}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{"expires_at" => 1})

    SalixStore.Repo.query!(
      "UPDATE agent_group_api_keys SET expires_at = now() - interval '1 minute' WHERE key_id = $1",
      [key_id]
    )

    assert GroupApiKeys.validate(raw) == {:error, :unauthorized}

    assert {:ok, %{"expires_at" => nil}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{"expires_at" => nil})

    assert {:ok, _} = GroupApiKeys.validate(raw)

    assert :ok = Groups.delete(ctx.group_id, ctx.tenant_id)
    assert GroupApiKeys.validate(raw) == {:error, :unauthorized}
  end

  test "rename, re-expire, delete, and the per-group cap", ctx do
    {:ok, created} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "Old"}, "comma_user:u1")

    key_id = created["key_id"]
    later = System.system_time(:second) + 3_600

    assert {:ok, %{"name" => "New", "expires_at" => ^later}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{
               "name" => "New",
               "expires_at" => later
             })

    iso = DateTime.from_unix!(later + 60) |> DateTime.to_iso8601()

    assert {:ok, %{"expires_at" => expires_at}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{"expires_at" => iso})

    assert expires_at == later + 60

    assert {:error, {:bad_request, "status must be one of: active, disabled"}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{"status" => "gone"})

    assert {:error, {:bad_request, "unsupported field: prefix"}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{"prefix" => "x"})

    assert {:error, {:bad_request, "nothing to update"}} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, key_id, %{})

    assert {:error, :not_found} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, "gak_missing", %{"name" => "x"})

    # Another group's request cannot touch this key.
    {:ok, other} = Groups.create(%{"name" => "Other"}, ctx.tenant_id)

    assert {:error, :not_found} =
             GroupApiKeys.update(other["group_id"], ctx.tenant_id, key_id, %{"name" => "x"})

    assert :ok = GroupApiKeys.delete(other["group_id"], ctx.tenant_id, key_id)
    assert {:ok, [_still_there]} = GroupApiKeys.list(ctx.group_id, ctx.tenant_id)

    assert :ok = GroupApiKeys.delete(ctx.group_id, ctx.tenant_id, key_id)
    assert :ok = GroupApiKeys.delete(ctx.group_id, ctx.tenant_id, key_id)
    assert {:ok, []} = GroupApiKeys.list(ctx.group_id, ctx.tenant_id)
    assert GroupApiKeys.validate(created["key"]) == {:error, :unauthorized}

    for n <- 1..GroupApiKeys.max_keys_per_group() do
      assert {:ok, _} =
               GroupApiKeys.create(
                 ctx.group_id,
                 ctx.tenant_id,
                 %{"name" => "k#{n}"},
                 "tenant_api"
               )
    end

    assert {:error, {:conflict, _}} =
             GroupApiKeys.create(
               ctx.group_id,
               ctx.tenant_id,
               %{"name" => "one too many"},
               "tenant_api"
             )
  end

  test "creation validates its inputs", ctx do
    assert {:error, {:bad_request, "name is required"}} =
             GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{}, "tenant_api")

    assert {:error, {:bad_request, "name is required"}} =
             GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "   "}, "tenant_api")

    assert {:error, {:bad_request, _}} =
             GroupApiKeys.create(
               ctx.group_id,
               ctx.tenant_id,
               %{"name" => String.duplicate("n", 81)},
               "tenant_api"
             )

    assert {:error, {:bad_request, "invalid actor"}} =
             GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "x"}, "someone")

    assert {:error, {:bad_request, "invalid actor"}} =
             GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "x"}, "agent:")

    assert {:error, :not_found} =
             GroupApiKeys.create("grp1_0_0", ctx.tenant_id, %{"name" => "x"}, "tenant_api")

    {:ok, other_tenant} = Tenants.create(%{"name" => "Other"})

    assert {:error, :not_found} =
             GroupApiKeys.create(
               ctx.group_id,
               other_tenant["tenant_id"],
               %{"name" => "x"},
               "tenant_api"
             )
  end

  test "the information-flow principal wraps the creator", ctx do
    {:ok, from_comma} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "Comma"}, "comma_user:usr_1")

    assert GroupApiKeys.principal(from_comma) ==
             "api_key|#{from_comma["key_id"]}|comma_user|usr_1"

    {:ok, from_admin} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "Admin"}, "salix_admin")

    assert GroupApiKeys.principal(from_admin) == "api_key|#{from_admin["key_id"]}|system"

    # A Router mints keys for the systems it wires up to itself. Such a key
    # must not carry the Router's reach, or minting one would be a way to
    # manufacture authority the agent did not already hold.
    {:ok, from_agent} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "CI"}, "agent:agt_1")

    assert from_agent["created_by"] == "agent:agt_1"
    assert GroupApiKeys.principal(from_agent) == "api_key|#{from_agent["key_id"]}|system"

    assert GroupApiKeys.principal(%{}) == nil
  end

  test "last_used is written at most once a minute", ctx do
    {:ok, created} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "Zendesk"}, "tenant_api")

    key_id = created["key_id"]
    assert :ok = GroupApiKeys.touch_last_used(key_id)
    assert {:ok, [%{"last_used_at" => first}]} = GroupApiKeys.list(ctx.group_id, ctx.tenant_id)
    assert is_integer(first)

    SalixStore.Repo.query!(
      "UPDATE agent_group_api_keys SET last_used_at = now() - interval '10 seconds' WHERE key_id = $1",
      [key_id]
    )

    assert :ok = GroupApiKeys.touch_last_used(key_id)
    assert {:ok, [%{"last_used_at" => recent}]} = GroupApiKeys.list(ctx.group_id, ctx.tenant_id)
    assert recent <= System.system_time(:second) - 9

    assert :ok = GroupApiKeys.touch_last_used("gak_missing")
  end
end
