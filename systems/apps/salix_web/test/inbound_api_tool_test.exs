defmodule SalixWeb.InboundApiToolTest do
  @moduledoc """
  The Router configuring its own inbound API: minting a key for an external
  system, handing that system an address it can reach, and revoking it.

  The tools run through the real dispatcher against the real control plane, so
  what these tests assert is what an external service would actually present.
  """
  use ExUnit.Case, async: false

  alias Salix.Control.{GroupApiKeys, Groups, Tenants}

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_binding = Application.get_env(:salix_agent, :inbound_api_key_store_mod)
    prev_base = Application.get_env(:salix_web, :public_base_url)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")

    Application.put_env(
      :salix_agent,
      :inbound_api_key_store_mod,
      Salix.Bindings.AgentInboundApiKeys
    )

    Application.put_env(:salix_web, :public_base_url, "https://salix.example.test")

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_store)
      restore(:salix_agent, :inbound_api_key_store_mod, prev_binding)
      restore(:salix_web, :public_base_url, prev_base)
    end)

    {:ok, tenant} = Tenants.create(%{"name" => "Inbound API tools"})
    {:ok, group} = Groups.create(%{"name" => "Router group"}, tenant["tenant_id"])

    router =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(
        tenant["tenant_id"],
        group["group_id"],
        %{"role" => "router"}
      )

    %{
      router: router,
      tenant: tenant["tenant_id"],
      group: group["group_id"]
    }
  end

  test "a created key is usable by the external system it was minted for", ctx do
    result = invoke(ctx, "inbound_api.create", %{"name" => "Release pipeline"})
    refute result.error
    created = Jason.decode!(result.content)

    assert created["name"] == "Release pipeline"
    assert created["status"] == "active"
    assert "salix_gk_" <> _ = created["key"]

    assert created["post_message_url"] ==
             "https://salix.example.test/v1/agent-groups/#{ctx.group}/router/post-message"

    # The address and header the tool hands out are the ones the endpoint
    # actually accepts: the key resolves to this group, for this tenant.
    assert {:ok, record} = GroupApiKeys.validate(created["key"])
    assert record["group_id"] == ctx.group
    assert record["tenant_id"] == ctx.tenant

    assert created["request"]["url"] == created["post_message_url"]
    assert created["request"]["headers"]["Authorization"] == "Bearer " <> created["key"]
    assert created["request"]["example"] =~ created["post_message_url"]

    # A Router's key carries no authority of the Router's own.
    assert record["created_by"] == "agent:" <> ctx.router["agent_id"]
    assert GroupApiKeys.principal(record) == "api_key|#{record["key_id"]}|system"
  end

  test "plaintext is returned once and never by a listing", ctx do
    created = Jason.decode!(invoke(ctx, "inbound_api.create", %{"name" => "Sentry"}).content)

    listed = Jason.decode!(invoke(ctx, "inbound_api.list", %{}).content)
    assert [key] = listed["keys"]
    assert key["key_id"] == created["key_id"]
    assert key["name"] == "Sentry"
    assert key["post_message_url"] == created["post_message_url"]
    refute Map.has_key?(key, "key")
    refute Map.has_key?(key, "key_hash")
  end

  test "revoking stops the key the external system holds", ctx do
    created = Jason.decode!(invoke(ctx, "inbound_api.create", %{"name" => "Cron"}).content)
    assert {:ok, _} = GroupApiKeys.validate(created["key"])

    disabled =
      Jason.decode!(invoke(ctx, "inbound_api.revoke", %{"key_id" => created["key_id"]}).content)

    assert disabled["status"] == "disabled"
    assert GroupApiKeys.validate(created["key"]) == {:error, :unauthorized}

    # Deleting frees the slot the disabled record still occupies.
    deleted =
      Jason.decode!(
        invoke(ctx, "inbound_api.revoke", %{
          "key_id" => created["key_id"],
          "mode" => "delete"
        }).content
      )

    assert deleted["status"] == "deleted"
    assert Jason.decode!(invoke(ctx, "inbound_api.list", %{}).content)["keys"] == []
  end

  test "an unknown key_id is an actionable error, not a silent success", ctx do
    result = invoke(ctx, "inbound_api.revoke", %{"key_id" => "gak_missing"})
    assert result.error
    assert result.error_class == "inbound_api_key_not_found"
  end

  test "the per-group cap is reported as its own condition", ctx do
    for n <- 1..GroupApiKeys.max_keys_per_group() do
      assert {:ok, _} =
               GroupApiKeys.create(ctx.group, ctx.tenant, %{"name" => "k#{n}"}, "tenant_api")
    end

    result = invoke(ctx, "inbound_api.create", %{"name" => "one too many"})
    assert result.error
    assert result.error_class == "inbound_api_limit_reached"
    assert Jason.decode!(result.content)["message"] =~ "at most"
  end

  test "a Worker cannot mint a key for the group it runs in", ctx do
    worker =
      SalixAgent.TestSupport.create_legacy_control_agent_in_group!(
        ctx.tenant,
        ctx.group,
        %{"role" => "worker"}
      )

    worker_ctx = tool_ctx(worker, ctx.tenant, ctx.group)

    # The disclosure gate is the first refusal: the tool is Router-only, so a
    # Worker session cannot call it at all.
    refute SalixAgent.ToolDisclosure.callable?(worker_ctx, "inbound_api.create")

    # The tool refuses a Worker identity on its own, so a disclosure that ever
    # widened would still not mint a key.
    result = SalixAgent.Tools.InboundApi.create(%{"name" => "Worker attempt"}, worker_ctx)
    assert {:tool_failure, _content, "forbidden", _visibility, _message, []} = result
    assert {:ok, []} = GroupApiKeys.list(ctx.group, ctx.tenant)
  end

  test "another group's runtime context cannot reach these keys", ctx do
    {:ok, other} = Groups.create(%{"name" => "Other"}, ctx.tenant)

    result =
      [%{"id" => "inbound-api-test", "name" => "inbound_api.list", "args" => %{}}]
      |> SalixAgent.Tools.execute(tool_ctx(ctx.router, ctx.tenant, other["group_id"]))
      |> hd()

    assert result.error
    assert result.error_class == "forbidden"
  end

  test "the tools fail closed when no control-plane binding is attached", ctx do
    Application.put_env(:salix_agent, :inbound_api_key_store_mod, nil)

    result = invoke(ctx, "inbound_api.create", %{"name" => "Nowhere"})
    assert result.error
    assert result.error_class == "inbound_api_unavailable"
  end

  defp restore(app, key, value) do
    if is_nil(value),
      do: Application.delete_env(app, key),
      else: Application.put_env(app, key, value)
  end

  defp invoke(ctx, name, args) do
    [result] =
      SalixAgent.Tools.execute(
        [%{"id" => "inbound-api-test", "name" => name, "args" => args}],
        tool_ctx(ctx.router, ctx.tenant, ctx.group)
      )

    result
  end

  defp tool_ctx(agent, tenant_id, group_id) do
    ctx =
      %{
        agent_id: agent["agent_id"],
        tenant_id: tenant_id,
        group_id: group_id,
        session_id: agent["router_session_id"],
        role: agent["role"],
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      SalixAgent.ToolDisclosure.materialize(agent["role"], :internal, ctx)
    )
  end
end
