defmodule SalixIM.LarkSuiteTriageAdminTest do
  use SystemsClock.Case, async: false

  alias SalixIM.LarkSuiteTriage.Admin
  alias SalixStore.{CasRecord, Ids, Keys, Repo}

  setup do
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    :ok = SalixStore.S3.Fake.reset()

    Repo.query!(
      "TRUNCATE lark_suite_triage_sources, lark_suite_triage_chats, lark_suite_triage_batches"
    )

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    router_id = "agt_router_#{SystemsRuntime.Proc.unique_integer([:positive])}"

    {:ok, _group} =
      CasRecord.create(Keys.ctl_group(group_id), %{
        "group_id" => group_id,
        "tenant_id" => tenant_id,
        "name" => "研发部",
        "router_agent_id" => router_id,
        "router_conversation_id" => "cnv1_router_#{group_id}"
      })

    {:ok, tenant_id: tenant_id, group_id: group_id, router_id: router_id}
  end

  defp put_connect(group_id, tenant_id, connect_id, overrides) do
    connect =
      Map.merge(
        %{
          "provider" => "feishu",
          "tenant_id" => tenant_id,
          "group_id" => group_id,
          "connect_id" => connect_id,
          "app_id" => "cli_" <> connect_id,
          "app_name" => "Bot " <> connect_id,
          "app_secret" => "secret",
          "bot_open_id" => "ou_bot_" <> connect_id,
          "status" => "connected",
          "created_at" => 1,
          "updated_at" => 1
        },
        overrides
      )

    {:ok, _} = CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), connect)
    connect
  end

  test "overview excludes owner_only personal connects for both feishu and lark", ctx do
    put_connect(ctx.group_id, ctx.tenant_id, "con_feishu_team", %{"provider" => "feishu"})

    put_connect(ctx.group_id, ctx.tenant_id, "con_feishu_personal", %{
      "provider" => "feishu",
      "owner_only" => true
    })

    put_connect(ctx.group_id, ctx.tenant_id, "con_lark_team", %{"provider" => "lark"})

    put_connect(ctx.group_id, ctx.tenant_id, "con_lark_personal", %{
      "provider" => "lark",
      "owner_only" => true
    })

    assert {:ok, %{connects: connects}} =
             Admin.overview(%{tenant_id: ctx.tenant_id, group_id: ctx.group_id})

    ids = Enum.map(connects, & &1.connect_id) |> Enum.sort()
    assert ids == ["con_feishu_team", "con_lark_team"]
  end

  for provider <- ~w(feishu lark) do
    @provider provider

    test "#{provider}: set_source refuses enabling a connect missing bot_open_id, but allows disabling",
         ctx do
      connect_id = "con_#{@provider}_nobot"

      put_connect(ctx.group_id, ctx.tenant_id, connect_id, %{
        "provider" => @provider,
        "bot_open_id" => ""
      })

      assert {:error, :bot_identity_missing} =
               Admin.set_source(%{
                 tenant_id: ctx.tenant_id,
                 group_id: ctx.group_id,
                 connect_id: connect_id,
                 enabled: true,
                 updated_by: "usr_admin"
               })

      assert {:ok, %{enabled: false}} =
               Admin.set_source(%{
                 tenant_id: ctx.tenant_id,
                 group_id: ctx.group_id,
                 connect_id: connect_id,
                 enabled: false,
                 updated_by: "usr_admin"
               })
    end
  end
end
