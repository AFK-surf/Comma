defmodule SalixAgent.IFCDeclassificationSettlementTest do
  @moduledoc """
  The durable half of a declassification confirmation
  (`docs/verification.md` §6.2).

  A Slack card is not a settlement guard: its buttons survive a failed update,
  the same press can be delivered twice, and two people can press opposite
  ones at the same moment. What the person's answer actually means therefore
  has to be enforced where the request is stored — once, and with its own
  clock — before any authority is written.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixAgent.CapabilityRequests
  alias SalixStore.{Ids, Keys, S3}

  @source "scope|cnx1|@U_A"
  @destination "space|cnx1"

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

  defp request!(ctx, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "source_agent_id" => ctx.agent["agent_id"],
          "source_session_id" => Ids.new_session_id(),
          "tool_call_id" =>
            "call-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
          "request_type" => "ifc_declassify",
          "group_id" => ctx.group,
          "tenant_id" => ctx.tenant,
          "request_payload" => %{
            "ifc_declassify" => %{
              "capability" => "ifc_declassify",
              "requester" => "provider_user|cnx1|U_A",
              "source_atoms" => [@source],
              "destination_atoms" => [@destination],
              "source_names" => ["私聊"],
              "destination_names" => ["#team"],
              "summary" => "把交接清单发到 #team"
            }
          }
        },
        overrides
      )

    {:ok, request} = CapabilityRequests.create_capability_request(attrs)
    request
  end

  defp decide(ctx, request, approved?) do
    CapabilityRequests.decide_declassification(
      ctx.group,
      request["request_id"],
      %{"approved" => approved?},
      ctx.tenant
    )
  end

  # These tests are about what a press durably means, so they read the stored
  # request and the receipts rather than the call's return value: telling the
  # waiting Router is the last step and needs a live session, which is its own
  # concern and has its own failure mode.
  defp stored(ctx, request) do
    {:ok, record} = CapabilityRequests.get(ctx.group, request["request_id"], ctx.tenant)
    record
  end

  defp receipts(ctx) do
    {:ok, rows} =
      SalixStore.IFC.receipts(
        ctx.tenant,
        ctx.group,
        ["provider_user|cnx1|U_A"],
        SystemsClock.system_time(:millisecond)
      )

    rows
  end

  describe "settling once" do
    test "an approval writes exactly one receipt", ctx do
      request = request!(ctx)
      decide(ctx, request, true)

      settled = stored(ctx, request)
      assert settled["status"] == "completed"
      assert settled["response_payload"] == %{"approved" => true}

      assert [receipt] = receipts(ctx)
      assert receipt["sources"] == [@source]
      assert receipt["destination"] == [@destination]
    end

    test "the same press delivered twice decides once and writes one receipt", ctx do
      request = request!(ctx)
      decide(ctx, request, true)

      assert {:error, {:conflict, :already_settled}} = decide(ctx, request, true)
      assert length(receipts(ctx)) == 1
    end

    test "a refusal cannot be turned into consent by a later press", ctx do
      request = request!(ctx)
      decide(ctx, request, false)

      assert stored(ctx, request)["response_payload"] == %{"approved" => false}
      assert receipts(ctx) == []

      # The buttons are still live if the card update failed. They decide
      # nothing: the refusal already settled.
      assert {:error, {:conflict, :already_settled}} = decide(ctx, request, true)

      assert receipts(ctx) == []
      assert stored(ctx, request)["response_payload"] == %{"approved" => false}
    end
  end

  describe "its own clock" do
    test "a card answered after the request expired grants nothing", ctx do
      request = request!(ctx, %{"expires_at" => SystemsClock.system_time(:second) - 1})

      decide(ctx, request, true)

      assert receipts(ctx) == []
      assert stored(ctx, request)["status"] == "expired"
      assert stored(ctx, request)["result"]["error_class"] == "capability_request_expired"
    end
  end

  describe "spending it" do
    test "a receipt is gone once it has been used", ctx do
      request = request!(ctx)
      decide(ctx, request, true)
      assert [receipt] = receipts(ctx)

      assert {:ok, true} = SalixStore.IFC.consume_receipt(ctx.tenant, ctx.group, receipt["id"])
      assert receipts(ctx) == []

      # A second effect racing for the same one does not also get it.
      assert {:ok, false} = SalixStore.IFC.consume_receipt(ctx.tenant, ctx.group, receipt["id"])
    end
  end

  defp reconcile(request, result \\ nil) do
    CapabilityRequests.reconcile_capability_request(
      request["source_agent_id"],
      request["source_session_id"],
      request["tool_call_id"],
      result
    )
  end

  describe "deadline reconciliation" do

    test "a completion whose session delivery fails remains replayable", ctx do
      request = request!(ctx, %{"request_type" => "location"})
      # No source session was created: the owner result must survive failed delivery.
      assert {:error, _} =
               CapabilityRequests.share_location(
                 ctx.group,
                 request["request_id"],
                 %{"status" => "success", "location" => %{"latitude" => 1.0, "longitude" => 2.0}},
                 ctx.tenant
               )

      assert {:ok, completed} = reconcile(request)
      assert completed["status"] == "completed"
      assert completed["result"]["status"] == "completed"

      assert {:ok, replay} =
               reconcile(request, %{"status" => "failed", "content" => "late failure"})

      assert replay["result"] == completed["result"]
    end
  end
end
