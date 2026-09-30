defmodule SalixWeb.VoiceApiKeysTest do
  @moduledoc """
  Voice agent API keys (docs/messaging-voice.md): a second kind of the Group
  API Key record with its own prefix and cap, refused on every surface but
  the voice routes, and revoked to live calls through `:pg`.
  """
  use ExUnit.Case, async: false

  alias Salix.Control.{GroupApiKeys, Groups}

  setup do
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_web, :api_token, "test-token")
    SalixStore.Repo.query!("DELETE FROM agent_group_api_keys")

    on_exit(fn ->
      if prev_api_token,
        do: Application.put_env(:salix_web, :api_token, prev_api_token),
        else: Application.delete_env(:salix_web, :api_token)
    end)

    tenant_id = req(:post, "/v1/admin/tenants", json: %{name: "Voice Keys"}).body["tenant_id"]

    tenant_key =
      req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"}).body["key"]

    group = req_as(tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Voice"}).body

    {:ok, tenant_id: tenant_id, tenant_key: tenant_key, group_id: group["group_id"]}
  end

  test "the kind column defaults existing rows to inbound and rejects unknown kinds", ctx do
    assert {:ok, inbound} =
             GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "Old"}, "salix_admin")

    assert inbound["kind"] == "inbound"

    assert_raise Postgrex.Error, ~r/agent_group_api_keys_kind_check/, fn ->
      SalixStore.Repo.query!("UPDATE agent_group_api_keys SET kind = 'other' WHERE key_id = $1", [
        inbound["key_id"]
      ])
    end
  end

  test "voice keys have their own prefix, cap and validation", ctx do
    assert {:ok, voice} =
             GroupApiKeys.create(
               ctx.group_id,
               ctx.tenant_id,
               %{"name" => "Kiosk"},
               "salix_admin",
               "voice"
             )

    assert "salix_vk_" <> _ = voice["key"]
    assert voice["kind"] == "voice"
    assert {:ok, %{"kind" => "voice"}} = GroupApiKeys.validate(voice["key"])

    # A voice plaintext presented with the inbound prefix finds nothing.
    "salix_vk_" <> rest = voice["key"]
    assert GroupApiKeys.validate("salix_gk_" <> rest) == {:error, :unauthorized}

    # Inbound and voice listings and caps are separate.
    assert {:ok, []} = GroupApiKeys.list(ctx.group_id, ctx.tenant_id)
    assert {:ok, [_]} = GroupApiKeys.list(ctx.group_id, ctx.tenant_id, "voice")

    for n <- 2..GroupApiKeys.max_keys_per_group() do
      assert {:ok, _} =
               GroupApiKeys.create(
                 ctx.group_id,
                 ctx.tenant_id,
                 %{"name" => "v#{n}"},
                 "salix_admin",
                 "voice"
               )
    end

    assert {:error, {:conflict, message}} =
             GroupApiKeys.create(
               ctx.group_id,
               ctx.tenant_id,
               %{"name" => "over"},
               "salix_admin",
               "voice"
             )

    assert message =~ "voice"

    assert {:ok, %{"kind" => "inbound"}} =
             GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "in"}, "salix_admin")

    # A management call of one kind cannot touch a key of the other.
    assert {:error, :not_found} =
             GroupApiKeys.update(ctx.group_id, ctx.tenant_id, voice["key_id"], %{"name" => "x"})
  end

  test "a Router cannot mint a voice key", ctx do
    assert {:error, {:bad_request, _}} =
             GroupApiKeys.create(
               ctx.group_id,
               ctx.tenant_id,
               %{"name" => "Injected"},
               "agent:agt_1",
               "voice"
             )
  end

  # Group deletion ends live calls through `SalixVoice.revoke_group/1`; the
  # session tests in voice_socket_test.exs and twilio_voice_test.exs cover it.
  test "disable, delete and a new expiry notify live calls on the key", ctx do
    {:ok, key} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "K"}, "salix_admin", "voice")

    key_id = key["key_id"]
    :ok = :pg.join(SalixVoice.PG, {:voice_key, key_id}, self())
    on_exit(fn -> :pg.leave(SalixVoice.PG, {:voice_key, key_id}, self()) end)

    expires_at = System.system_time(:second) + 3_600

    assert {:ok, _} =
             GroupApiKeys.update(
               ctx.group_id,
               ctx.tenant_id,
               key_id,
               %{"expires_at" => expires_at},
               "voice"
             )

    expires_at_ms = expires_at * 1000
    assert_receive {:voice_key_expiry, ^key_id, ^expires_at_ms}

    assert {:ok, _} =
             GroupApiKeys.update(
               ctx.group_id,
               ctx.tenant_id,
               key_id,
               %{"expires_at" => nil},
               "voice"
             )

    assert_receive {:voice_key_expiry, ^key_id, nil}

    assert {:ok, _} =
             GroupApiKeys.update(
               ctx.group_id,
               ctx.tenant_id,
               key_id,
               %{"status" => "disabled"},
               "voice"
             )

    assert_receive {:voice_key_revoked, ^key_id}

    assert :ok = GroupApiKeys.delete(ctx.group_id, ctx.tenant_id, key_id, "voice")
    assert_receive {:voice_key_revoked, ^key_id}

    {:ok, other} =
      GroupApiKeys.create(ctx.group_id, ctx.tenant_id, %{"name" => "K2"}, "salix_admin", "voice")

    assert :ok = Groups.delete(ctx.group_id, ctx.tenant_id)
    assert GroupApiKeys.validate(other["key"]) == {:error, :unauthorized}
  end

  test "tenant routes manage voice keys; each kind opens only its own surface", ctx do
    base = "/v1/runtime/agent-groups/#{ctx.group_id}/voice/api-keys"
    minted = req_as(ctx.tenant_key, :post, base, json: %{name: "CLI"})
    assert minted.status == 201
    assert "salix_vk_" <> _ = voice = minted.body["key"]
    assert minted.body["created_by"] == "tenant_api"

    listed = req_as(ctx.tenant_key, :get, base)
    assert [%{"key_id" => key_id, "kind" => "voice"}] = listed.body
    refute Map.has_key?(hd(listed.body), "key_hash")

    assert req_as(
             ctx.tenant_key,
             :get,
             "/v1/runtime/agent-groups/#{ctx.group_id}/router/api-keys"
           ).body == []

    inbound =
      req_as(ctx.tenant_key, :post, "/v1/runtime/agent-groups/#{ctx.group_id}/router/api-keys",
        json: %{name: "Zendesk"}
      ).body["key"]

    # A voice key never opens the Router inbox or a tenant route.
    assert req_as(voice, :post, "/v1/agent-groups/#{ctx.group_id}/router/post-message",
             json: %{text: "hi", source_message_id: "v1"}
           ).status == 401

    assert req_as(voice, :get, "/v1/runtime/agent-groups").status == 401

    # An inbound key never opens the voice routes.
    assert req_as(inbound, :get, "/v1/agent-groups/#{ctx.group_id}/voice").status == 401
    assert req_as(ctx.tenant_key, :get, "/v1/agent-groups/#{ctx.group_id}/voice").status == 401

    ready = req_as(voice, :get, "/v1/agent-groups/#{ctx.group_id}/voice")
    assert ready.status == 200
    assert ready.body["subprotocol"] == "comma.voice.v1"
    assert Enum.sort(ready.body["audio_formats"]) == ["pcm16_24k", "pcmu_8k"]

    # The key's Group must be the path Group.
    other = req_as(ctx.tenant_key, :post, "/v1/runtime/agent-groups", json: %{name: "Other"}).body
    assert req_as(voice, :get, "/v1/agent-groups/#{other["group_id"]}/voice").status == 401

    patched = req_as(ctx.tenant_key, :patch, base <> "/" <> key_id, json: %{status: "disabled"})
    assert patched.status == 200
    assert req_as(voice, :get, "/v1/agent-groups/#{ctx.group_id}/voice").status == 401

    assert req_as(ctx.tenant_key, :delete, base <> "/" <> key_id).status == 200
    assert req_as(ctx.tenant_key, :get, base).body == []
  end

  defp req(method, path, opts), do: req_as("test-token", method, path, opts)

  defp req_as(token, method, path, opts \\ []) do
    headers = [{"authorization", "Bearer " <> token}]

    Req.request!(
      [
        method: method,
        url: SalixWeb.Application.base_url() <> path,
        headers: headers,
        retry: false
      ] ++
        opts
    )
  end
end
