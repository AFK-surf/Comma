defmodule SalixAgent.OAuthAuthorizationSettlementTest do
  @moduledoc """
  How a connect-account request (`oauth_authorization`) ends. The verified
  OAuth callback, not a client, ends it as connected: the flow that started it,
  or another that connected the same account (Settings > Plugins). A person
  in the app may only decline. The first ending wins.

  These tests read the stored request: telling the waiting Agent is the last
  step and needs a live session, which is its own concern.
  """

  use SystemsClock.Case, async: false

  alias SalixAgent.CapabilityRequests
  alias SalixStore.Ids

  setup do
    previous_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    case start_supervised(SalixStore.S3.Fake) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> SalixStore.S3.Fake.reset()
    end

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, previous_store) end)

    {:ok, tenant: tenant, group: group, agent: agent}
  end

  defp request!(ctx, oauth, conversation \\ "cnv-1") do
    {:ok, request} =
      CapabilityRequests.create_capability_request(%{
        "source_agent_id" => ctx.agent["agent_id"],
        "source_session_id" => Ids.new_session_id(),
        "tool_call_id" =>
          "call-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
        "request_type" => "oauth_authorization",
        "group_id" => ctx.group,
        "tenant_id" => ctx.tenant,
        "surface_kind" => "conversation",
        "surface_ref" => %{"conversation_id" => conversation, "message_id" => "msg-1"},
        "request_payload" => %{
          "oauth_authorization" =>
            Map.merge(
              %{
                "provider" => "github",
                "alias" => "github",
                "reason" => "An app keeps its code in GitHub.",
                "authorization_url" => "https://github.com/login/oauth/authorize?x=1"
              },
              oauth
            )
        }
      })

    request
  end

  defp stored(ctx, request) do
    {:ok, record} = CapabilityRequests.get(ctx.group, request["request_id"], ctx.tenant)
    record
  end

  test "a finished flow ends the requests for its account, and only those", ctx do
    started = request!(ctx, %{"state" => "flow-1"})
    same_account = request!(ctx, %{"state" => "flow-2"})
    other = request!(ctx, %{"provider" => "google", "alias" => "work", "state" => "flow-3"})

    assert {:ok, [_, _]} =
             CapabilityRequests.complete_oauth_authorization(ctx.group, ctx.tenant, %{
               "state" => "flow-1",
               "provider" => "github",
               "alias" => "github",
               "provider_account_name" => "octocat"
             })

    for request <- [started, same_account] do
      record = stored(ctx, request)
      assert record["status"] == "completed"

      assert record["response_payload"] == %{
               "status" => "connected",
               "provider_account_name" => "octocat"
             }

      assert %{"status" => "completed", "error" => false} = record["result"]
    end

    assert stored(ctx, other)["status"] == "pending"
  end

  test "a person declines; the first ending wins", ctx do
    request = request!(ctx, %{"state" => "flow-4"})

    CapabilityRequests.decline_oauth_authorization(ctx.group, request["request_id"], ctx.tenant)

    declined = stored(ctx, request)
    assert declined["status"] == "completed"
    assert declined["response_payload"] == %{"status" => "declined"}
    assert %{"status" => "failed", "error_class" => "permission_denied"} = declined["result"]

    # A connection made later does not turn the refusal into consent.
    CapabilityRequests.complete_oauth_authorization(ctx.group, ctx.tenant, %{
      "state" => "flow-4",
      "provider" => "github",
      "alias" => "github"
    })

    assert stored(ctx, request)["response_payload"] == %{"status" => "declined"}
  end

  test "a Conversation reads its own requests, every pending one kept, and fails when the store does",
       ctx do
    waiting = request!(ctx, %{"state" => "flow-5"})
    _elsewhere = request!(ctx, %{"state" => "flow-6"}, "cnv-2")
    answered = request!(ctx, %{"state" => "flow-7"})
    CapabilityRequests.decline_oauth_authorization(ctx.group, answered["request_id"], ctx.tenant)

    ids = fn {:ok, records} -> Enum.map(records, & &1["request_id"]) end

    assert ids.(CapabilityRequests.list_conversation(ctx.group, ctx.tenant, "cnv-1")) ==
             [waiting["request_id"], answered["request_id"]]

    # The bound drops finished requests first: a pending card is never pushed out.
    assert ids.(CapabilityRequests.list_conversation(ctx.group, ctx.tenant, "cnv-1", limit: 1)) ==
             [waiting["request_id"]]

    SalixStore.S3.Fake.set_fault(
      {:fail, 503, :get, SalixStore.Keys.ctl_capability_request(ctx.group, waiting["request_id"])}
    )

    assert {:error, _} = CapabilityRequests.list_conversation(ctx.group, ctx.tenant, "cnv-1")
  end

  test "a decline needs a connect-account request", ctx do
    {:ok, location} =
      CapabilityRequests.create_capability_request(%{
        "source_agent_id" => ctx.agent["agent_id"],
        "source_session_id" => Ids.new_session_id(),
        "tool_call_id" => "call-location",
        "request_type" => "location",
        "group_id" => ctx.group,
        "tenant_id" => ctx.tenant,
        "request_payload" => %{"location" => %{"reason" => "Nearby shops"}}
      })

    assert {:error, {:bad_request, _}} =
             CapabilityRequests.decline_oauth_authorization(
               ctx.group,
               location["request_id"],
               ctx.tenant
             )
  end
end
