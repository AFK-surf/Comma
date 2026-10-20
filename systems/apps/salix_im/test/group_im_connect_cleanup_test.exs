defmodule SalixIM.GroupIMConnectCleanupTest do
  use SystemsClock.Case, async: false

  alias SalixIM.{ProviderConnects, ProviderIdentity}
  alias SalixStore.{CasRecord, Ids, Keys, S3}

  setup do
    previous = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_store, :s3_backend, previous),
        else: SystemsRuntime.delete_env(:salix_store, :s3_backend)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    %{tenant: tenant, group: Ids.new_group_id(tenant)}
  end

  defp seed(tenant, group, provider, extra \\ %{}) do
    id = Ids.new_connect_id()
    identity = "app-#{id}"

    rec =
      Map.merge(
        %{
          "tenant_id" => tenant,
          "group_id" => group,
          "connect_id" => id,
          "provider" => provider,
          "app_id" => identity,
          "bot_user_id" => identity
        },
        extra
      )

    assert {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group, id), rec)
    assert :ok = ProviderIdentity.reserve_provider(provider, identity, tenant, group, id)
    rec
  end

  test "orphan cleanup releases active and disabled identities across providers", ctx do
    records =
      for provider <- ~w(feishu slack wechat), disabled <- [nil, 1] do
        seed(ctx.tenant, ctx.group, provider, %{"disabled_at" => disabled})
      end

    other_group = Ids.new_group_id(ctx.tenant)
    other = seed(ctx.tenant, other_group, "feishu")

    assert :ok = ProviderConnects.delete_group_im_connects(ctx.tenant, ctx.group)

    for rec <- records do
      assert {:ok, deleted} = CasRecord.get(Keys.ctl_im_connect(ctx.group, rec["connect_id"]))
      assert is_integer(deleted["deleted_at"])
      if rec["provider"] == "slack", do: assert(is_binary(deleted["connect_generation"]))

      key = Keys.ctl_im_provider_identity(rec["provider"], rec["app_id"])

      if rec["provider"] == "wechat" do
        assert {:ok, %{"released_at" => released}} = CasRecord.get(key)
        assert is_integer(released)
      else
        assert {:error, :not_found} = CasRecord.get(key)
        assert :ok = ProviderIdentity.ensure_available(rec["provider"], rec["app_id"])
      end
    end

    assert {:ok, ^other} = CasRecord.get(Keys.ctl_im_connect(other_group, other["connect_id"]))
    assert :ok = ProviderConnects.delete_group_im_connects(ctx.tenant, ctx.group)
  end

  test "cleanup cannot follow a forged record into another group", ctx do
    other = seed(ctx.tenant, Ids.new_group_id(ctx.tenant), "feishu")
    key = Keys.ctl_im_connect(ctx.group, other["connect_id"])
    assert {:ok, _} = CasRecord.create(key, other)

    assert {:error, :invalid_connect_record} =
             ProviderConnects.delete_group_im_connects(ctx.tenant, ctx.group)

    assert {:ok, ^other} =
             CasRecord.get(Keys.ctl_im_connect(other["group_id"], other["connect_id"]))

    assert {:error, :not_found} =
             ProviderConnects.delete_group_im_connects(Ids.new_tenant_id(), ctx.group)
  end
end
