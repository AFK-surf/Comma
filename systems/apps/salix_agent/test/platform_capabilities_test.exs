defmodule SalixAgent.PlatformCapabilitiesTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{PlatformCapabilities, ToolDisclosure}

  defmodule Adapter do
    def capabilities(ctx),
      do:
        if(ctx[:ready],
          do: %{"question" => true, "permission" => true, "location" => true, "oauth" => true},
          else: %{}
        )
  end

  setup do
    previous = Application.get_env(:salix_agent, :telegram_interaction_mod)
    Application.put_env(:salix_agent, :telegram_interaction_mod, Adapter)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:salix_agent, :telegram_interaction_mod),
        else: Application.put_env(:salix_agent, :telegram_interaction_mod, previous)
    end)
  end

  test "Telegram product availability, not the platform name, controls disclosure and execution" do
    entries =
      for name <-
            ~w(question.request permission.request location.request oauth.request_authorization fs.read_file),
          do: %{"name" => name, "callable" => true, "helpable" => true}

    config = %{role: "router", tool_specs: [], tool_disclosure: %{"tools" => entries}}
    ctx = %{trusted_origin: %{"provider" => "telegram"}}
    scoped = PlatformCapabilities.scope_config(config, ctx)
    assert Enum.map(scoped.tool_disclosure["tools"], & &1["name"]) == ["fs.read_file"]
    # Even a stale full disclosure cannot bypass the current source gate.
    stale = Map.put(ctx, :tool_disclosure, config.tool_disclosure)
    refute ToolDisclosure.callable?(stale, "location.request")
    refute ToolDisclosure.helpable?(stale, "permission.request")
    assert ToolDisclosure.callable?(Map.put(stale, :ready, true), "location.request")

    assert length(
             PlatformCapabilities.scope_config(config, Map.put(ctx, :ready, true)).tool_disclosure[
               "tools"
             ]
           ) == 5
  end

  test "internal sessions retain their resolved tool specs and prompt" do
    config = %{
      role: "worker",
      tool_specs: [%{"name" => "custom_runtime_tool"}],
      tool_disclosure: %{"tools" => [%{"name" => "fs.read_file"}]}
    }

    for origin <- [nil, %{}, %{"provider" => "internal"}] do
      ctx = %{trusted_origin: origin}
      assert PlatformCapabilities.scope_config(config, ctx) == config

      assert PlatformCapabilities.request_prompt("stored prompt", config.tool_disclosure, origin) ==
               "stored prompt"
    end
  end

  test "Telegram location requires dialogue locale without changing the internal host contract" do
    entry = %{
      "name" => "location.request",
      "callable" => true,
      "helpable" => true,
      "input_schema" => SalixAgent.Tools.Schemas.schema("location.request")
    }

    config = %{role: "router", tool_specs: [], tool_disclosure: %{"tools" => [entry]}}
    ctx = %{ready: true, trusted_origin: %{"provider" => "telegram"}}
    scoped = PlatformCapabilities.scope_config(config, ctx)
    schema = hd(scoped.tool_disclosure["tools"])["input_schema"]

    assert {:error, "missing required params: locale"} =
             SalixAgent.Tools.validate_schema(%{"reason" => "查询天气"}, schema)

    assert :ok =
             SalixAgent.Tools.validate_schema(%{"reason" => "查询天气", "locale" => "zh-CN"}, schema)

    assert PlatformCapabilities.scope_config(config, %{
             trusted_origin: %{"provider" => "internal"}
           }) == config

    assert :ok = SalixAgent.Tools.validate_schema(%{"reason" => "查询天气"}, entry["input_schema"])
  end

  test "current-source guidance preserves the stored snapshot" do
    stored = "Earlier tool catalog: Telegram only supports plain-text questions."
    disclosure = %{"tools" => [%{"name" => "question.request"}]}

    prompt =
      PlatformCapabilities.request_prompt(stored, disclosure, %{"provider" => "telegram"})

    assert String.starts_with?(prompt, stored)
  end

  test "other messaging providers cannot request host popups or native Telegram questions" do
    for provider <- ["slack", "feishu", "wechat"] do
      ctx = %{trusted_origin: %{"provider" => provider}}

      for tool <- ~w(location.request permission.request question.request),
          do: refute(PlatformCapabilities.allowed?(ctx, tool))

      assert PlatformCapabilities.allowed?(ctx, "oauth.request_authorization")
      assert PlatformCapabilities.allowed?(ctx, "fs.read_file")
    end

    assert PlatformCapabilities.allowed?(%{}, "location.request")
    refute PlatformCapabilities.allowed?(%{}, "question.request")
  end
end
