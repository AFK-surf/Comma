defmodule CommaWeb.PluginInstallTools do
  @moduledoc """
  The Comma side of the `plugin.request_install` Router tool
  (`SalixAgent.Tools.PluginInstall`): a Workspace owner installs a plugin
  from the Router chat, on a card there, the way the Plugins page installs
  it.

  The requester is the Workspace owner the turn's message came from
  (`CommaWeb.ChannelLinkTools.owner/1`); nobody else installs. The catalog
  is the Workspace's own (`Comma.Plugins.list/4`). A plugin that runs on the
  member's own computer (a `device_client` connection: the Mac apps,
  Blender) is installed from Comma on that computer, so it gets no card.
  The card's install is the Plugins page's; `Comma.Plugins.install/4` ends
  every call waiting for the plugin.
  """

  alias CommaWeb.ChannelLinkTools
  alias SalixAgent.PluginStore

  @doc """
  `{:ok, %{"status" => "installed" | "pending", "plugin" => ...}}` for a
  plugin of the requester's Workspace, or an error.
  """
  def start(plugin_id, ctx) do
    with {:ok, user, workspace} <- ChannelLinkTools.owner(ctx),
         {:ok, plugins} <- Comma.Plugins.list(user, %{}, workspace["id"]) do
      case Enum.find(plugins, &(&1["id"] == plugin_id)) do
        nil ->
          {:error, {:unknown_plugin, Enum.map(plugins, &listed/1)}}

        %{"installed" => true} = plugin ->
          {:ok, %{"status" => "installed", "plugin" => brief(plugin)}}

        plugin ->
          if device_plugin?(workspace, plugin_id),
            do: {:error, {:device_plugin, plugin["name"]}},
            else:
              {:ok,
               %{
                 "status" => "pending",
                 "plugin" => brief(plugin),
                 "workspace_id" => workspace["id"]
               }}
      end
    end
  end

  defp device_plugin?(workspace, plugin_id) do
    case PluginStore.get_definition(
           workspace["salix_tenant_id"],
           workspace["default_group_id"],
           plugin_id
         ) do
      {:ok, %{} = definition} ->
        definition
        |> get_in(["setup", "connections"])
        |> List.wrap()
        |> Enum.any?(&match?(%{"kind" => "device_client"}, &1))

      _unreadable ->
        false
    end
  end

  defp brief(plugin),
    do: %{"id" => plugin["id"], "name" => plugin["name"], "brand" => plugin["brand"]}

  defp listed(plugin),
    do: %{"id" => plugin["id"], "name" => plugin["name"], "installed" => plugin["installed"]}
end
