defmodule SalixAgent.Tools.PluginInstall do
  @moduledoc """
  A Router installs a Comma plugin from the chat: the person says "add
  Notion", or what they asked needs a plugin the Workspace does not have.
  The Router calls `plugin.request_install`, the Comma chat shows the
  plugin's install card, and the call waits until the plugin is installed,
  so the Router goes on without asking again.

  The product adapter (`:plugin_install_adapter_mod`) owns the catalog and
  who may install (the Workspace owner, from the message's server-sealed
  principal, never from the model). Its `start/2` answers
  `{:ok, %{"status" => "installed", "plugin" => ...}}`,
  `{:ok, %{"status" => "pending", "plugin" => ..., "workspace_id" => ...}}`
  or `{:error, reason}`. The card installs the plugin the way the Plugins
  page does; any install of it ends the call
  (`SalixAgent.CapabilityRequests.complete_plugin_install/3`), a decline on
  the card or the request's expiry ends it too.
  """

  alias SalixAgent.{CapabilityRequestStore, Waits}
  alias SalixAgent.Tools.AsyncPolicy

  @user_interaction_auto_wait_seconds AsyncPolicy.user_interaction_tool_auto_wait_seconds()
  @request_seconds 600

  def defs do
    [
      {"plugin.request_install",
       "Ask the user you serve to install a Comma plugin (an integration on Comma's Plugins page, such as Notion, GitHub, Gmail or Stripe) in this Workspace, " <>
         "when they ask to add, install or connect one, or what they asked needs a plugin that is not installed. " <>
         "Only the Workspace owner can install; the requester is the sender of the message you are answering. " <>
         "plugin_id is the plugin's id (e.g. notion); an unknown id fails with the plugins there are. reason says in one sentence, in the user's language, what the plugin is for here. " <>
         "An installed plugin answers status installed: go on. Otherwise the Comma chat shows the user an install card with the reason: do not post a link or steps. " <>
         "The call waits until they install it and returns status installed (or declined / expired): then go on, or tell them.",
       schema(), &__MODULE__.request_install/2, @user_interaction_auto_wait_seconds,
       [safety: "write", roles: ["router"], runtimes: [:internal]]}
    ]
  end

  def schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["plugin_id", "reason"],
      "properties" => %{
        "plugin_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
        "reason" => %{"type" => "string", "minLength" => 1, "maxLength" => 1000}
      }
    }
  end

  def request_install(args, ctx) do
    with :ok <- SalixAgent.Tools.validate_schema(args, schema()),
         {:ok, result} <- adapter().start(String.trim(args["plugin_id"]), ctx) do
      case result do
        %{"status" => "pending"} = pending ->
          case SalixAgent.Tools.OAuth.conversation_surface(ctx) do
            %{} = surface ->
              await(pending, String.trim(args["reason"]), surface, ctx)

            nil ->
              failure(
                "not_in_comma_chat",
                "The install card shows only in a Comma chat. Tell the user to add #{pending["plugin"]["name"]} on Comma's Plugins page."
              )
          end

        other ->
          Jason.encode!(other)
      end
    else
      {:error, reason} when is_binary(reason) ->
        failure("invalid_arguments", reason)

      {:error, :forbidden} ->
        failure("forbidden", "Only the Workspace owner can install its plugins.")

      {:error, :requester_unknown} ->
        failure(
          "requester_unknown",
          "The requester is not known as this Workspace's owner; the owner must ask in their own chat."
        )

      {:error, {:unknown_plugin, plugins}} ->
        failure(
          "unknown_plugin",
          "No plugin has that id. The plugins here: " <> Jason.encode!(plugins),
          plugins
        )

      {:error, {:device_plugin, name}} ->
        failure(
          "device_plugin",
          "#{name} runs on the user's own computer: tell them to add it on the Plugins page of Comma on that computer."
        )

      {:error, reason} ->
        failure("plugins_unavailable", "The plugins could not be read: #{inspect(reason)}")
    end
  end

  # The call stays open as a capability request until the plugin is
  # installed, the person declines on the card, or the request expires.
  defp await(pending, reason, surface, ctx) do
    {:ok, %{tenant: tenant, group_id: group_id}} =
      SalixAgent.OAuthStore.agent_oauth_context(ctx.agent_id)

    session_id = ctx.session_id
    tool_call_id = ctx[:tool_call_id] || random_id()
    plugin = pending["plugin"]

    {:ok, request} =
      CapabilityRequestStore.create_capability_request(
        %{
          "tenant_id" => tenant,
          "group_id" => group_id,
          "source_agent_id" => ctx.agent_id,
          "source_session_id" => session_id,
          "tool_call_id" => tool_call_id,
          "request_type" => "plugin_install",
          "request_payload" => %{
            "plugin_install" => %{
              "plugin_id" => plugin["id"],
              "name" => plugin["name"],
              "brand" => plugin["brand"],
              "reason" => reason,
              "workspace_id" => pending["workspace_id"],
              "tool_name" => "plugin.request_install"
            }
          },
          "expires_at" => div(SystemsClock.system_time(:millisecond), 1000) + @request_seconds
        }
        |> Map.merge(surface)
      )

    content =
      Jason.encode!(%{
        "status" => "running",
        "request_id" => request["request_id"],
        "tool_call_id" => tool_call_id,
        "plugin" => %{"id" => plugin["id"], "name" => plugin["name"]},
        "message" =>
          "The user sees an install card for #{plugin["name"]} in this chat; do not post a link or steps. " <>
            "This call returns status installed once they add it."
      })

    wait =
      Waits.build(
        "plugin install: " <> plugin["id"],
        @user_interaction_auto_wait_seconds,
        "auto_wait",
        %{"tool_call_id" => tool_call_id, "tool_name" => "plugin.request_install"}
      )

    {content,
     [
       %{
         "type" => "async_tool_call_started",
         "session_id" => session_id,
         "tool_call_id" => tool_call_id,
         "tool_name" => "plugin.request_install",
         "input" => Jason.encode!(%{"plugin_id" => plugin["id"], "reason" => reason}),
         "status" => "running",
         "completion_mode" => "external_callback",
         "started_at" => SystemsClock.system_time(:millisecond),
         "auto_wait_seconds" => @user_interaction_auto_wait_seconds
       }
       |> Map.merge(CapabilityRequestStore.execution_fields(request)),
       Waits.event(session_id, wait)
     ]}
  end

  defp random_id, do: SystemsRuntime.Proc.random_bytes(8) |> Base.encode16(case: :lower)

  defp adapter do
    case SystemsRuntime.get_env(:salix_agent, :plugin_install_adapter_mod) do
      nil -> raise "plugin installs are not available here"
      module -> module
    end
  end

  defp failure(code, message, details \\ nil) do
    payload =
      if details,
        do: %{"code" => code, "message" => message, "plugins" => details},
        else: %{"code" => code, "message" => message}

    {:tool_failure, Jason.encode!(payload), code, "user_reportable", message, []}
  end
end
