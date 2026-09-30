defmodule SalixIM.TriageThreadSubscriptionTest do
  use ExUnit.Case, async: true

  alias SalixIM.Provider.Slack.TriageThreadSubscription
  alias SalixStore.{Ids, ULID}

  defmodule OwnerPort do
    def lookup(scope) do
      send(self(), {:owner_lookup, scope})
      Process.get(:owner_lookup, :unbound)
    end

    def claim_triage(scope, claim_identity) do
      send(self(), {:owner_claim, scope, claim_identity})
      Process.get(:owner_claim, {:ok, :triage})
    end
  end

  defmodule StorePort do
    def product_scope(target, identity) do
      send(self(), {:product_scope, target, identity})
      Process.get(:product_scope, {:ok, Process.get(:scope)})
    end

    def activate(scope, provenance) do
      send(self(), {:activate, scope, provenance})
      Process.get(:activate, {:ok, :created})
    end

    def status(scope) do
      send(self(), {:status, scope})
      Process.get(:status, {:ok, :active})
    end
  end

  defmodule ContinuationContext do
    def deliver_participation(_claim, _status, _opts), do: Process.get(:continuation_context, :ok)
  end

  setup do
    scope = scope()
    Process.put(:scope, scope)
    Process.put(:owner_lookup, :unbound)
    Process.put(:owner_claim, {:ok, :triage})
    Process.put(:activate, {:ok, :created})
    Process.put(:status, {:ok, :active})
    {:ok, scope: scope}
  end

  test "only a provider-confirmed direct Triage reply claims and activates", %{scope: scope} do
    claim = claim(scope)
    result = {:ok, %{"channel" => scope["channel_id"], "ts" => "101.000001"}}

    assert TriageThreadSubscription.after_reply(claim, result,
             owner_port: OwnerPort,
             store_port: StorePort,
             continuation_context_port: ContinuationContext
           ) == result

    route_scope = Map.delete(scope, "agent_id")
    assert_receive {:owner_lookup, ^route_scope}
    assert_receive {:owner_claim, ^route_scope, claim_identity}
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, claim_identity)

    obligation_id = claim.obligation_id

    assert_receive {:activate, ^scope,
                    %{
                      "obligation_id" => ^obligation_id,
                      "provider_message_ref" => "slack:101.000001"
                    }}

    assert_receive {:product_scope, _target, _identity}
    refute_receive _message
  end

  test "failed and malformed provider results never activate", %{scope: scope} do
    claim = claim(scope)

    assert TriageThreadSubscription.after_reply(claim, {:error, :timeout},
             owner_port: OwnerPort,
             store_port: StorePort,
             continuation_context_port: ContinuationContext
           ) == {:error, :timeout}

    assert {:unknown, %{"status" => "triage_subscription_contract_invalid"},
            :invalid_subscription} =
             TriageThreadSubscription.after_reply(
               claim,
               {:ok, %{"channel" => "C_WRONG", "ts" => "101.000001"}},
               owner_port: OwnerPort,
               store_port: StorePort,
               continuation_context_port: ContinuationContext
             )

    refute_receive {:activate, _scope, _provenance}
  end

  test "temporary activation failure preserves provider success for local-only retry", %{
    scope: scope
  } do
    Process.put(:owner_lookup, {:ok, :triage})
    Process.put(:activate, {:error, :unavailable})
    status = %{"channel" => scope["channel_id"], "ts" => "101.000001"}

    assert {:completion_later, {:ok, ^status}, {:triage_subscription_unavailable, :unavailable}} =
             TriageThreadSubscription.after_reply(claim(scope), {:ok, status},
               owner_port: OwnerPort,
               store_port: StorePort,
               continuation_context_port: ContinuationContext
             )

    assert_receive {:activate, ^scope, _provenance}
  end

  test "a foreign owner preserves delivered status but never subscribes", %{scope: scope} do
    Process.put(:owner_lookup, {:ok, :legacy})
    result = {:ok, %{"channel" => scope["channel_id"], "ts" => "101.000001"}}

    assert TriageThreadSubscription.after_reply(claim(scope), result,
             owner_port: OwnerPort,
             store_port: StorePort,
             continuation_context_port: ContinuationContext
           ) == result

    refute_receive {:activate, _scope, _provenance}
  end

  test "ordinary human admission requires the exact immutable admission", %{scope: scope} do
    authority = authority(scope)
    route_scope = Map.delete(scope, "agent_id")

    assert TriageThreadSubscription.admission(authority, route_scope,
             store_port: StorePort,
             continuation_context_port: ContinuationContext
           ) ==
             :admit

    Process.put(:status, {:error, :not_found})

    assert TriageThreadSubscription.admission(authority, route_scope,
             store_port: StorePort,
             continuation_context_port: ContinuationContext
           ) ==
             :ignore

    Process.put(:status, {:error, :unavailable})

    assert TriageThreadSubscription.admission(authority, route_scope,
             store_port: StorePort,
             continuation_context_port: ContinuationContext
           ) ==
             {:error, :unavailable}
  end

  test "context must persist before ordinary continuation activates", %{scope: scope} do
    Process.put(:continuation_context, {:error, :unavailable})
    result = {:ok, %{"channel" => scope["channel_id"], "ts" => "101.000001"}}

    assert {:completion_later, ^result, _} =
             TriageThreadSubscription.after_reply(claim(scope), result,
               owner_port: OwnerPort,
               store_port: StorePort,
               continuation_context_port: ContinuationContext
             )

    refute_receive {:activate, _, _}
  end

  defp scope do
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => Ids.new_connect_id(),
      "connect_generation" => ULID.generate(),
      "workspace_id" => "T_TEST",
      "channel_id" => "C_TEST",
      "root_thread_ts" => "100.000001",
      "agent_id" => Ids.new_agent_id(group_id)
    }
  end

  defp claim(scope) do
    %{
      obligation_id: "triage-product-" <> String.duplicate("a", 64),
      payload: %{
        "run_id" => "run-1",
        "target" => %{
          "connect_id" => scope["connect_id"],
          "connect_generation" => scope["connect_generation"],
          "workspace_id" => scope["workspace_id"],
          "channel_id" => scope["channel_id"],
          "thread_ts" => scope["root_thread_ts"]
        },
        "product_identity" => %{
          "project_salix_group_id" => scope["group_id"],
          "salix_agent_id" => scope["agent_id"]
        }
      }
    }
  end

  defp authority(scope) do
    %{
      "tenant_id" => scope["tenant_id"],
      "group_id" => scope["group_id"],
      "connect_id" => scope["connect_id"],
      "connect_generation" => scope["connect_generation"],
      "workspace_id" => scope["workspace_id"],
      "approved_channel_id" => scope["channel_id"],
      "inbound_agent_id" => scope["agent_id"]
    }
  end
end
