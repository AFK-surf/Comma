defmodule SalixMCP.HostedServices do
  @moduledoc """
  Official hosted MCP servers: services in mainland China, listed under
  中国服务, and optional global services with a `category` of their own.

  Each service becomes one built-in MCP definition (`SalixMCP.Builtins`) and
  one system plugin (`Salix.Control.Plugins`). Every server here answers MCP
  from outside mainland China. A service authenticates in one of these ways:

    * `{:url_key, key, label, help_url}`: the user's key is a URL parameter.
    * `{:bearer, key, label, help_url}`: the user's key is a Bearer token.
    * `:oauth`: MCP OAuth with dynamic client registration.
    * `:oauth_per_requester`: every person signs in with their own account
      through the server's OAuth device flow, and each tool call runs as the
      person who asked for the turn (`SalixMCP.Provider`). Enabling the
      plugin needs no credential: the server lists its tools without one.

  A server that rejects a wrong key in its own way, or accepts any key until a
  tool runs, declares `check` (`Salix.Control.PluginSetup` credential checks):
  the texts it rejects a key with and, for the second kind, one read-only tool
  call to make with the new key. The map geocoding checks use one call of the
  key's quota; Gitee's user lookup is free.
  """

  # The data abilities a WeCom (企业微信) AI bot is granted under 可使用权限.
  # Each ability has its own hosted MCP and its own key: the admin console
  # shows a `https://qyapi.weixin.qq.com/mcp/v2/bot/<path>?apikey=…` address
  # per ability, and a key is pasted alone or as that whole address
  # (`credential_param`). The server takes any key until a tool runs and then
  # answers errcode 850001 in a successful tool result
  # (`credential_failure/1`), so the check runs one read-only tool. The data is that
  # of the bot's creator and serves the whole Agent Swarm, like any connected
  # account; grants expire after seven days.
  @wecom_abilities [
    {"msg", "28", "消息",
     "Read the groups the bot is in and their messages, and send messages, as the WeCom bot.",
     "message_aibot_sessions_list", %{}},
    {"mail", "29", "邮件", "Search, read and send WeCom mail of the bot's creator.", "mail_search",
     %{}},
    {"doc", "30", "文档", "Create, search, read and edit WeCom documents, sheets and smart pages.",
     "doc_search", %{"keywords" => "comma"}},
    {"todo", "31", "待办", "Create, read, update and finish WeCom to-dos.", "todo_list", %{}},
    {"schedule", "32", "日程",
     "Read, search, create and update WeCom calendar events and find free time.",
     "meeting_rooms_buildings_list", %{}},
    {"meeting", "33", "会议",
     "Read, search, create and update WeCom meetings and fetch transcripts.",
     "meeting_rooms_buildings_list", %{}},
    {"disk", "34", "微盘", "Search, read, upload and organize WeCom Drive (微盘) files.",
     "disk_files_list", %{}},
    {"contact", "35", "通讯录", "Search members of the WeCom organization.", "contact_users_search",
     %{"keywords" => "comma"}}
  ]

  @wecom_services (for {path, number, label, description, tool, arguments} <- @wecom_abilities do
                     key = "WECOM_" <> String.upcase(path) <> "_APIKEY"

                     %{
                       id: "wecom-" <> path,
                       mcp_id: "mcp1_00000000000000000" <> number,
                       name: "企业微信" <> label,
                       description: description,
                       url: "https://qyapi.weixin.qq.com/mcp/v2/bot/#{path}?apikey={#{key}}",
                       auth:
                         {:url_key, key, "apikey（或整段地址）",
                          "https://developer.work.weixin.qq.com/document/path/101805"},
                       brand: "wecom",
                       credential_param: "apikey",
                       credential_address: "https://qyapi.weixin.qq.com/mcp/v2/bot/#{path}",
                       check: %{
                         "tool" => tool,
                         "arguments" => arguments
                       }
                     }
                   end)

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
    },
    %{
      id: "feishu-project",
      mcp_id: "mcp1_0000000000000000026",
      name: "飞书项目",
      description:
        "Read and update work items, views and comments in Feishu Project as the person who asks, through its official MCP.",
      url: "https://project.feishu.cn/mcp_server/v1",
      auth: :oauth_per_requester
    },
    %{
      id: "meegle",
      mcp_id: "mcp1_0000000000000000027",
      name: "Meegle",
      description:
        "Read and update work items, views and comments in Meegle as the person who asks, through its official MCP.",
      url: "https://meegle.com/mcp_server/v1",
      auth: :oauth_per_requester
    },
    %{
      id: "fastmail",
      mcp_id: "mcp1_0000000000000000036",
      name: "Fastmail",
      category: "Integrations",
      description: "Email, contacts, and calendars through Fastmail's official MCP.",
      url: "https://api.fastmail.com/mcp",
      auth:
        {:bearer, "FASTMAIL_MCP_TOKEN", "Fastmail MCP token",
         "https://www.fastmail.help/hc/en-us/articles/15869557281295"}
    }
  ]

  @services @services ++ @wecom_services

  @per_requester_mcp_ids for %{auth: :oauth_per_requester, mcp_id: id} <- @services, do: id

  @doc "The built-in MCP definitions, one per service."
  def mcp_definitions, do: Enum.map(@services, &mcp_definition/1)

  @doc "The system plugin definitions, one per service."
  def plugin_definitions, do: Enum.map(@services, &plugin_definition/1)

  @doc "Whether the MCP definition `mcp_id` runs each call as the person who asked."
  def per_requester?(mcp_id), do: mcp_id in @per_requester_mcp_ids

  @wecom_mcp_ids for %{brand: "wecom", mcp_id: id} <- @services, do: id

  @doc """
  How a successful tool result of the MCP definition `mcp_id` says its stored
  key no longer works, or nil. WeCom answers an expired, revoked or replaced
  grant with errcode 850001 inside a successful result; such a result is a
  failure (`SalixMCP.Gateway`), not data.
  """
  def credential_failure(mcp_id) when mcp_id in @wecom_mcp_ids,
    do: %{
      "errcodes" => [850_001],
      "message" =>
        "WeCom refused this ability's key: the grant expired, was revoked or was granted again with a new key. " <>
          "Tell the person that an admin must grant the ability again in the WeCom bot's 可使用权限 and paste the new key on the Plugins page."
    }

  def credential_failure(_mcp_id), do: nil

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
    |> Map.merge(auth_requirements(service))
  end

  defp auth_requirements(%{auth: :oauth, id: id}),
    do: %{"auth_requirements" => %{id => ["oauth"]}}

  defp auth_requirements(%{auth: :oauth_per_requester, id: id}),
    do: %{"auth_requirements" => %{id => ["oauth_per_requester"]}}

  defp auth_requirements(_service), do: %{}

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
  defp remote_auth(:oauth_per_requester), do: %{"headers_schema" => %{}}

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
      "ui" => %{
        "brand" => Map.get(service, :brand, service.id),
        "category" => Map.get(service, :category, "中国服务")
      },
      "default_enabled" => false,
      "setup" => setup,
      "refs" => %{
        "tool_refs" => ["mcp.#{service.id}.*"],
        "mcp_refs" => [%{"mcp_id" => service.mcp_id}]
      }
    }
  end

  # Nothing to connect for the Group: each person signs in when they first
  # ask (`Salix.Control.RemoteMCPDeviceSignIn`).
  defp connection(%{auth: :oauth_per_requester} = service) do
    %{
      "id" => service.id <> "-requester",
      "kind" => "requester_mcp_oauth",
      "label" => service.name <> " sign-in per person"
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
    connection_label =
      if String.starts_with?(label, service.name <> " "),
        do: label,
        else: service.name <> " " <> label

    %{
      "id" => service.id <> "-api-key",
      "kind" => "mcp_api_key",
      "label" => connection_label,
      "config_key" => key,
      "credential_label" => label,
      "help_url" => help_url
    }
    |> Map.merge(
      if check = Map.get(service, :check), do: %{"credential_check" => check}, else: %{}
    )
    |> Map.merge(
      if param = Map.get(service, :credential_param),
        do: %{
          "credential_param" => param,
          "credential_address" => Map.fetch!(service, :credential_address)
        },
        else: %{}
    )
  end
end
