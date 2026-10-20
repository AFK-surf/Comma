defmodule SalixAgent.PluginPolicyTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.PluginPolicy

  test "a disabled plugin blocks only its declared tool refs" do
    ctx = %{
      plugin_projection: %{
        "revision" => "disabled-plugin",
        "disabled_tools" => ["agent.create_worker"],
        "disabled_tool_prefixes" => ["composio."]
      }
    }

    refute PluginPolicy.allowed_tool?(ctx, "agent.create_worker")
    refute PluginPolicy.allowed_tool?(ctx, "composio.execute")
    assert PluginPolicy.allowed_tool?(ctx, "im_api.internal.task.create")
    assert PluginPolicy.allowed_tool?(ctx, "unassociated.tool")
  end

  test "IM providers default on and only an explicit disabled family hides them" do
    assert PluginPolicy.visible_im_provider?(%{}, "slack")

    projection = fn attrs ->
      %{
        plugin_projection:
          Map.merge(
            %{
              "revision" => "im-provider",
              "allowed_tools" => [],
              "allowed_tool_prefixes" => [],
              "disabled_tools" => [],
              "disabled_tool_prefixes" => []
            },
            attrs
          )
      }
    end

    assert PluginPolicy.visible_im_provider?(
             projection.(%{"disabled_tools" => ["im_api.slack.post_message"]}),
             "slack"
           )

    refute PluginPolicy.visible_im_provider?(
             projection.(%{"disabled_tool_prefixes" => ["im_api.slack."]}),
             "slack"
           )

    assert PluginPolicy.visible_im_provider?(
             projection.(%{
               "allowed_tools" => ["im_api.slack.post_message"],
               "disabled_tool_prefixes" => ["im_api.slack."]
             }),
             "slack"
           )

    assert PluginPolicy.visible_im_provider?(
             projection.(%{
               "allowed_tool_prefixes" => ["im_api.slack.chat."],
               "disabled_tool_prefixes" => ["im_api.slack."]
             }),
             "slack"
           )
  end
end
