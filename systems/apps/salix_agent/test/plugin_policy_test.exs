defmodule SalixAgent.PluginPolicyTest do
  use ExUnit.Case, async: true

  alias SalixAgent.PluginPolicy

  test "tools default to enabled without an explicit plugin disable" do
    assert PluginPolicy.allowed_tool?(%{}, "agent.create_worker")

    assert PluginPolicy.allowed_tool?(
             %{
               plugin_projection: %{
                 "revision" => "default-on",
                 "allowed_tools" => [],
                 "allowed_tool_prefixes" => []
               }
             },
             "agent.create_worker"
           )
  end

  test "tool disclosure does not require an enabled-plugin allowlist entry" do
    projection = %{
      "revision" => "default-on-disclosure",
      "allowed_tools" => [],
      "allowed_tool_prefixes" => [],
      "disabled_tools" => [],
      "disabled_tool_prefixes" => []
    }

    disclosure =
      SalixAgent.ToolDisclosure.materialize("router", :internal, %{
        plugin_projection: projection
      })

    assert %{"callable" => true, "helpable" => true} =
             Enum.find(disclosure["tools"], &(&1["name"] == "agent.create_worker"))
  end

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

  test "renamed device tools retain exact and prefix plugin policy identities" do
    ctx = fn attrs -> %{plugin_projection: Map.put(attrs, "revision", "device-policy")} end

    for denied <- [
          %{"disabled_tools" => ["env.get", "env.list"]},
          %{"disabled_tool_prefixes" => ["env."]},
          %{"disabled_tool_prefixes" => ["device."]}
        ] do
      refute PluginPolicy.allowed_tool?(ctx.(denied), "device.get")
      refute PluginPolicy.allowed_tool?(ctx.(denied), "device.list")
    end

    assert PluginPolicy.allowed_tool?(
             ctx.(%{"disabled_tool_prefixes" => ["device."]}),
             "env.exec"
           )

    assert PluginPolicy.allowed_tool?(
             ctx.(%{"allowed_tools" => ["env.get"], "disabled_tools" => ["device.get"]}),
             "device.get"
           )

    assert PluginPolicy.allowed_tool?(
             ctx.(%{"allowed_tools" => ["device.get"], "disabled_tools" => ["env.get"]}),
             "device.get"
           )
  end

  test "an enabled plugin keeps a shared tool enabled" do
    ctx = %{
      plugin_projection: %{
        "revision" => "shared-tool",
        "allowed_tools" => ["agent.create_worker"],
        "allowed_tool_prefixes" => [],
        "disabled_tools" => ["agent.create_worker"],
        "disabled_tool_prefixes" => []
      }
    }

    assert PluginPolicy.allowed_tool?(ctx, "agent.create_worker")
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
