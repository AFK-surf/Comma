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
  @posthog_mcp_id "mcp1_0000000000000000012"
  @stripe_mcp_id "mcp1_0000000000000000013"
  @blender_mcp_id "mcp1_0000000000000000025"

  # The PostHog MCP tool families (its `features` query) Comma offers: those
  # PostHog's own MCP installer offers (`@posthog/wizard` AVAILABLE_FEATURES),
  # with its names and categories, in its order. `workspace` (organization and
  # project switching) is always on; families it does not offer stay off.
  @posthog_tool_groups [
    {"dashboards", "Dashboards", "Data & Analytics"},
    {"insights", "Insights", "Data & Analytics"},
    {"product_analytics", "Product Analytics", "Data & Analytics"},
    {"experiments", "Experiments", "Data & Analytics"},
    {"surveys", "Surveys", "Data & Analytics"},
    {"annotations", "Annotations", "Data & Analytics"},
    {"replay", "Session Replay", "Data & Analytics"},
    {"sql", "SQL", "Data & Analytics"},
    {"web_analytics", "Web Analytics", "Data & Analytics"},
    {"customer_analytics", "Usage metrics", "Data & Analytics"},
    {"signals", "Signals", "Data & Analytics"},
    {"llm_analytics", "AI Observability", "AI Engineering"},
    {"error_tracking", "Error Tracking", "Development Tools"},
    {"logs", "Logs", "Development Tools"},
    {"flags", "Feature Flags", "Development Tools"},
    {"early_access_features", "Early Access Features", "Development Tools"},
    {"cohorts", "Cohorts", "Development Tools"},
    {"tracing", "APM Tracing", "Development Tools"},
    {"events", "Events", "Data Management"},
    {"persons", "Persons", "Data Management"},
    {"actions", "Actions", "Data Management"},
    {"data_warehouse", "Data Warehouse", "Data Management"},
    {"endpoints", "Endpoints", "Data Management"},
    {"data_schema", "Data Schema", "Data Management"},
    {"batch_exports", "Batch Exports", "Data Management"},
    {"hog_functions", "Hog Functions", "CDP & Automation"},
    {"hog_function_templates", "Hog Function Templates", "CDP & Automation"},
    {"workflows", "Workflows", "CDP & Automation"},
    {"docs", "Documentation", "Platform & Management"},
    {"notebooks", "Notebooks", "Platform & Management"},
    {"alerts", "Alerts", "Platform & Management"},
    {"platform_features", "Platform Features", "Platform & Management"},
    {"integrations", "Integrations", "Platform & Management"},
    {"conversations", "Conversations", "Platform & Management"},
    {"core", "Core", "Platform & Management"},
    {"reverse_proxy", "Reverse Proxy", "Platform & Management"},
    {"debug", "Debug", "Platform & Management"}
  ]
  @posthog_all_features Enum.map_join(
                          [{"workspace", nil, nil} | @posthog_tool_groups],
                          ",",
                          &elem(&1, 0)
                        )

  @doc """
  The PostHog MCP's tool groups, each a family of its `features` query, for the
  `posthog` plugin's switches. `workspace` is not among them: it is always on.
  """
  def posthog_tool_groups,
    do:
      Enum.map(@posthog_tool_groups, fn {id, name, category} ->
        %{"id" => id, "name" => name, "category" => category}
      end)

  @doc "The Mac apps MCP served by the Comma desktop app (see SalixMCP.Connection client_mcp)."
  def mac_apps_mcp_id, do: @mac_apps_mcp_id

  @doc "The Blender MCP served by the Comma desktop app (see SalixMCP.Connection client_mcp)."
  def blender_mcp_id, do: @blender_mcp_id

  @doc "Whether an MCP is one the Comma desktop app serves itself, over `client_mcp`."
  def client_mcp_id?(mcp_id), do: mcp_id in [@mac_apps_mcp_id, @blender_mcp_id]

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
        "mcp_id" => @blender_mcp_id,
        "tenant_id" => "",
        "name" => "Blender",
        "description" =>
          "Look at, change, render and export the scenes of Blender on the user's own computer, served by the Comma desktop app.",
        "server_metadata" => %{
          "name" => "Blender",
          "description" =>
            "The Comma desktop app's MCP server for Blender on that computer. It reaches only the Blender windows with Comma's add-on connected.",
          "remotes" => [
            %{
              "target_ref" => "client:blender",
              "transport" => "comma-client",
              "url" => "comma-client://blender",
              "headers_schema" => %{}
            }
          ]
        },
        "supports_server" => false,
        "recommended_placement" => "device",
        "supported_placements" => ["device"],
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"device" => ["comma_desktop"]},
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
        "mcp_id" => @posthog_mcp_id,
        "tenant_id" => "",
        "name" => "PostHog",
        "description" =>
          "Official hosted PostHog MCP for product analytics, feature flags, experiments, and errors.",
        "server_metadata" => %{
          "name" => "PostHog",
          "description" =>
            "Official hosted PostHog MCP for product analytics, feature flags, experiments, and errors.",
          "remotes" => [
            %{
              "target_ref" => "remote:posthog",
              "transport" => "streamable-http",
              "url" => "https://mcp.posthog.com/mcp?features={POSTHOG_FEATURES}",
              "variables_schema" => %{
                "POSTHOG_FEATURES" => %{
                  "description" => "Comma-separated PostHog tool families.",
                  "isRequired" => false,
                  "default" => @posthog_all_features
                }
              },
              "headers_schema" => %{}
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"posthog" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" =>
          "Uses PostHog's official hosted MCP with OAuth discovery, PKCE, and dynamic client registration.",
        "trust" => %{"source" => "system_builtin"},
        "created_by" => "system"
      },
      %{
        "mcp_id" => @stripe_mcp_id,
        "tenant_id" => "",
        "name" => "Stripe",
        "description" => "Official hosted Stripe MCP for payments, customers, and billing.",
        "server_metadata" => %{
          "name" => "Stripe",
          "description" => "Official hosted Stripe MCP for payments, customers, and billing.",
          "remotes" => [
            %{
              "target_ref" => "remote:stripe",
              "transport" => "streamable-http",
              "url" => "https://mcp.stripe.com",
              "headers_schema" => %{}
            }
          ]
        },
        "supports_server" => true,
        "recommended_placement" => "server",
        "supported_placements" => ["server"],
        "auth_requirements" => %{"stripe" => ["oauth"]},
        "declared_capabilities" => %{"tools" => true},
        "environment_requirements" => %{"server" => ["public_network"]},
        "server_support_note" =>
          "Uses Stripe's official hosted MCP with OAuth discovery, PKCE, and dynamic client registration.",
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
    ] ++ SalixMCP.ChinaServices.mcp_definitions()
  end
end
