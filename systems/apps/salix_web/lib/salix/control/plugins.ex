defmodule Salix.Control.Plugins do
  @moduledoc """
  Plugin control-plane.

  A plugin is only a feature package: it stores display metadata and refs to
  independently owned domains, plus a group enablement switch. This module never
  mutates Skill, MCP, OAuth, IM, env, or tool state while enabling or disabling a
  plugin.
  """

  alias Salix.Control.{Groups, PluginCatalogCache, PluginSetup, Store, Tenants}
  alias SalixStore.{Ids, Keys}

  @canonical_ref_re ~r/^[a-z0-9][a-z0-9_.-]*(\.\*)?$/
  @max_refs 500

  @feishu_mcp_scopes ~w(
    mcp-tool:common:get-user
    mcp-tool:common:search-user
    mcp-tool:docs:search-doc
    mcp-tool:docs:fetch-doc
    mcp-tool:docs:get-comments
    mcp-tool:docs:list-docs-v2
    mcp-tool:im:search-groups
    mcp-tool:im:get-group-members
    mcp-tool:im:get-messages
    mcp-tool:im:get-thread-messages
    mcp-tool:im:search-messages
    mcp-tool:im:get-read-status
    offline_access
  )
  @github_mcp_scopes ~w(repo read:org read:user user:email)
  @google_workspace_mcp_scopes ~w(
    https://www.googleapis.com/auth/gmail.readonly
    https://www.googleapis.com/auth/drive.readonly
    https://www.googleapis.com/auth/calendar.readonly
    https://www.googleapis.com/auth/chat.messages.readonly
  )
  @slack_mcp_scopes ~w(
    search:read.public
    search:read.private
    search:read.mpim
    search:read.im
    search:read.files
    search:read.users
    chat:write
    channels:history
    groups:history
    mpim:history
    im:history
    canvases:read
    canvases:write
    users:read
    users:read.email
    reactions:write
    reactions:read
    emoji:read
    files:read
    channels:write
    groups:write
    im:write
    mpim:write
    channels:read
    groups:read
    mpim:read
  )

  @system_plugins [
    %{
      "plugin_id" => "core-runtime",
      "name" => "Core Runtime",
      "description" =>
        "Session scheduling, tool lifecycle, help, permission and location requests.",
      "locked" => true,
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(help wait_for tool_call.get_status tool_call.get_result tool_call.cancel permission.request location.request)
      }
    },
    %{
      "plugin_id" => "core-workspace",
      "name" => "Core Workspace",
      "description" => "Agent workspace and runtime file read/write tools.",
      "locked" => true,
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(fs.read_file fs.write_file fs.list_files fs.delete_file fs.edit_file fs.copy_file fs.move_file fs.grep fs.glob fs.stat_file)
      }
    },
    %{
      "plugin_id" => "core-internal-im",
      "name" => "Core Internal IM",
      "description" =>
        "Internal Comma conversations, participant status, visible replies and Task lifecycle controls.",
      "locked" => true,
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(im.connects_list im.provider_apis_list im_api.internal.search_conversations im_api.internal.read_conversation im_api.internal.list_conversation_participants im_api.internal.get_conversation_participant_status im_api.internal.add_agent_participant im_api.internal.update_conversation im_api.internal.send_message im_api.internal.task.create im_api.internal.task.update im_api.internal.task.list)
      }
    },
    %{
      "plugin_id" => "agent-collaboration",
      "name" => "Agent Collaboration",
      "description" => "Agent listing, worker creation and runtime binding.",
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(agent.list agent.get agent.create_worker agent.update agent.rebind_runtime agent.archive)
      }
    },
    %{
      "plugin_id" => "meeting-preparation",
      "name" => "Meeting Preparation",
      "description" =>
        "Router-owned manual meeting control plus scheduled preparation decisions and publication fences.",
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(meeting.preparation.start_research meeting.preparation.open_trigger meeting.preparation.record_decision meeting.preparation.publish_report meeting.join meeting.get)
      }
    },
    %{
      "plugin_id" => "environment-control",
      "name" => "Environment Control",
      "description" =>
        "Connector-backed environment discovery, command execution, file copy and process control.",
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(device.list device.get env.runtime_targets env.exec env.copy env.computer_use env.process_list env.process_write env.process_tail)
      }
    },
    %{
      "plugin_id" => "android-control",
      "name" => "Android Control",
      "description" => "Lease and operate an authorized Connector-owned Android emulator.",
      "ui" => %{"classification" => "capability", "setup_destination" => "project_devices"},
      "default_enabled" => false,
      "refs" => %{"tool_refs" => ["env.android"]}
    },
    %{
      "plugin_id" => "virtual-compute",
      "name" => "Virtual Compute",
      "description" =>
        "Environment-bound virtual machine workspace, build, service export/import and route controls.",
      "default_enabled" => false,
      "ui" => %{"classification" => "compute", "resource_lifecycle" => "independent"},
      "refs" => %{"tool_refs" => ["compute.*"]}
    },
    %{
      "plugin_id" => "external-im",
      "name" => "External IM",
      "description" => "Third-party IM provider operations.",
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" => ~w(im_api.telegram.* im_api.wechat.* im_api.discord.*)
      }
    },
    %{
      "plugin_id" => "web-research",
      "name" => "Web Research",
      "description" => "Web search and page reading.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(web.search web.read_pages)}
    },
    %{
      "plugin_id" => "script-runtime",
      "name" => "Script Runtime",
      "description" => "Sandboxed one-shot C scripts compiled to eBPF (spinfoam).",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(script.run script.run_file script.sdk)}
    },
    %{
      "plugin_id" => "skill-authoring",
      "name" => "Skill Authoring",
      "description" => "Create, copy and delete reusable skills.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(skill.create skill.copy skill.delete)}
    },
    %{
      "plugin_id" => "skill-library",
      "name" => "Skill Library",
      "description" => "Session-visible shared skills.",
      "default_enabled" => true,
      "refs" => %{"skill_refs" => ~w(*)}
    },
    %{
      "plugin_id" => "plugin-management",
      "name" => "Plugin Management",
      "description" => "Create, update, enable, disable and inspect plugin definitions.",
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(plugin.definitions_list plugin.definition_get plugin.definition_create plugin.definition_update plugin.refs_put plugin.enable plugin.disable plugin.projection_get)
      }
    },
    %{
      "plugin_id" => "mcp-management",
      "name" => "MCP Management",
      "description" => "MCP definition, binding, connection, resource, prompt and tool access.",
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(mcp_manager.definition_list mcp_manager.definition_create mcp_manager.connect mcp_manager.update mcp_manager.set_enabled mcp_manager.reconnect mcp_manager.authorize mcp.list mcp.get mcp.*)
      }
    },
    %{
      "plugin_id" => "managed-oauth",
      "name" => "Managed OAuth",
      "description" => "Group OAuth credential management.",
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(oauth.list_credentials oauth.request_authorization oauth.complete_authorization oauth.delete_credential)
      }
    },
    %{
      "plugin_id" => "feishu",
      "name" => "Feishu",
      "description" => "Workspace messaging and bot routing through Feishu.",
      "ui" => %{"brand" => "feishu"},
      "default_enabled" => true,
      "setup" => %{
        "type" => "integration",
        "default_connection" => "feishu-im",
        "connections" => [
          %{
            "id" => "feishu-native",
            "kind" => "native_mcp_oauth",
            "label" => "Feishu MCP OAuth",
            "scopes" => @feishu_mcp_scopes
          },
          %{
            "id" => "feishu-im",
            "kind" => "im_connect",
            "label" => "Feishu messaging",
            "provider" => "feishu"
          }
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000005",
            "alias" => "feishu",
            "target_ref" => "remote:feishu",
            "placement" => "server",
            "auth_refs" => ["feishu-native"]
          }
        ]
      },
      "refs" => %{
        "tool_refs" => ["im_api.feishu.*", "mcp.feishu.*"],
        "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000005"}],
        "im_connect_requirements" => [%{"provider" => "feishu"}]
      }
    },
    %{
      "plugin_id" => "github",
      "name" => "GitHub",
      "description" => "Repositories, issues and pull requests through OAuth or direct APIs.",
      "ui" => %{"brand" => "github"},
      "default_enabled" => true,
      "setup" => %{
        "type" => "integration",
        "default_connection" => "github-managed",
        "required_connections" => ["github-managed"],
        "connections" => [
          %{
            "id" => "github-managed",
            "kind" => "managed_oauth",
            "label" => "GitHub OAuth",
            "provider" => "github",
            "alias" => "github",
            "credential_env_var" => "GITHUB_ACCESS_TOKEN",
            "scopes" => @github_mcp_scopes
          }
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000003",
            "alias" => "github",
            "target_ref" => "remote:github",
            "placement" => "server",
            "auth_refs" => ["github-managed"]
          }
        ]
      },
      "refs" => %{
        "tool_refs" => ["mcp.github.*"],
        "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000003"}],
        "oauth_requirements" => [
          %{"provider" => "github", "alias" => "github", "scopes" => @github_mcp_scopes}
        ]
      }
    },
    %{
      "plugin_id" => "google",
      "name" => "Google Workspace",
      "description" =>
        "Developer Preview search across Gmail, Drive, Calendar, and Chat through Google OAuth.",
      "ui" => %{"brand" => "google"},
      "default_enabled" => false,
      "setup" => %{
        "type" => "integration",
        "default_connection" => "google-managed",
        "connections" => [
          %{
            "id" => "google-managed",
            "kind" => "managed_oauth",
            "label" => "Google OAuth",
            "provider" => "google",
            "alias" => "google",
            "credential_env_var" => "GOOGLE_ACCESS_TOKEN",
            "scopes" => @google_workspace_mcp_scopes
          },
          %{
            "id" => "gmail-composio",
            "kind" => "composio",
            "label" => "Gmail via Composio",
            "toolkit" => "gmail"
          },
          %{
            "id" => "googlecalendar-composio",
            "kind" => "composio",
            "label" => "Google Calendar via Composio",
            "toolkit" => "googlecalendar"
          },
          %{
            "id" => "googledrive-composio",
            "kind" => "composio",
            "label" => "Google Drive via Composio",
            "toolkit" => "googledrive",
            "personal_optional" => true
          }
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000006",
            "alias" => "google-workspace",
            "icon" => "google",
            "target_ref" => "remote:google-workspace",
            "placement" => "server",
            "auth_refs" => ["google-managed"]
          }
        ]
      },
      "refs" => %{
        "tool_refs" => ["mcp.google-workspace.*"],
        "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000006"}],
        "oauth_requirements" => [
          %{
            "provider" => "google",
            "alias" => "google",
            "scopes" => @google_workspace_mcp_scopes
          }
        ]
      }
    },
    %{
      "plugin_id" => "linear",
      "name" => "Linear",
      "description" => "Linear issues and projects through the official MCP or direct APIs.",
      "ui" => %{"brand" => "linear"},
      "default_enabled" => false,
      "setup" => %{
        "type" => "integration",
        "default_connection" => "linear-managed",
        "required_connections" => ["linear-managed"],
        "connections" => [
          %{
            "id" => "linear-native",
            "kind" => "native_mcp_oauth",
            "label" => "Linear MCP OAuth",
            "scopes" => ~w(read write openid email)
          },
          %{
            "id" => "linear-managed",
            "kind" => "managed_oauth",
            "label" => "Linear OAuth",
            "provider" => "linear",
            "alias" => "linear",
            "credential_env_var" => "LINEAR_ACCESS_TOKEN",
            "scopes" => ~w(read write)
          }
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000004",
            "alias" => "linear",
            "target_ref" => "remote:linear",
            "placement" => "server",
            "auth_refs" => ["linear-native", "linear-managed"]
          }
        ]
      },
      "refs" => %{
        "tool_refs" => ["mcp.linear.*"],
        "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000004"}],
        "oauth_requirements" => [
          %{"provider" => "linear", "alias" => "linear", "scopes" => ~w(read write)}
        ]
      }
    },
    %{
      "plugin_id" => "notion",
      "name" => "Notion",
      "description" => "Pages and databases through OAuth or direct APIs.",
      "ui" => %{"brand" => "notion"},
      "default_enabled" => true,
      "setup" => %{
        "type" => "integration",
        "default_connection" => "notion-managed",
        "required_connections" => ["notion-managed", "notion-native"],
        "connections" => [
          %{
            "id" => "notion-native",
            "kind" => "native_mcp_oauth",
            "label" => "Notion MCP OAuth",
            "scopes" => []
          },
          %{
            "id" => "notion-managed",
            "kind" => "managed_oauth",
            "label" => "Notion OAuth",
            "provider" => "notion",
            "alias" => "notion",
            "scopes" => []
          }
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000007",
            "alias" => "notion",
            "target_ref" => "remote:notion",
            "placement" => "server",
            "auth_refs" => ["notion-native"]
          }
        ]
      },
      "refs" => %{
        "tool_refs" => ["mcp.notion.*"],
        "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000007"}],
        "oauth_requirements" => [%{"provider" => "notion", "alias" => "notion"}]
      }
    },
    %{
      "plugin_id" => "slack",
      "name" => "Slack",
      "description" => "Workspace messaging through Slack IM, OAuth or direct APIs.",
      "ui" => %{"brand" => "slack"},
      "default_enabled" => true,
      "setup" => %{
        "type" => "integration",
        "default_connection" => "slack-managed",
        "required_connections" => ["slack-managed"],
        "connections" => [
          %{
            "id" => "slack-im",
            "kind" => "im_connect",
            "label" => "Slack messaging",
            "provider" => "slack"
          },
          %{
            "id" => "slack-managed",
            "kind" => "managed_oauth",
            "label" => "Slack OAuth",
            "provider" => "slack",
            "alias" => "slack",
            "credential_env_var" => "SLACK_USER_TOKEN",
            "scopes" => @slack_mcp_scopes
          }
        ],
        "mcps" => [
          %{
            "mcp_id" => "mcp1_0000000000000000008",
            "alias" => "slack",
            "target_ref" => "remote:slack",
            "placement" => "server",
            "auth_refs" => ["slack-managed"]
          }
        ]
      },
      "refs" => %{
        "tool_refs" => ["im_api.slack.*", "mcp.slack.*"],
        "mcp_refs" => [%{"mcp_id" => "mcp1_0000000000000000008"}],
        "oauth_requirements" => [
          %{"provider" => "slack", "alias" => "slack", "scopes" => @slack_mcp_scopes}
        ],
        "im_connect_requirements" => [%{"provider" => "slack"}]
      }
    },
    %{
      "plugin_id" => "memory",
      "name" => "Memory",
      "description" => "Long-term memory read and write tools.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(memory.get memory.search memory.write)}
    },
    %{
      "plugin_id" => "schedules",
      "name" => "Schedules",
      "description" => "Create, list and delete schedules.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(schedule.create schedule.list schedule.delete)}
    },
    %{
      "plugin_id" => "image-generation",
      "name" => "Image Generation",
      "description" => "Image generation and editing.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(image.generate)}
    },
    %{
      "plugin_id" => "video-generation",
      "name" => "Video Generation",
      "description" => "Video generation.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(video.generate)}
    },
    %{
      "plugin_id" => "web-preview",
      "name" => "Web Preview",
      "description" => "Publish HTML previews from agent workspace files.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(preview.publish_html)}
    },
    %{
      "plugin_id" => "owner-notification",
      "name" => "Owner Notification",
      "description" => "Send email notifications to group owners.",
      "default_enabled" => true,
      "refs" => %{"tool_refs" => ~w(email.send_to_owners)}
    },
    %{
      "plugin_id" => "composio",
      "name" => "Composio",
      "description" => "Composio-hosted external SaaS connections and tool execution.",
      # Default-on like the other integration surfaces (managed-oauth,
      # external-im): tool disclosure already drops the composio.* family for
      # tenants whose Composio configuration definitively resolves to
      # :not_configured, so the plugin gate must not be the opt-in switch.
      "default_enabled" => true,
      "refs" => %{
        "tool_refs" =>
          ~w(composio.list_connections composio.request_connection composio.check_connection composio.delete_connection composio.list_toolkits composio.list_tools composio.get_tool composio.execute)
      }
    }
  ]

  @doc false
  def system_plugins, do: @system_plugins

  def list_definitions(tenant_id, group_id) do
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)

    with {:ok, definitions} <- list_raw_definitions(tenant_id, group_id) do
      {:ok, PluginSetup.resolve_statuses(definitions, tenant_id, group_id)}
    end
  end

  @doc "Lists visible definitions without resolving OAuth, MCP, or IM setup status."
  def list_raw_definitions(tenant_id, group_id) do
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)

    with {:ok, catalog} <- visible_catalog(tenant_id, group_id) do
      {:ok, Enum.map(catalog.definitions, &public_definition/1)}
    end
  end

  def list_tenant_definitions(tenant_id) do
    tenant_id = trim(tenant_id)

    with :ok <- ensure_tenant_scope(tenant_id) do
      {:ok,
       tenant_visible_definitions(tenant_id)
       |> Enum.map(&public_definition/1)}
    end
  end

  def get_definition(tenant_id, group_id, plugin_id) do
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)
    plugin_id = trim(plugin_id)

    with {:ok, catalog} <- visible_catalog(tenant_id, group_id) do
      case Enum.find(catalog.definitions, &(&1["plugin_id"] == plugin_id)) do
        nil -> {:error, :not_found}
        definition -> {:ok, public_definition(definition)}
      end
    end
  end

  def prepare_group_setup(tenant_id, group_id, plugin_id, connection_id \\ nil) do
    with {:ok, definition} <- get_definition(tenant_id, group_id, plugin_id) do
      PluginSetup.prepare(tenant_id, group_id, definition, connection_id)
    end
  end

  @doc false
  def load_group_catalog(tenant_id, group_id) do
    # Hidden groups still own live agents. Visibility only filters the public
    # catalog; runtime materialization requires the same durable tenant scope.
    with true <- Ids.valid_group_id_for_tenant?(group_id, tenant_id),
         {:ok, %{"tenant_id" => ^tenant_id} = group} <- Groups.get(group_id) do
      [tenant_definitions, group_definitions, enablements] =
        read_group_catalog_slices(tenant_id, group_id)

      {:ok,
       %{
         hidden?: group["hidden"] == true,
         definitions:
           visible_definitions_from(
             system_definitions_for_read(),
             tenant_definitions,
             group_definitions,
             tenant_id,
             group_id
           ),
         enablements: Enum.sort_by(enablements, & &1["plugin_id"])
       }}
    else
      {:error, _reason} = error -> error
      _wrong_scope -> {:error, :not_found}
    end
  end

  defp visible_catalog(tenant_id, group_id) do
    case PluginCatalogCache.snapshot(tenant_id, group_id) do
      {:ok, %{hidden?: false} = catalog} -> {:ok, catalog}
      {:ok, _hidden_catalog} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp read_group_catalog_slices(tenant_id, group_id) do
    context = SystemsObservability.Context.capture()

    [
      Keys.ctl_tenant_plugin_definitions_prefix(tenant_id),
      Keys.ctl_group_plugin_definitions_prefix(tenant_id, group_id),
      Keys.ctl_group_plugin_enablements_prefix(tenant_id, group_id)
    ]
    |> Task.async_stream(
      fn prefix ->
        SystemsObservability.Context.run(context, fn -> Store.list_records(prefix) end)
      end,
      ordered: true,
      max_concurrency: 3,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, records} -> records end)
  end

  def create_definition(tenant_id, group_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)
    now = Store.now()

    with {:ok, owner_scope} <- normalize_owner_scope(attrs["owner_scope"]),
         :ok <- ensure_create_id_not_provided(attrs),
         :ok <- ensure_group_scope(tenant_id, group_id),
         plugin_id <- Ids.new_plugin_id(),
         :ok <- ensure_definition_scope_available(tenant_id, group_id, plugin_id, owner_scope),
         {:ok, refs} <- normalize_refs(attrs),
         :ok <- validate_refs(refs) do
      rec =
        %{
          "owner_scope" => owner_scope,
          "tenant_id" => tenant_id,
          "group_id" => if(owner_scope == "group", do: group_id, else: ""),
          "plugin_id" => plugin_id,
          "version" => int(attrs["version"], 1),
          "name" => nonblank(attrs["name"], plugin_id),
          "description" => trim(attrs["description"]),
          "refs" => refs,
          "source" => nonblank(attrs["source"], owner_scope),
          "read_only" => false,
          "locked" => false,
          "default_enabled" => false,
          "created_at" => now,
          "updated_at" => now
        }
        |> maybe_put("setup", attrs["setup"])
        |> maybe_put("ui", attrs["ui"])
        |> maybe_put("trust", attrs["trust"])
        |> maybe_put("manual", attrs["manual"])

      Store.put_new(definition_key(owner_scope, tenant_id, group_id, plugin_id), rec)
      |> invalidate_definition(owner_scope, tenant_id, group_id)
    end
  end

  def create_tenant_definition(tenant_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    tenant_id = trim(tenant_id)
    now = Store.now()

    with :ok <- ensure_tenant_scope(tenant_id),
         :ok <- ensure_create_id_not_provided(attrs),
         {:ok, refs} <- normalize_refs(attrs),
         :ok <- validate_refs(refs),
         plugin_id <- Ids.new_plugin_id(),
         :ok <- ensure_definition_scope_available(tenant_id, "", plugin_id, "tenant") do
      rec =
        %{
          "owner_scope" => "tenant",
          "tenant_id" => tenant_id,
          "group_id" => "",
          "plugin_id" => plugin_id,
          "version" => int(attrs["version"], 1),
          "name" => nonblank(attrs["name"], plugin_id),
          "description" => trim(attrs["description"]),
          "refs" => refs,
          "source" => nonblank(attrs["source"], "tenant"),
          "read_only" => false,
          "locked" => false,
          "default_enabled" => false,
          "created_at" => now,
          "updated_at" => now
        }
        |> maybe_put("setup", attrs["setup"])
        |> maybe_put("ui", attrs["ui"])
        |> maybe_put("trust", attrs["trust"])
        |> maybe_put("manual", attrs["manual"])

      Store.put_new(definition_key("tenant", tenant_id, "", plugin_id), rec)
      |> invalidate_tenant(tenant_id)
    end
  end

  @doc """
  Updates a mutable plugin definition visible to a group.

  This group-context API intentionally supports both tenant- and group-owned
  definitions for the agent tool and public HTTP contract. Scope-specific
  control planes should use `update_tenant_definition/3` or
  `update_group_definition/4`.
  """
  def update_definition(tenant_id, group_id, plugin_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)

    with :ok <- ensure_group_scope(tenant_id, group_id),
         {:ok, definition, key} <-
           find_mutable_definition_with_key(tenant_id, group_id, plugin_id) do
      update_mutable_definition(key, definition, attrs)
      |> invalidate_definition(definition["owner_scope"], tenant_id, group_id)
    end
  end

  def update_tenant_definition(tenant_id, plugin_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    tenant_id = trim(tenant_id)
    plugin_id = trim(plugin_id)

    with :ok <- ensure_tenant_scope(tenant_id),
         {:ok, definition, key} <- find_mutable_tenant_definition_with_key(tenant_id, plugin_id) do
      update_mutable_definition(key, definition, attrs)
      |> invalidate_tenant(tenant_id)
    end
  end

  def update_group_definition(tenant_id, group_id, plugin_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)
    plugin_id = trim(plugin_id)

    with :ok <- ensure_group_scope(tenant_id, group_id),
         {:ok, definition, key} <-
           find_mutable_group_definition_with_key(tenant_id, group_id, plugin_id) do
      update_mutable_definition(key, definition, attrs)
      |> invalidate_group(group_id)
    end
  end

  def put_refs(tenant_id, group_id, plugin_id, attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    refs = Map.get(attrs, "refs", attrs)

    update_definition(tenant_id, group_id, plugin_id, Map.put(attrs, "refs", refs))
  end

  def list_group_enablements(tenant_id, group_id) do
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)

    with {:ok, catalog} <- visible_catalog(tenant_id, group_id) do
      {:ok, catalog.enablements}
    end
  end

  def enable_group(tenant_id, group_id, plugin_id) do
    set_group_enabled(tenant_id, group_id, plugin_id, true)
  end

  def disable_group(tenant_id, group_id, plugin_id) do
    set_group_enabled(tenant_id, group_id, plugin_id, false)
  end

  @doc "Deletes a group override so the definition's default_enabled value applies again."
  def clear_group_enablement(tenant_id, group_id, plugin_id) do
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)
    plugin_id = trim(plugin_id)

    Keys.ctl_group_plugin_enablement(tenant_id, group_id, plugin_id)
    |> Store.delete_record()
    |> invalidate_group(group_id)
  end

  def runtime_projection(attrs) when is_map(attrs) do
    attrs = stringify(attrs)
    tenant_id = trim(attrs["tenant_id"])
    group_id = trim(attrs["group_id"])

    with {:ok, catalog} <- PluginCatalogCache.snapshot(tenant_id, group_id) do
      definitions = catalog.definitions
      enablements = catalog.enablements
      enablement_by_id = Map.new(enablements, &{&1["plugin_id"], &1})

      materialized =
        definitions
        |> Enum.filter(&effective_enabled?(&1, enablement_by_id))
        |> Enum.map(&definition_projection(&1, Map.get(enablement_by_id, &1["plugin_id"])))

      disabled =
        definitions
        |> Enum.reject(&effective_enabled?(&1, enablement_by_id))
        |> Enum.map(&definition_projection(&1, Map.get(enablement_by_id, &1["plugin_id"])))

      tool_policy = materialized_tool_policy(materialized)
      disabled_tool_policy = materialized_tool_policy(disabled)
      skill_policy = materialized_skill_policy(materialized)

      revision = projection_revision(materialized, disabled)

      {:ok,
       %{
         "revision" => revision,
         "tenant_id" => tenant_id,
         "group_id" => group_id,
         "enabled_plugin_ids" => Enum.map(materialized, & &1["plugin_id"]),
         "disabled_plugin_ids" => Enum.map(disabled, & &1["plugin_id"]),
         "locked_plugin_ids" =>
           definitions |> Enum.filter(& &1["locked"]) |> Enum.map(& &1["plugin_id"]),
         "plugins" => materialized,
         "allowed_tools" => tool_policy.exact,
         "allowed_tool_prefixes" => tool_policy.prefixes,
         "disabled_tools" => disabled_tool_policy.exact,
         "disabled_tool_prefixes" => disabled_tool_policy.prefixes,
         "visible_skill_ids" => skill_policy.exact,
         "visible_skill_prefixes" => skill_policy.prefixes
       }}
    end
  end

  def runtime_projection(_attrs),
    do: {:error, {:bad_request, "runtime projection attrs required"}}

  # ---- system catalog ----

  defp all_tenant_groups(tenant_id) do
    tenant_id
    |> Keys.ctl_groups_prefix_for_tenant()
    |> Store.list_keyed_records()
    |> Enum.flat_map(fn
      {key, %{"group_id" => group_id} = group} ->
        if key == Keys.ctl_group(group_id) and
             Ids.valid_group_id_for_tenant?(group_id, tenant_id) and
             trim(group["tenant_id"]) == tenant_id,
           do: [group],
           else: []

      _ ->
        []
    end)
  end

  # ---- lookups ----

  defp ensure_group_scope(tenant_id, group_id) do
    case Groups.get(group_id, tenant_id) do
      {:ok, _group} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp ensure_tenant_scope(tenant_id) do
    case Tenants.get(tenant_id) do
      {:ok, _tenant} -> :ok
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  defp visible_definitions(tenant_id, group_id) do
    visible_definitions_from(
      system_definitions_for_read(),
      Store.list_records(Keys.ctl_tenant_plugin_definitions_prefix(tenant_id)),
      Store.list_records(Keys.ctl_group_plugin_definitions_prefix(tenant_id, group_id)),
      tenant_id,
      group_id
    )
  end

  defp visible_definitions_from(system, tenant, group, tenant_id, group_id) do
    system
    |> Kernel.++(tenant)
    |> Kernel.++(group)
    |> Enum.filter(&definition_visible?(&1, tenant_id, group_id))
    |> Enum.uniq_by(& &1["plugin_id"])
    |> Enum.sort_by(&{definition_scope_rank(&1), &1["name"] || "", &1["plugin_id"] || ""})
  end

  defp tenant_visible_definitions(tenant_id) do
    system = system_definitions_for_read()
    tenant = Store.list_records(Keys.ctl_tenant_plugin_definitions_prefix(tenant_id))

    system
    |> Kernel.++(tenant)
    |> Enum.filter(fn
      %{"owner_scope" => "system"} -> true
      %{"owner_scope" => "tenant", "tenant_id" => ^tenant_id} -> true
      _ -> false
    end)
    |> Enum.uniq_by(& &1["plugin_id"])
    |> Enum.sort_by(&{definition_scope_rank(&1), &1["name"] || "", &1["plugin_id"] || ""})
  end

  defp system_definitions_for_read do
    @system_plugins
    |> Enum.map(&readonly_system_definition/1)
  end

  defp readonly_system_definition(attrs) do
    attrs = stringify(attrs)
    {:ok, refs} = normalize_refs(attrs)

    %{
      "owner_scope" => "system",
      "tenant_id" => "",
      "group_id" => "",
      "plugin_id" => attrs["plugin_id"],
      "version" => int(attrs["version"], 1),
      "name" => nonblank(attrs["name"], attrs["plugin_id"]),
      "description" => trim(attrs["description"]),
      "refs" => refs,
      "source" => "salix_builtin",
      "read_only" => true,
      "locked" => attrs["locked"] == true,
      "default_enabled" => attrs["default_enabled"] == true,
      "created_at" => 0,
      "updated_at" => 0
    }
    |> maybe_put("setup", attrs["setup"])
    |> maybe_put("ui", attrs["ui"])
    |> maybe_put("trust", attrs["trust"])
    |> maybe_put("manual", attrs["manual"])
  end

  defp find_visible_definition(tenant_id, group_id, plugin_id) do
    plugin_id = trim(plugin_id)

    case Enum.find(visible_definitions(tenant_id, group_id), &(&1["plugin_id"] == plugin_id)) do
      nil -> {:error, :not_found}
      definition -> {:ok, definition}
    end
  end

  defp find_mutable_definition_with_key(tenant_id, group_id, plugin_id) do
    plugin_id = trim(plugin_id)

    candidate_keys = [
      Keys.ctl_group_plugin_definition(tenant_id, group_id, plugin_id),
      Keys.ctl_tenant_plugin_definition(tenant_id, plugin_id)
    ]

    case Enum.reduce_while(candidate_keys, {:error, :not_found}, fn key, {:error, :not_found} ->
           case Store.get_record(key) do
             {:ok, %{"read_only" => true}} ->
               {:halt, {:error, {:bad_request, "plugin definition is read-only"}}}

             {:ok, rec} ->
               {:halt, {:ok, rec, key}}

             {:error, :not_found} ->
               {:cont, {:error, :not_found}}

             {:error, _} = err ->
               {:halt, err}
           end
         end) do
      {:error, :not_found} ->
        if system_plugin_id?(plugin_id),
          do: {:error, {:bad_request, "plugin definition is read-only"}},
          else: {:error, :not_found}

      result ->
        result
    end
  end

  defp find_mutable_tenant_definition_with_key(tenant_id, plugin_id) do
    plugin_id = trim(plugin_id)
    key = Keys.ctl_tenant_plugin_definition(tenant_id, plugin_id)

    case Store.get_record(key) do
      {:ok, %{"read_only" => true}} ->
        {:error, {:bad_request, "plugin definition is read-only"}}

      {:ok, rec} ->
        {:ok, rec, key}

      {:error, :not_found} ->
        if system_plugin_id?(plugin_id),
          do: {:error, {:bad_request, "plugin definition is read-only"}},
          else: {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  defp find_mutable_group_definition_with_key(tenant_id, group_id, plugin_id) do
    plugin_id = trim(plugin_id)
    key = Keys.ctl_group_plugin_definition(tenant_id, group_id, plugin_id)

    case Store.get_record(key) do
      {:ok, %{"read_only" => true}} ->
        {:error, {:bad_request, "plugin definition is read-only"}}

      {:ok, rec} ->
        {:ok, rec, key}

      {:error, :not_found} ->
        cond do
          system_plugin_id?(plugin_id) ->
            {:error, {:bad_request, "plugin definition is read-only"}}

          tenant_definition_exists?(tenant_id, plugin_id) ->
            {:error, {:bad_request, "tenant plugin definitions must be edited from org scope"}}

          true ->
            {:error, :not_found}
        end

      {:error, _} = err ->
        err
    end
  end

  defp definition_visible?(%{"owner_scope" => "system"}, _tenant_id, _group_id), do: true

  defp definition_visible?(%{"owner_scope" => "tenant"} = rec, tenant_id, _group_id),
    do: rec["tenant_id"] == tenant_id

  defp definition_visible?(%{"owner_scope" => "group"} = rec, tenant_id, group_id),
    do: rec["tenant_id"] == tenant_id and rec["group_id"] == group_id

  defp definition_visible?(_rec, _tenant_id, _group_id), do: false

  defp definition_scope_rank(%{"owner_scope" => "system"}), do: 0
  defp definition_scope_rank(%{"owner_scope" => "tenant"}), do: 1
  defp definition_scope_rank(%{"owner_scope" => "group"}), do: 2
  defp definition_scope_rank(_), do: 9

  defp ensure_definition_scope_available(tenant_id, group_id, plugin_id, "group") do
    cond do
      system_plugin_id?(plugin_id) ->
        {:error, :exists}

      true ->
        case find_visible_definition(tenant_id, group_id, plugin_id) do
          {:error, :not_found} -> :ok
          {:ok, _} -> {:error, :exists}
        end
    end
  end

  defp ensure_definition_scope_available(tenant_id, _group_id, plugin_id, "tenant") do
    cond do
      system_plugin_id?(plugin_id) ->
        {:error, :exists}

      tenant_definition_exists?(tenant_id, plugin_id) ->
        {:error, :exists}

      group_definition_exists_in_tenant?(tenant_id, plugin_id) ->
        {:error, :exists}

      true ->
        :ok
    end
  end

  # ---- enablement ----

  defp set_group_enabled(tenant_id, group_id, plugin_id, enabled) do
    tenant_id = trim(tenant_id)
    group_id = trim(group_id)
    plugin_id = trim(plugin_id)

    with {:ok, definition} <- get_definition(tenant_id, group_id, plugin_id),
         :ok <- ensure_enablement_allowed(definition, enabled) do
      key = Keys.ctl_group_plugin_enablement(tenant_id, group_id, plugin_id)
      now = Store.now()

      new_rec = %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "plugin_id" => plugin_id,
        "enabled" => enabled,
        "enabled_version" => definition["version"] || 1,
        "revision" => 1,
        "created_at" => now,
        "updated_at" => now
      }

      Store.upsert_record(key, new_rec, fn rec ->
        rec
        |> Map.put("enabled", enabled)
        |> Map.put("enabled_version", definition["version"] || rec["enabled_version"] || 1)
        |> Map.update("revision", 1, &(int(&1, 0) + 1))
        |> Map.put("updated_at", now)
      end)
      |> invalidate_group(group_id)
    end
  end

  defp ensure_enablement_allowed(%{"locked" => true}, _enabled),
    do: {:error, {:bad_request, "locked plugin enablement is fixed"}}

  defp ensure_enablement_allowed(_definition, _enabled), do: :ok

  # ---- projection ----

  @doc "Resolves a definition's effective state from its lock, group override, and default."
  def effective_enabled?(%{"locked" => true}, _enablements), do: true

  def effective_enabled?(definition, enablements) do
    case Map.fetch(enablements, definition["plugin_id"]) do
      {:ok, %{"enabled" => enabled}} when is_boolean(enabled) -> enabled
      :error -> definition["default_enabled"] == true
      {:ok, _invalid} -> false
    end
  end

  defp definition_projection(definition, enablement) do
    %{
      "plugin_id" => definition["plugin_id"],
      "name" => definition["name"],
      "owner_scope" => definition["owner_scope"],
      "version" => definition["version"],
      "locked" => definition["locked"] == true,
      "enabled_revision" => enablement && enablement["revision"],
      "refs" => definition["refs"] || %{}
    }
  end

  defp materialized_tool_policy(plugins) do
    refs =
      plugins
      |> Enum.flat_map(&(get_in(&1, ["refs", "tool_refs"]) || []))
      |> Enum.map(&ref_value(&1, "tool_id"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {prefixes, exact} =
      Enum.split_with(refs, &String.ends_with?(&1, ".*"))

    %{
      exact: Enum.sort(exact),
      prefixes: prefixes |> Enum.map(&String.trim_trailing(&1, "*")) |> Enum.sort()
    }
  end

  defp materialized_skill_policy(plugins) do
    refs =
      plugins
      |> Enum.flat_map(&(get_in(&1, ["refs", "skill_refs"]) || []))
      |> Enum.map(&ref_value(&1, "skill_id"))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {prefixes, exact} =
      Enum.split_with(refs, fn ref -> ref == "*" or String.ends_with?(ref, ".*") end)

    %{
      exact: Enum.sort(exact),
      prefixes: prefixes |> Enum.map(&skill_prefix/1) |> Enum.sort()
    }
  end

  defp skill_prefix("*"), do: ""
  defp skill_prefix(ref), do: String.trim_trailing(ref, "*")

  defp projection_revision(materialized, disabled) do
    :crypto.hash(
      :sha256,
      Jason.encode!(%{"plugins" => materialized, "disabled_plugins" => disabled})
    )
    |> Base.encode16(case: :lower)
  end

  # ---- normalization ----

  defp ensure_create_id_not_provided(attrs) do
    case trim(attrs["plugin_id"]) do
      "" -> :ok
      _ -> {:error, {:bad_request, "custom plugin_id is generated by Salix"}}
    end
  end

  defp normalize_owner_scope(nil), do: {:ok, "group"}
  defp normalize_owner_scope(""), do: {:ok, "group"}
  defp normalize_owner_scope("group"), do: {:ok, "group"}
  defp normalize_owner_scope("tenant"), do: {:ok, "tenant"}

  defp normalize_owner_scope(_scope),
    do: {:error, {:bad_request, "owner_scope must be group or tenant"}}

  defp normalize_refs(attrs) do
    raw_refs =
      attrs["refs"] ||
        %{
          "tool_refs" => attrs["tool_refs"],
          "skill_refs" => attrs["skill_refs"],
          "mcp_refs" => attrs["mcp_refs"],
          "oauth_requirements" => attrs["oauth_requirements"],
          "im_connect_requirements" => attrs["im_connect_requirements"]
        }

    refs =
      raw_refs
      |> stringify()
      |> Map.take(~w(tool_refs skill_refs mcp_refs oauth_requirements im_connect_requirements))
      |> Enum.map(fn {key, value} -> {key, normalize_ref_list(value)} end)
      |> Enum.reject(fn {_key, value} -> value == [] end)
      |> Map.new()

    {:ok, refs}
  end

  defp update_mutable_definition(key, definition, attrs) do
    with {:ok, refs} <- maybe_normalize_refs(attrs, definition["refs"]),
         :ok <- validate_refs(refs) do
      Store.update_record(key, fn rec ->
        rec
        |> maybe_put("name", attrs["name"])
        |> maybe_put("description", attrs["description"])
        |> maybe_put("setup", attrs["setup"])
        |> maybe_put("ui", attrs["ui"])
        |> maybe_put("trust", attrs["trust"])
        |> maybe_put("manual", attrs["manual"])
        |> Map.put("refs", refs)
        |> Map.put("updated_at", Store.now())
        |> Map.update("version", 1, &(int(&1, 1) + 1))
      end)
      |> public_ok()
    end
  end

  defp maybe_normalize_refs(attrs, current_refs) do
    if Map.has_key?(attrs, "refs") or
         Enum.any?(
           ~w(tool_refs skill_refs mcp_refs oauth_requirements im_connect_requirements),
           &Map.has_key?(attrs, &1)
         ) do
      normalize_refs(attrs)
    else
      {:ok, current_refs || %{}}
    end
  end

  defp normalize_ref_list(nil), do: []
  defp normalize_ref_list(value) when is_list(value), do: Enum.map(value, &normalize_ref/1)
  defp normalize_ref_list(value), do: [normalize_ref(value)]

  defp normalize_ref(value) when is_binary(value), do: trim(value)
  defp normalize_ref(value) when is_map(value), do: stringify(value)
  defp normalize_ref(value), do: to_string(value)

  defp validate_refs(refs) do
    count =
      refs
      |> Map.values()
      |> Enum.flat_map(&List.wrap/1)
      |> length()

    cond do
      count > @max_refs ->
        {:error, {:bad_request, "plugin refs exceed #{@max_refs} entries"}}

      duplicate_refs?(refs["tool_refs"]) ->
        {:error, {:bad_request, "plugin tool refs contain duplicates"}}

      invalid_tool_ref = invalid_canonical_refs(refs["tool_refs"], "tool_id") ->
        {:error, {:bad_request, "invalid plugin tool ref: #{invalid_tool_ref}"}}

      invalid_skill_ref = invalid_skill_refs(refs["skill_refs"]) ->
        {:error, {:bad_request, "invalid plugin skill ref: #{invalid_skill_ref}"}}

      invalid_mcp_ref = invalid_mcp_refs(refs["mcp_refs"]) ->
        {:error, {:bad_request, "invalid plugin mcp ref: #{invalid_mcp_ref}"}}

      invalid_oauth_ref = invalid_provider_refs(refs["oauth_requirements"]) ->
        {:error, {:bad_request, "invalid plugin oauth requirement: #{invalid_oauth_ref}"}}

      invalid_im_ref = invalid_provider_refs(refs["im_connect_requirements"]) ->
        {:error, {:bad_request, "invalid plugin im requirement: #{invalid_im_ref}"}}

      true ->
        :ok
    end
  end

  defp duplicate_refs?(refs) do
    values = refs |> List.wrap() |> Enum.map(&ref_value(&1, "tool_id"))
    length(values) != length(Enum.uniq(values))
  end

  defp invalid_canonical_refs(refs, key) do
    refs
    |> List.wrap()
    |> Enum.map(&ref_value(&1, key))
    |> Enum.find(fn ref -> ref == "" or not Regex.match?(@canonical_ref_re, ref) end)
  end

  defp invalid_skill_refs(refs) do
    refs
    |> List.wrap()
    |> Enum.map(&ref_value(&1, "skill_id"))
    |> Enum.find(fn ref ->
      ref == "" or (ref != "*" and not Regex.match?(@canonical_ref_re, ref))
    end)
  end

  defp invalid_mcp_refs(refs) do
    invalid_ref =
      refs
      |> List.wrap()
      |> Enum.find(fn ref ->
        binding_id = mcp_ref_binding_id(ref)
        mcp_id = mcp_ref_mcp_id(ref)

        cond do
          is_map(ref) and binding_id != "" ->
            not Regex.match?(@canonical_ref_re, binding_id)

          is_map(ref) and mcp_id != "" ->
            not Regex.match?(@canonical_ref_re, mcp_id)

          true ->
            value = mcp_ref_mcp_id(ref)
            value == "" or not Regex.match?(@canonical_ref_re, value)
        end
      end)

    case invalid_ref do
      nil -> nil
      ref -> mcp_ref_binding_id(ref) |> nonblank(mcp_ref_mcp_id(ref))
    end
  end

  defp mcp_ref_binding_id(ref) when is_map(ref), do: trim(ref["binding_id"])
  defp mcp_ref_binding_id(_ref), do: ""

  defp mcp_ref_mcp_id(ref) when is_map(ref), do: trim(ref["mcp_id"] || ref["id"] || ref["ref"])
  defp mcp_ref_mcp_id(ref), do: trim(ref)

  defp invalid_provider_refs(refs) do
    refs
    |> List.wrap()
    |> Enum.map(&ref_value(&1, "provider"))
    |> Enum.find(fn provider ->
      provider == "" or not Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, provider)
    end)
  end

  defp ref_value(ref, key) when is_map(ref), do: trim(ref[key] || ref["id"] || ref["ref"])
  defp ref_value(ref, _key), do: trim(ref)

  defp definition_key("tenant", tenant_id, _group_id, plugin_id),
    do: Keys.ctl_tenant_plugin_definition(tenant_id, plugin_id)

  defp definition_key("group", tenant_id, group_id, plugin_id),
    do: Keys.ctl_group_plugin_definition(tenant_id, group_id, plugin_id)

  defp system_plugin_id?(plugin_id) do
    plugin_id = trim(plugin_id)
    Enum.any?(@system_plugins, &(trim(&1["plugin_id"]) == plugin_id))
  end

  defp tenant_definition_exists?(tenant_id, plugin_id) do
    case Store.get_record(Keys.ctl_tenant_plugin_definition(tenant_id, plugin_id)) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp group_definition_exists_in_tenant?(tenant_id, plugin_id) do
    tenant_id
    |> all_tenant_groups()
    |> Enum.any?(fn group ->
      case Store.get_record(
             Keys.ctl_group_plugin_definition(tenant_id, group["group_id"], plugin_id)
           ) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end

  defp public_definition(definition) do
    Map.drop(definition, [])
  end

  defp public_ok({:ok, rec}), do: {:ok, public_definition(rec)}
  defp public_ok(other), do: other

  defp invalidate_definition(result, "tenant", tenant_id, _group_id),
    do: invalidate_tenant(result, tenant_id)

  defp invalidate_definition(result, _owner_scope, _tenant_id, group_id),
    do: invalidate_group(result, group_id)

  defp invalidate_tenant({:ok, _} = result, tenant_id) do
    :ok = PluginCatalogCache.invalidate_tenant(tenant_id)
    result
  end

  defp invalidate_tenant(result, _tenant_id), do: result

  defp invalidate_group({:ok, _} = result, group_id) do
    _ = PluginCatalogCache.invalidate_group(group_id)
    result
  end

  defp invalidate_group(:ok, group_id) do
    _ = PluginCatalogCache.invalidate_group(group_id)
    :ok
  end

  defp invalidate_group(result, _group_id), do: result

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp nonblank(value, fallback) do
    case trim(value) do
      "" -> fallback
      value -> value
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp int(value, _default) when is_integer(value), do: value

  defp int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp int(_value, default), do: default
end
