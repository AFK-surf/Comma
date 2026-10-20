defmodule SalixAgent.BillingTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.Billing
  alias SalixAgent.TestSupport.RetiredSessionFixture

  @session_id "ses1_0000000000000000602"

  setup do
    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, prev_store)
    end)

    :ok
  end

  test "list_history includes usage recorded by a retired External Session" do
    agent_id = SalixAgent.TestSupport.new_agent_id()
    group_id = SalixStore.Ids.group_id_from_agent!(agent_id)
    tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "role" => "worker"
      })

    RetiredSessionFixture.put!(agent, @session_id, %{}, [
      %{"type" => "message", "data" => %{"role" => "user", "content" => "billing context"}},
      %{
        "type" => "runtime.event",
        "data" => %{
          "event" => %{"method" => "turn/completed"},
          "model" => "gpt-5.3-codex-spark",
          "usage" => %{"input_tokens" => 11, "output_tokens" => 7, "total_tokens" => 18}
        },
        "created_at" => 123
      }
    ])

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
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
