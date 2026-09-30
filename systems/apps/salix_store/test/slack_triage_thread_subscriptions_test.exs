defmodule SalixStore.SlackTriageThreadSubscriptionsTest do
  use ExUnit.Case, async: false

  alias SalixStore.{Ids, Repo, SlackTriageThreadSubscriptions, ULID}

  setup do
    Repo.query!("TRUNCATE slack_triage_thread_subscriptions")
    :ok
  end

  test "provider-confirmed activation is exact, immutable, and idempotent" do
    scope = scope()
    first = provenance()

    assert {:ok, :created} = SlackTriageThreadSubscriptions.activate(scope, first)
    assert {:ok, :active} = SlackTriageThreadSubscriptions.status(scope)
    assert {:ok, :existing} = SlackTriageThreadSubscriptions.activate(scope, first)

    # A later provider-confirmed reply proves the same permanent admission;
    # it does not create a revision or overwrite first activation provenance.
    assert {:ok, :existing} =
             SlackTriageThreadSubscriptions.activate(scope, provenance("b"))

    first_obligation_id = first["obligation_id"]
    first_provider_message_ref = first["provider_message_ref"]

    assert %{rows: [[^first_obligation_id, nil, ^first_provider_message_ref]]} =
             Repo.query!("""
             SELECT activated_by_obligation_id, activated_by_message_id,
                    activated_by_provider_message_ref
             FROM slack_triage_thread_subscriptions
             """)

    assert Repo.aggregate("slack_triage_thread_subscriptions", :count) == 1
  end

  test "provider-owned canonical connect ids activate continuation admission" do
    scope = Map.put(scope(), "connect_id", "slack-i7nUs8h_3S6g")

    assert {:ok, :created} =
             SlackTriageThreadSubscriptions.activate(scope, provenance())

    assert {:ok, :active} = SlackTriageThreadSubscriptions.status(scope)
  end

  test "generation, channel, thread, and agent are independent fences" do
    scope = scope()

    assert {:ok, _subscription} =
             SlackTriageThreadSubscriptions.activate(scope, provenance())

    for changed <- [
          Map.put(scope, "connect_generation", ULID.generate()),
          Map.put(scope, "channel_id", "C_OTHER"),
          Map.put(scope, "root_thread_ts", "101.000001"),
          Map.put(scope, "agent_id", Ids.new_agent_id(scope["group_id"]))
        ] do
      assert {:error, :not_found} = SlackTriageThreadSubscriptions.status(changed)
    end
  end

  test "malformed identity and non-provider provenance fail closed" do
    scope = scope()

    assert {:error, :invalid} =
             SlackTriageThreadSubscriptions.activate(
               Map.put(scope, "connect_generation", "not-a-generation"),
               provenance()
             )

    assert {:error, :invalid} =
             SlackTriageThreadSubscriptions.activate(
               scope,
               Map.put(provenance(), "obligation_id", "queued-only")
             )

    assert {:error, :invalid} =
             SlackTriageThreadSubscriptions.activate(
               scope,
               provenance() |> Map.put("message_id", Ids.new_message_id())
             )

    assert {:error, :invalid} =
             SlackTriageThreadSubscriptions.activate(
               scope,
               Map.delete(provenance(), "provider_message_ref")
             )
  end

  test "legacy Conversation provenance remains readable during the additive rollout" do
    scope = scope()

    assert {:ok, :created} =
             SlackTriageThreadSubscriptions.activate(scope, %{
               "obligation_id" => "triage-product-" <> String.duplicate("c", 64),
               "message_id" => Ids.new_message_id()
             })

    assert {:ok, :active} = SlackTriageThreadSubscriptions.status(scope)
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

  defp provenance(digest_char \\ "a") do
    %{
      "obligation_id" => "triage-product-" <> String.duplicate(digest_char, 64),
      "provider_message_ref" => "slack:101.000001"
    }
  end
end
