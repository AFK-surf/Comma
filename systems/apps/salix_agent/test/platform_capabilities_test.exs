defmodule SalixAgent.PlatformCapabilitiesTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.{ContextProviders, PlatformCapabilities, ToolDisclosure}

  defmodule Adapter do
    def capabilities(ctx),
      do:
        if(ctx[:ready],
          do: %{"question" => true, "permission" => true, "location" => true, "oauth" => true},
          else: %{}
        )
  end

  setup do
    previous = SystemsRuntime.get_env(:salix_agent, :telegram_interaction_mod)
    SystemsRuntime.put_env(:salix_agent, :telegram_interaction_mod, Adapter)

    on_exit(fn ->
      if is_nil(previous),
        do: SystemsRuntime.delete_env(:salix_agent, :telegram_interaction_mod),
        else: SystemsRuntime.put_env(:salix_agent, :telegram_interaction_mod, previous)
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

  test "current-source guidance is an activation message stored once per tool set" do
    disclosure = %{"tools" => [%{"name" => "question.request"}, %{"name" => "fs.read_file"}]}
    telegram = %{"provider" => "telegram"}

    assert %{messages: [message], provider_state: state} =
             ContextProviders.with_interaction_reminder(nil, %{}, disclosure, telegram)

    assert state == %{"interaction_tools" => %{"tools" => ["question.request"]}}
    assert message["runtime_message_type"] == "runtime_guidance"
    assert message["content"] =~ ~s(Current-source interaction tools: ["question.request"])

    # A session that already stored this set gets nothing new, so the request
    # prefix is the stored history.
    stored = %{context_provider_states: state}
    assert ContextProviders.with_interaction_reminder(nil, stored, disclosure, telegram) == nil

    # A changed set appends a new reminder and keeps the other provider states.
    known = Map.put(state, "time_context", %{"day" => "2026-10-09"})
    delta = %{messages: [], provider_state: known}
    narrower = %{"tools" => [%{"name" => "fs.read_file"}]}

    assert %{messages: [changed], provider_state: next} =
             ContextProviders.with_interaction_reminder(delta, %{}, narrower, telegram)

    assert changed["content"] =~ "Current-source interaction tools: []"
    assert next == Map.put(known, "interaction_tools", %{"tools" => []})
  end
end
