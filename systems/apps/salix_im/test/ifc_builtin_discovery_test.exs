defmodule SalixIM.IFCBuiltinDiscoveryTest do
  use ExUnit.Case, async: false

  test "built-in discovery and help work without tenant or connection access" do
    old = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, SalixIM.Provider)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :im_provider_mod, old) end)

    assert {:tool_ifc, body, [], %{"label" => ["public"]}} =
             SalixAgent.Tools.ImRouter.provider_apis_list(%{"provider" => "slack"}, %{})

    catalog = Jason.decode!(body)
    assert Enum.any?(catalog["apis"], &(&1["operation_id"] == "im_api.slack.reply_message"))

    assert SalixAgent.IFC.LocalMetadata.exempt?(
             "help",
             %{"tool" => "im_api.slack.reply_message"},
             %{}
           )

    refute SalixAgent.IFC.LocalMetadata.exempt?(
             "help",
             %{"tool" => "im_api.slack.tenant_defined"},
             %{}
           )

    assert {:error, :unsupported} = SalixIM.Provider.builtin_provider_manual("tenant_defined")
  end
end
