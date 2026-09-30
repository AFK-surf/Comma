defmodule SalixAgent.BillingTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{Billing, ExternalSessionActor}
  alias SalixStore.RuntimeIds

  @runtime_status_pid_key {__MODULE__, :runtime_status_pid}
  @device_runtime_id RuntimeIds.device_runtime_id("test-device", "codex", "test-runtime")
  @session_id "ses1_0000000000000000602"

  defmodule RuntimeEnv do
    @moduledoc false
    @behaviour SalixAgent.RuntimeEnvironment

    @runtime_status_pid_key {SalixAgent.BillingTest, :runtime_status_pid}

    @impl true
    def resolve_external_runtime_binding(config, _tenant_id, _group_id) do
      {:ok,
       %{
         "kind" => "external",
         "provider" => config["provider"] || "codex",
         "device_id" => config["device_id"] || "test-device",
         "connector_id" => "test-connector",
         "connector_run_id" => "test-connector-run",
         "runtime_id" => config["runtime_id"] || "test-runtime",
         "device_runtime_id" => config["device_runtime_id"] || "test-device-runtime",
         "command" => config["command"] || "codex"
       }}
    end

    @impl true
    def external_runtime_binding_status(config, tenant_id, group_id) do
      send(
        :persistent_term.get(@runtime_status_pid_key),
        {:runtime_environment_status, config, tenant_id, group_id}
      )

      {:ok,
       %{
         "status" => "ready",
         "connector_run_id" => "test-connector-run",
         "device_id" => config["device_id"] || "test-device",
         "device_runtime_id" => config["device_runtime_id"]
       }}
    end
  end

  setup do
    prev_store = Application.get_env(:salix_store, :s3_backend)
    prev_runtime_environment = Application.get_env(:salix_agent, :runtime_environment_mod)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :runtime_environment_mod, RuntimeEnv)
    :persistent_term.put(@runtime_status_pid_key, self())
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      :persistent_term.erase(@runtime_status_pid_key)
      restore_env(:salix_store, :s3_backend, prev_store)
      restore_env(:salix_agent, :runtime_environment_mod, prev_runtime_environment)
    end)

    :ok
  end

  test "list_history reads external billing usage without runtime environment fan-out" do
    agent_id = unique_id("billing-external")
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    SalixAgent.TestSupport.create_control_agent!(agent_id, %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "role" => "worker",
      "model" => "gpt-5.3-codex-spark",
      "runtime_config" => %{
        "kind" => "external",
        "provider" => "codex",
        "device_id" => "test-device",
        "runtime_id" => "test-runtime",
        "device_runtime_id" => @device_runtime_id
      }
    })

    {:ok, pid} =
      ExternalSessionActor.start_link(
        agent_id: agent_id,
        session_id: @session_id,
        process_on_init: false
      )

    assert {:ok, :committed} =
             ExternalSessionActor.stage_delivery(pid, %{
               "source_message_id" => "billing-context",
               "payload" => %{
                 "session_id" => @session_id,
                 "role" => "user",
                 "content" => "billing context",
                 "no_wake" => true
               }
             })

    assert {:ok, binding} =
             ExternalSessionActor.begin_session(
               pid,
               tenant_id,
               %{
                 "kind" => "external",
                 "provider" => "codex",
                 "device_id" => "test-device",
                 "runtime_id" => "test-runtime",
                 "device_runtime_id" => @device_runtime_id
               }
             )

    put_session_event(pid, binding["runtime_capability"]["token_hash"], %{
      "event_id" => "event-usage-1",
      "event_ref" => "00000000000000000001",
      "source" => "codex_app_server",
      "session_id" => @session_id,
      "method" => "turn/completed",
      "event" => %{},
      "model" => "gpt-5.3-codex-spark",
      "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18},
      "created_at" => 123
    })

    assert {:ok,
            %{
              "data" => [
                %{
                  "session_id" => @session_id,
                  "model" => "gpt-5.3-codex-spark",
                  "provider_type" => "codex",
                  "call_kind" => "agent",
                  "input_tokens" => 11,
                  "output_tokens" => 7,
                  "total_tokens" => 18
                }
              ],
              "has_more" => false,
              "next_after_id" => 1
            }} = Billing.list_history(agent_id, [limit: 500], tenant_id)

    refute_received {:runtime_environment_status, _config, _tenant_id, _group_id}
  end

  defp put_session_event(pid, token_hash, event) do
    assert {:ok, _session, _record} =
             ExternalSessionActor.append_event(pid, %{
               "event" => event["event"],
               "model" => event["model"],
               "usage" => event["usage"],
               "token_hash" => token_hash
             })
  end

  defp unique_id(_prefix), do: SalixAgent.TestSupport.new_agent_id()

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
