defmodule SalixAgent.IFCStaticDiscoveryTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.Tools.ImRouter
  alias SalixAgent.IFC.LocalMetadata

  defmodule Producer do
    def builtin_provider_manual("slack"),
      do: {:ok, %{"apis" => [%{"name" => "reply_message", "description" => "Static help"}]}}

    def builtin_provider_manual("internal"),
      do:
        {:ok,
         %{"apis" => [%{"name" => "send_message", "description" => "Static internal delivery"}]}}

    def builtin_provider_manual(_), do: {:error, :unsupported}

    def provider_manual(_),
      do: {:ok, %{"apis" => [%{"name" => "tenant_secret", "description" => "TENANT_SECRET"}]}}

    def list_connects(_), do: {:ok, [%{"connect_id" => "tenant", "provider" => "slack"}]}
  end

  setup do
    old = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, Producer)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :im_provider_mod, old) end)
  end

  test "projected common IM catalog comes from the static producer" do
    entries =
      for name <- ["im_api.internal.send_message", "im_api.internal.private_plugin"] do
        %{
          "name" => name,
          "callable" => true,
          "summary" => "TENANT_SECRET",
          "manual" => "TENANT_SECRET"
        }
      end

    prompt =
      SalixAgent.ToolDisclosure.projected_prompt_section(
        %{"tools" => entries},
        "router",
        :internal
      )

    assert is_binary(prompt)
    assert prompt =~ "im_api.internal.send_message"
    assert prompt =~ "Static internal delivery"
    refute prompt =~ "private_plugin"
    refute prompt =~ "TENANT_SECRET"
  end

  test "only static no-connect discovery receives trusted public provenance" do
    assert {:tool_ifc, body, [], %{"label" => ["public"]}} =
             ImRouter.provider_apis_list(%{"provider" => "slack"}, %{
               agent_id: "agent",
               role: "router"
             })

    refute body =~ "TENANT_SECRET"
    assert body =~ "reply_message"

    connected =
      ImRouter.provider_apis_list(%{"provider" => "slack", "connect_id" => "tenant"}, %{
        agent_id: "agent",
        role: "router"
      })

    assert is_binary(connected)
    assert connected =~ "TENANT_SECRET"
  end

  test "help omission matches exact builtin operations and never arbitrary or tenant names" do
    assert LocalMetadata.exempt?("help", %{"tool" => "im_api.slack.reply_message"}, %{})
    refute LocalMetadata.exempt?("help", %{"tool" => "im_api.slack.tenant_secret"}, %{})
    refute LocalMetadata.exempt?("help", %{"tool" => "im_api.evil.reply_message"}, %{})

    refute LocalMetadata.exempt?(
             "help",
             %{"tool" => "im_api.slack.reply_message", "extra" => "secret"},
             %{}
           )
  end

  test "static help never reads same-name tenant overrides and malformed declarations still fail" do
    entry = %{
      "name" => "im_api.slack.reply_message",
      "manual" => "TENANT_SECRET",
      "summary" => "TENANT_SECRET",
      "helpable" => true,
      "callable" => true,
      "input_schema" => %{"type" => "object", "properties" => %{}}
    }

    ctx = %{
      ifc_mode: :enforce,
      llm_tool_envelope: true,
      tool_disclosure: %{
        "tools" => [
          entry,
          %{
            "name" => "help",
            "callable" => true,
            "helpable" => true,
            "input_schema" => %{"type" => "object"}
          }
        ]
      }
    }

    help = SalixAgent.Tools.help(%{"tool" => "im_api.slack.reply_message"}, ctx)
    refute help =~ "TENANT_SECRET"
    assert help =~ "Static help"

    invalid = %{
      id: "bad",
      name: "call",
      args: %{
        "tool" => "help",
        "params" => %{"tool" => "im_api.slack.reply_message"},
        "ifc" => %{}
      }
    }

    [prepared] = SalixAgent.Tools.prepare_for_dispatch([invalid], ctx)
    assert {:ok, result} = SalixAgent.Tools.prepared_guidance_result(prepared)
    assert Jason.decode!(result.content)["guidance_reason"] == "invalid_params"
  end
end
