defmodule SalixAgent.PluginInstallDeltaTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{CapabilityRequests, ContextProviders, MigrationNotice, TestSupport}

  defp adopted_context(session) do
    Map.put(session, "messages", [%{"role" => "assistant", "content" => "earlier reply"}])
  end

  defp session_with_state(state) do
    adopted_context(%{"context_provider_states" => state})
  end

  defp baseline_config(revision, enabled_ids) do
    %{
      plugin_projection_revision: revision,
      plugin_projection: %{
        "revision" => revision,
        "enabled_plugin_ids" => enabled_ids
      }
    }
  end

  defp adopt_baseline(config) do
    base_session =
      session_with_state(%{
        "migration_notice" => %{"version" => MigrationNotice.version()}
      })

    assert {:delta, adopt} = ContextProviders.prepare_activation_delta(base_session, config)
    session_with_state(ContextProviders.adopted_provider_state(adopt))
  end

  describe "ContextProviders plugin delta" do
    test "reports exact newly enabled plugin and settles to :none after adoption" do
      session = adopt_baseline(baseline_config("rev-1", ["github"]))
      after_config = baseline_config("rev-2", ["github", "outlook"])

      assert {:delta, delta} = ContextProviders.prepare_activation_delta(session, after_config)
      assert [message] = ContextProviders.model_messages(delta)
      assert message.content =~ "enabled: outlook"
      refute message.content =~ "disabled:"

      adopted = session_with_state(ContextProviders.adopted_provider_state(delta))
      assert :none = ContextProviders.prepare_activation_delta(adopted, after_config)
    end

    test "reports exact disabled plugins and combined enable/disable transitions" do
      session = adopt_baseline(baseline_config("rev-1", ["github", "outlook"]))

      assert {:delta, disable_delta} =
               ContextProviders.prepare_activation_delta(
                 session,
                 baseline_config("rev-2", ["github"])
               )

      assert [disable_msg] = ContextProviders.model_messages(disable_delta)
      assert disable_msg.content =~ "disabled: outlook"
      refute disable_msg.content =~ "enabled:"

      assert {:delta, swap_delta} =
               ContextProviders.prepare_activation_delta(
                 session,
                 baseline_config("rev-3", ["notion"])
               )

      assert [swap_msg] = ContextProviders.model_messages(swap_delta)
      assert swap_msg.content =~ "enabled: notion; disabled: github, outlook"
    end

    test "emits a neutral update when revision changes with an unchanged enabled plugin set" do
      session = adopt_baseline(baseline_config("rev-1", ["outlook"]))
      after_config = baseline_config("rev-2", ["outlook"])

      assert {:delta, delta} = ContextProviders.prepare_activation_delta(session, after_config)
      assert [message] = ContextProviders.model_messages(delta)
      refute message.content =~ "enabled:"
      refute message.content =~ "disabled:"
    end

    test "upgrades legacy provider state silently on unchanged revision and falls back on revision change" do
      legacy_session = adopt_baseline(%{plugin_projection_revision: "rev-1"})

      assert get_in(legacy_session, ["context_provider_states", "plugins"]) == %{
               "revision" => "rev-1"
             }

      same_rev_config = baseline_config("rev-1", ["outlook"])

      assert {:delta, adopt} =
               ContextProviders.prepare_activation_delta(legacy_session, same_rev_config)

      assert ContextProviders.model_messages(adopt) == []
      assert get_in(adopt.provider_state, ["plugins", "enabled_plugin_ids"]) == ["outlook"]

      assert {:delta, fallback_delta} =
               ContextProviders.prepare_activation_delta(
                 legacy_session,
                 baseline_config("rev-2", ["outlook"])
               )

      assert [fallback_msg] = ContextProviders.model_messages(fallback_delta)
      refute fallback_msg.content =~ "enabled:"
      refute fallback_msg.content =~ "disabled:"
    end
  end

  describe "plugin install settlement" do
    test "complete_plugin_install/3 and complete_plugin_install_in_tx/3 produce identical settled payloads" do
      suffix = SystemsRuntime.Proc.unique_integer([:positive])
      tenant = SalixStore.Ids.new_tenant_id()
      group = SalixStore.Ids.new_group_id(tenant)

      agent =
        TestSupport.create_control_agent_in_group!(tenant, group, %{
          "role" => "router",
          "runtime_config" => %{"kind" => "internal"}
        })

      now = div(SystemsClock.system_time(:millisecond), 1000)

      create_pending = fn tool_call_id ->
        {:ok, req} =
          CapabilityRequests.create_capability_request(%{
            "tenant_id" => tenant,
            "group_id" => group,
            "source_agent_id" => agent["agent_id"],
            "source_session_id" => SalixStore.Ids.new_session_id(),
            "tool_call_id" => tool_call_id,
            "request_type" => "plugin_install",
            "request_payload" => %{
              "plugin_install" => %{
                "plugin_id" => "outlook",
                "name" => "Microsoft Outlook",
                "reason" => "Connect Outlook mail."
              }
            },
            "expires_at" => now + 600
          })

        req["request_id"]
      end

      req_direct = create_pending.("call-direct-#{suffix}")
      assert :ok = CapabilityRequests.complete_plugin_install(group, tenant, "outlook")
      assert {:ok, settled_direct} = CapabilityRequests.get(group, req_direct, tenant)

      assert settled_direct["response_payload"] == %{
               "status" => "installed",
               "plugin_id" => "outlook"
             }

      direct_payload = Jason.decode!(settled_direct["result"]["content"])
      assert direct_payload["status"] == "installed"
      assert direct_payload["plugin_id"] == "outlook"
      assert is_binary(direct_payload["message"]) and direct_payload["message"] != ""

      req_tx = create_pending.("call-tx-#{suffix}")

      assert {:ok, [{settled_tx, true}]} =
               CapabilityRequests.complete_plugin_install_in_tx(group, tenant, "outlook")

      assert settled_tx["request_id"] == req_tx

      assert settled_tx["response_payload"] == %{
               "status" => "installed",
               "plugin_id" => "outlook"
             }

      tx_payload = Jason.decode!(settled_tx["result"]["content"])
      assert tx_payload == direct_payload
    end
  end
end
