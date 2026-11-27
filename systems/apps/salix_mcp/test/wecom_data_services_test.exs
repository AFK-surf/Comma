defmodule SalixMCP.WeComDataServicesTest do
  @moduledoc """
  The WeCom (企业微信) AI bot's data abilities as built-in MCP definitions and
  system plugins: one hosted server and one key per ability, the key taken
  alone or from the address the admin console shows, and a read-only check
  call whose successful result carries WeCom's bad-key answer.
  """
  use ExUnit.Case, async: true

  alias SalixMCP.HostedServices

  @abilities ~w(msg mail doc todo schedule meeting disk contact)

  test "every ability has its own server, key and plugin" do
    definitions = Map.new(HostedServices.mcp_definitions(), &{&1["name"], &1})
    plugins = Map.new(HostedServices.plugin_definitions(), &{&1["plugin_id"], &1})

    ids =
      for ability <- @abilities do
        plugin = Map.fetch!(plugins, "wecom-" <> ability)
        [mcp] = plugin["setup"]["mcps"]
        [connection] = plugin["setup"]["connections"]
        key = "WECOM_" <> String.upcase(ability) <> "_APIKEY"

        assert connection["kind"] == "mcp_api_key"
        assert connection["config_key"] == key
        assert connection["credential_param"] == "apikey"
        assert plugin["ui"]["brand"] == "wecom"

        assert %{"tool" => tool} = connection["credential_check"]

        assert is_binary(tool)

        definition = Enum.find(Map.values(definitions), &(&1["mcp_id"] == mcp["mcp_id"]))
        [remote] = definition["server_metadata"]["remotes"]

        assert remote["url"] ==
                 "https://qyapi.weixin.qq.com/mcp/v2/bot/#{ability}?apikey={#{key}}"

        assert remote["variables_schema"] == %{key => %{"isRequired" => true, "isSecret" => true}}
        mcp["mcp_id"]
      end

    assert length(Enum.uniq(ids)) == length(@abilities)
    all_ids = Enum.map(HostedServices.mcp_definitions(), & &1["mcp_id"])
    assert length(Enum.uniq(all_ids)) == length(all_ids)
  end

  describe "a dead key in a successful result" do
    setup do
      [mcp_id: Enum.find(HostedServices.mcp_definitions(), &(&1["name"] == "企业微信日程"))["mcp_id"]]
    end

    test "is a failure that tells the agent to have the ability granted again", %{mcp_id: mcp_id} do
      # What the gateway makes of WeCom's answer to an expired or revoked key.
      result = %{
        "status" => "completed",
        "content" =>
          ~s({\n  "errcode": 850001,\n  "errmsg": "invalid api key, hint: [1794907017396170062161268]"\n})
      }

      assert %{"status" => "error", "error_class" => "credential_invalid", "content" => content} =
               SalixMCP.Gateway.credential_failure(result, %{"mcp_id" => mcp_id})

      assert %{"error" => "credential_invalid", "message" => message} = Jason.decode!(content)
      assert message =~ "grant the ability again"
      refute content =~ "hint"
    end

    test "leaves data and other servers' results alone", %{mcp_id: mcp_id} do
      data = %{"status" => "completed", "content" => ~s({"errcode": 0, "schedules": []})}
      assert SalixMCP.Gateway.credential_failure(data, %{"mcp_id" => mcp_id}) == data

      # The words in a mail or a document are data, even these.
      for text <- [
            "invalid api key",
            ~s({"errcode": 0, "mails": [{"subject": "invalid api key, errcode 850001"}]})
          ] do
        mail = %{"status" => "completed", "content" => text}
        assert SalixMCP.Gateway.credential_failure(mail, %{"mcp_id" => mcp_id}) == mail
      end

      other = %{"status" => "completed", "content" => ~s({"errcode": 850001})}

      assert SalixMCP.Gateway.credential_failure(other, %{"mcp_id" => "mcp1_0000000000000000014"}) ==
               other
    end
  end
end
