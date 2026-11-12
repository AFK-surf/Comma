defmodule SalixMCP.ChinaServices do
  @moduledoc """
  Official hosted MCP servers of services in mainland China.

  Each service becomes one built-in MCP definition (`SalixMCP.Builtins`) and
  one system plugin (`Salix.Control.Plugins`). Every server here answers MCP
  from outside mainland China. A service authenticates in one of three ways:

    * `{:url_key, key, label, help_url}`: the user's key is a URL parameter.
    * `{:bearer, key, label, help_url}`: the user's key is a Bearer token.
    * `:oauth`: MCP OAuth with dynamic client registration.

  A server that rejects a wrong key in its own way, or accepts any key until a
  tool runs, declares `check` (`Salix.Control.PluginSetup` credential checks):
  the texts it rejects a key with and, for the second kind, one read-only tool
  call to make with the new key. The map geocoding checks use one call of the
  key's quota; Gitee's user lookup is free.
  """

  @services [
    %{
      id: "amap",
      mcp_id: "mcp1_0000000000000000014",
      name: "高德地图",
      description: "Place search, geocoding, routes, and weather through AMap's official MCP.",
      url: "https://mcp.amap.com/mcp?key={AMAP_MAPS_API_KEY}",
      auth: {:url_key, "AMAP_MAPS_API_KEY", "Web服务 Key", "https://console.amap.com/dev/key/app"},
      check: %{"rejections" => ["INVALID_USER_KEY"]}
    },
    %{
      id: "baidu-maps",
      mcp_id: "mcp1_0000000000000000015",
      name: "百度地图",
      description:
        "Place search, geocoding, routes, and traffic through Baidu Maps' official MCP.",
      url: "https://mcp.map.baidu.com/mcp?ak={BAIDU_MAP_API_KEY}",
      auth: {:url_key, "BAIDU_MAP_API_KEY", "服务端 AK", "https://lbsyun.baidu.com/apiconsole/key"},
      check: %{
        "tool" => "map_geocode",
        "arguments" => %{"address" => "北京市"},
        "rejections" => ["Authentication failed"]
      }
    },
    %{
      id: "tencent-maps",
      mcp_id: "mcp1_0000000000000000016",
      name: "腾讯地图",
      description: "Place search, geocoding, and routes through Tencent Maps' official MCP.",
      url: "https://mcp.map.qq.com/mcp?key={TENCENT_MAP_API_KEY}",
      auth:
        {:url_key, "TENCENT_MAP_API_KEY", "WebService Key",
         "https://lbs.qq.com/dev/console/application/mine"},
      check: %{
        "tool" => "geocoder",
        "arguments" => %{"address" => "北京市"},
        "rejections" => ["Invalid Key"]
      }
    },
    %{
      id: "didi",
      mcp_id: "mcp1_0000000000000000017",
      name: "滴滴出行",
      description: "Estimate fares, call a car, and track rides through DiDi's official MCP.",
      url: "https://mcp.didichuxing.com/mcp-servers?key={DIDI_MCP_KEY}",
      auth: {:url_key, "DIDI_MCP_KEY", "MCP Key", "https://mcp.didichuxing.com/claw"},
      check: %{"rejections" => ["auth failed"]}
    },
    %{
      id: "luckin",
      mcp_id: "mcp1_0000000000000000018",
      name: "瑞幸咖啡",
      description:
        "Find stores, choose drinks, and order for pickup through Luckin's official MCP.",
      url: "https://gwmcp.lkcoffee.com/order/user/mcp",
      auth: {:bearer, "LUCKIN_MCP_TOKEN", "MCP Token", "https://open.lkcoffee.com/mcp"}
    },
    %{
      id: "qcc",
      mcp_id: "mcp1_0000000000000000019",
      name: "企查查",
      description: "Company registration, shareholders, and risk records through Qichacha's MCP.",
      url: "https://agent.qcc.com/mcp/company/stream",
      auth: {:bearer, "QCC_API_KEY", "API Key", "https://agent.qcc.com/guide"}
    },
    %{
      id: "zhipu-search",
      mcp_id: "mcp1_0000000000000000020",
      name: "智谱搜索",
      description: "Web search through Zhipu's official search MCP.",
      url: "https://open.bigmodel.cn/api/mcp/web_search_prime/mcp",
      auth: {:bearer, "ZHIPU_API_KEY", "API Key", "https://open.bigmodel.cn/usercenter/apikeys"},
      check: %{"rejections" => ["令牌已过期或验证不正确"]}
    },
    %{
      id: "gitee",
      mcp_id: "mcp1_0000000000000000021",
      name: "Gitee",
      description: "Repositories, issues, and pull requests through Gitee's hosted MCP.",
      url: "https://api.gitee.com/mcp",
      auth:
        {:bearer, "GITEE_ACCESS_TOKEN", "私人令牌",
         "https://gitee.com/profile/personal_access_tokens"},
      check: %{
        "tool" => "get_user_info",
        "arguments" => %{},
        "rejections" => ["Access token does not exist"]
      }
    },
    %{
      id: "tencent-docs",
      mcp_id: "mcp1_0000000000000000022",
      name: "腾讯文档",
      description: "Read and edit Tencent Docs through its official MCP.",
      url: "https://docs.qq.com/openapi/mcp",
      auth: :oauth
    },
    %{
      id: "flomo",
      mcp_id: "mcp1_0000000000000000023",
      name: "flomo",
      description: "Write and search flomo memos through flomo's official MCP.",
      url: "https://flomoapp.com/mcp",
      auth: :oauth
    },
    %{
      id: "pixso",
      mcp_id: "mcp1_0000000000000000024",
      name: "Pixso",
      description: "Read Pixso design files through Pixso's official remote MCP.",
      url: "https://pixso.cn/mcp",
      auth: :oauth
    }
  ]

  @doc "The built-in MCP definitions, one per service."
  def mcp_definitions, do: Enum.map(@services, &mcp_definition/1)

  @doc "The system plugin definitions, one per service."
  def plugin_definitions, do: Enum.map(@services, &plugin_definition/1)

  defp mcp_definition(service) do
    remote =
      Map.merge(
        %{
          "target_ref" => "remote:" <> service.id,
          "transport" => "streamable-http",
          "url" => service.url
        },
        remote_auth(service.auth)
      )

    %{
      "mcp_id" => service.mcp_id,
      "tenant_id" => "",
      "name" => service.name,
      "description" => service.description,
      "server_metadata" => %{
        "name" => service.name,
        "description" => service.description,
        "remotes" => [remote]
      },
      "supports_server" => true,
      "recommended_placement" => "server",
      "supported_placements" => ["server"],
      "declared_capabilities" => %{"tools" => true},
      "environment_requirements" => %{"server" => ["public_network"]},
      "trust" => %{"source" => "system_builtin"},
      "created_by" => "system"
    }
    |> Map.merge(
      if service.auth == :oauth,
        do: %{"auth_requirements" => %{service.id => ["oauth"]}},
        else: %{}
    )
  end

  defp remote_auth({:url_key, key, _label, _help_url}) do
    %{
      "variables_schema" => %{key => %{"isRequired" => true, "isSecret" => true}},
      "headers_schema" => %{}
    }
  end

  defp remote_auth({:bearer, key, _label, _help_url}) do
    %{
      "headers_schema" => %{
        "Authorization" => %{
          "isRequired" => true,
          "isSecret" => true,
          "value" => "Bearer ${#{key}}"
        }
      }
    }
  end

  defp remote_auth(:oauth), do: %{"headers_schema" => %{}}

  defp plugin_definition(service) do
    connection = connection(service)

    setup = %{
      "type" => "integration",
      "default_connection" => connection["id"],
      "connections" => [connection],
      "mcps" => [
        %{
          "mcp_id" => service.mcp_id,
          "alias" => service.id,
          "target_ref" => "remote:" <> service.id,
          "placement" => "server",
          "auth_refs" => [connection["id"]]
        }
      ]
    }

    # Comma connects required connections in order before it installs; an
    # API key arrives with the install request instead.
    setup =
      if service.auth == :oauth,
        do: Map.put(setup, "required_connections", [connection["id"]]),
        else: setup

    %{
      "plugin_id" => service.id,
      "name" => service.name,
      "description" => service.description,
      "ui" => %{"brand" => service.id, "category" => "中国服务"},
      "default_enabled" => false,
      "setup" => setup,
      "refs" => %{
        "tool_refs" => ["mcp.#{service.id}.*"],
        "mcp_refs" => [%{"mcp_id" => service.mcp_id}]
      }
    }
  end

  defp connection(%{auth: :oauth} = service) do
    %{
      "id" => service.id <> "-native",
      "kind" => "native_mcp_oauth",
      "label" => service.name <> " MCP OAuth",
      "scopes" => []
    }
  end

  defp connection(%{auth: {_placement, key, label, help_url}} = service) do
    %{
      "id" => service.id <> "-api-key",
      "kind" => "mcp_api_key",
      "label" => service.name <> " " <> label,
      "config_key" => key,
      "credential_label" => label,
      "help_url" => help_url
    }
    |> Map.merge(
      if check = Map.get(service, :check), do: %{"credential_check" => check}, else: %{}
    )
  end
end
