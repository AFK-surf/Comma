defmodule SalixMCP.Builtins do
  @moduledoc false

  use SystemsRuntime.Server

  require Logger

  alias SalixMCP.Store

  @context7_mcp_id "mcp1_0000000000000000001"
  @playwright_mcp_id "mcp1_0000000000000000002"
  @github_mcp_id "mcp1_0000000000000000003"
  @linear_mcp_id "mcp1_0000000000000000004"
  @feishu_mcp_id "mcp1_0000000000000000005"
  @google_workspace_mcp_id "mcp1_0000000000000000006"
  @notion_mcp_id "mcp1_0000000000000000007"
  @slack_mcp_id "mcp1_0000000000000000008"
  @x_mcp_id "mcp1_0000000000000000009"
  @lark_mcp_id "mcp1_0000000000000000010"
  @mac_apps_mcp_id "mcp1_0000000000000000011"

  @doc "The Mac apps MCP served by the Comma desktop app (see SalixMCP.Connection client_mcp)."
  def mac_apps_mcp_id, do: @mac_apps_mcp_id

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :seed}}

  @impl true
  def handle_continue(:seed, opts) do
    case seed_builtin_definitions(opts) do
      {:ok, counts} ->
        Logger.info("seeded built-in MCP definitions: #{inspect(counts)}")

      {:error, reason} ->
        Logger.error("failed to seed built-in MCP definitions: #{inspect(reason)}")
    end

    {:stop, :normal, opts}
  end

  @doc false
  def seed_builtin_definitions(_opts \\ []) do
    builtin_definitions()
    |> Enum.reduce_while({:ok, %{created: 0, updated: 0, unchanged: 0}}, fn attrs,
                                                                            {:ok, counts} ->
      case Store.upsert_system_definition(attrs) do
        {:ok, _definition, :created} ->
          {:cont, {:ok, Map.update!(counts, :created, &(&1 + 1))}}

        {:ok, _definition, :updated} ->
          {:cont, {:ok, Map.update!(counts, :updated, &(&1 + 1))}}

        {:ok, _definition, :unchanged} ->
          {:cont, {:ok, Map.update!(counts, :unchanged, &(&1 + 1))}}

        {:error, reason} ->
          {:halt, {:error, {attrs["mcp_id"], reason}}}
      end
    end)
  end

  defp builtin_definitions do
    [
      %{
        "mcp_id" => @mac_apps_mcp_id,
        "tenant_id" => "",
        "name" => "Mac apps",
        "description" =>
          "Calendar, Reminders, Contacts, Messages, Mail, Notes, Music, Maps, system controls and on-device image recognition on the user's own Mac, served by the Comma desktop app.",
        "server_metadata" => %{
          "name" => "Mac apps",
          "description" =>
            "The Comma desktop app's MCP server for the Mac's own apps. Each app is on only when the user turns it on in Comma on that Mac.",
          "remotes" => [
            %{
              # Not an HTTP endpoint: the device's Connector forwards each message
              # to the desktop app with `client_mcp` (SalixMCP.Connection).
              "target_ref" => "client:mac-apps",
              "transport" => "comma-client",
              "url" => "comma-client://mac-apps",
              "headers_schema" => %{}
            }
          ]
        },
        "supports_server" => false,
        "recommended_placement" => "device",
        "supported_placements" => ["device"],
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"device" => ["comma_desktop_macos"]},
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @x_mcp_id,
        "name" => "X",
        "description" =>
          "Use X with your account's OAuth permissions, or read public data with an App-only Bearer Token.",
        "server_metadata" => %{
          "name" => "X",
          "remotes" => [
            %{
              "target_ref" => "remote:x",
              "transport" => "streamable-http",
              "url" => "https://api.x.com/mcp",
              "headers_schema" => %{
                "Authorization" => %{
                  "isRequired" => true,
                  "isSecret" => true,
                  "value" => "Bearer ${X_BEARER_TOKEN}"
                }
              }
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "salix_metadata" => %{
          # App-only credentials permit public reads. Managed OAuth uses the
          # official server's tools and the account's granted scopes.
          "app_only_tool_allowlist" => ~w(
            get_posts_by_id get_posts_by_ids get_posts_counts_recent
            get_posts_liking_users get_posts_quoted_posts get_posts_reposted_by
            get_users_by_id get_users_by_username get_users_by_usernames get_users_posts
            search_posts_all search_users get_news search_news get_trends_by_woeid
          )
        },
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @context7_mcp_id,
        "tenant_id" => "",
        "name" => "Context7",
        "description" => "Context7 documentation search MCP.",
        "server_metadata" => %{
          "name" => "Context7",
          "description" => "Context7 documentation search MCP.",
          "remotes" => [
            %{
              "target_ref" => "remote:context7",
              "transport" => "streamable-http",
              "url" => "https://mcp.context7.com/mcp",
              "headers_schema" => %{}
            }
          ],
          "packages" => [
            %{
              "target_ref" => "package:context7-npm",
              "registry_type" => "npm",
              "identifier" => "@upstash/context7-mcp",
              "version" => "latest",
              "transport" => "stdio",
              "command" => "npx",
              "runtime_arguments" => ["-y", "@upstash/context7-mcp@latest"],
              "environment_variables_schema" => %{}
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server", "device"],
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{
          "server" => ["public_network"],
          "device" => ["node_package_manager"]
        },
        "server_support_note" =>
          "Remote entry is server-safe. Package entry is a trusted system definition and may run only when server process runner policy is configured.",
        "trust" => %{
          "source" => "system_builtin",
          "server_process_execution" => true
        },
        "created_by" => "system"
      },
      %{
        "mcp_id" => @playwright_mcp_id,
        "tenant_id" => "",
        "name" => "Playwright MCP",
        "description" =>
          "Microsoft Playwright MCP for browser automation on a group-managed device.",
        "server_metadata" => %{
          "name" => "Playwright MCP",
          "description" =>
            "Microsoft Playwright MCP for browser automation on a group-managed device.",
          "packages" => [
            %{
              "target_ref" => "package:playwright-npm",
              "registry_type" => "npm",
              "identifier" => "@playwright/mcp",
              "version" => "latest",
              "transport" => "stdio",
              "command" => "npx",
              "runtime_arguments" => ["-y", "@playwright/mcp@latest", "--headless"],
              "environment_variables_schema" => %{}
            }
          ]
        },
        "supports_server" => false,
        "recommended_placement" => "device",
        "supported_placements" => ["device"],
        "declared_capabilities" => %{"tools" => true, "browser" => true},
        "environment_requirements" => %{"device" => ["node_package_manager", "browser"]},
        "server_support_note" => "Requires browser/device capabilities.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @github_mcp_id,
        "tenant_id" => "",
        "name" => "GitHub MCP Server",
        "description" =>
          "Official GitHub MCP server for repository, issue, and pull request operations.",
        "server_metadata" => %{
          "name" => "GitHub MCP Server",
          "description" =>
            "Official GitHub MCP server for repository, issue, and pull request operations.",
          "remotes" => [
            %{
              "target_ref" => "remote:github",
              "transport" => "streamable-http",
              "url" => "https://api.githubcopilot.com/mcp/",
              "headers_schema" => %{
                "Authorization" => %{
                  "isRequired" => true,
                  "isSecret" => true,
                  "value" => "Bearer ${GITHUB_ACCESS_TOKEN}"
                }
              }
            }
          ],
          "packages" => [
            %{
              "target_ref" => "package:github-container",
              "registry_type" => "oci",
              "identifier" => "ghcr.io/github/github-mcp-server",
              "transport" => "stdio",
              "command" => "docker",
              "runtime_arguments" => ["run", "-i", "--rm", "ghcr.io/github/github-mcp-server"],
              "environment_variables_schema" => %{
                "GITHUB_PERSONAL_ACCESS_TOKEN" => %{
                  "description" => "GitHub token or OAuth-provided access token.",
                  "isRequired" => true,
                  "isSecret" => true
                },
                "GITHUB_TOOLSETS" => %{
                  "description" => "Optional comma-separated GitHub MCP toolsets.",
                  "isRequired" => false
                }
              }
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server", "device"],
        "auth_requirements" => %{"github" => ["token", "oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{
          "server" => ["public_network"],
          "device" => ["docker"]
        },
        "server_support_note" =>
          "Uses GitHub's official hosted MCP on server placement; the official container remains available for device placement.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @linear_mcp_id,
        "tenant_id" => "",
        "name" => "Linear",
        "description" => "Official hosted Linear MCP for issue and project access.",
        "server_metadata" => %{
          "name" => "Linear",
          "description" => "Official hosted Linear MCP for issue and project access.",
          "remotes" => [
            %{
              "target_ref" => "remote:linear",
              "transport" => "streamable-http",
              "url" => "https://mcp.linear.app/mcp",
              "headers_schema" => %{
                "Authorization" => %{
                  "isRequired" => true,
                  "isSecret" => true,
                  "value" => "Bearer ${LINEAR_ACCESS_TOKEN}"
                }
              }
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"linear" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" => "Uses Linear's official hosted Streamable HTTP endpoint.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @feishu_mcp_id,
        "tenant_id" => "",
        "name" => "Feishu",
        "description" => "Official hosted Feishu MCP for documents, people, and messages.",
        "server_metadata" => %{
          "name" => "Feishu",
          "description" => "Official hosted Feishu MCP for documents, people, and messages.",
          "remotes" => [
            %{
              "target_ref" => "remote:feishu",
              "transport" => "streamable-http",
              "url" => "https://mcp.feishu.cn/mcp",
              "headers_schema" => %{}
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"feishu" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" =>
          "Uses Feishu's official hosted MCP with OAuth discovery, PKCE, and dynamic client registration.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @lark_mcp_id,
        "tenant_id" => "",
        "name" => "Lark",
        "description" => "Official hosted Lark MCP for documents, people, and messages.",
        "server_metadata" => %{
          "name" => "Lark",
          "description" => "Official hosted Lark MCP for documents, people, and messages.",
          "remotes" => [
            %{
              "target_ref" => "remote:lark",
              "transport" => "streamable-http",
              "url" => "https://mcp.larksuite.com/mcp",
              "headers_schema" => %{}
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"lark" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" =>
          "Uses Lark's official hosted MCP with OAuth discovery, PKCE, and dynamic client registration.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @google_workspace_mcp_id,
        "tenant_id" => "",
        "name" => "Google Workspace Universal Search",
        "description" =>
          "Official Google Workspace MCP for read-only search across Gmail, Drive, Calendar, and Chat.",
        "server_metadata" => %{
          "name" => "Google Workspace Universal Search",
          "description" =>
            "Official Google Workspace MCP for read-only search across Gmail, Drive, Calendar, and Chat.",
          "remotes" => [
            %{
              "target_ref" => "remote:google-workspace",
              "transport" => "streamable-http",
              "url" => "https://workspacemcp.googleapis.com/mcp/v1",
              "headers_schema" => %{
                "Authorization" => %{
                  "isRequired" => true,
                  "isSecret" => true,
                  "value" => "Bearer ${GOOGLE_ACCESS_TOKEN}"
                }
              }
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"google" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" =>
          "Google Workspace MCP is a Developer Preview and requires an enrolled Google Cloud project.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @notion_mcp_id,
        "tenant_id" => "",
        "name" => "Notion",
        "description" => "Official hosted Notion MCP for pages, databases, and workspace search.",
        "server_metadata" => %{
          "name" => "Notion",
          "description" =>
            "Official hosted Notion MCP for pages, databases, and workspace search.",
          "remotes" => [
            %{
              "target_ref" => "remote:notion",
              "transport" => "streamable-http",
              "url" => "https://mcp.notion.com/mcp",
              "headers_schema" => %{}
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"notion" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" =>
          "Uses Notion's official hosted MCP with OAuth discovery, PKCE, and dynamic client registration.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @slack_mcp_id,
        "tenant_id" => "",
        "name" => "Slack",
        "description" => "Official hosted Slack MCP for search, messaging, users, and canvases.",
        "server_metadata" => %{
          "name" => "Slack",
          "description" =>
            "Official hosted Slack MCP for search, messaging, users, and canvases.",
          "remotes" => [
            %{
              "target_ref" => "remote:slack",
              "transport" => "streamable-http",
              "url" => "https://mcp.slack.com/mcp",
              "headers_schema" => %{
                "Authorization" => %{
                  "isRequired" => true,
                  "isSecret" => true,
                  "value" => "Bearer ${SLACK_USER_TOKEN}"
                }
              }
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"slack" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" =>
          "Uses Slack's official hosted MCP; the workspace administrator must allow the integration.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      }
    ]
  end
end
