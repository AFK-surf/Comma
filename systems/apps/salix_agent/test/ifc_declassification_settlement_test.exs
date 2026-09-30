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

  use ExUnit.Case, async: false

  alias SalixAgent.CapabilityRequests
  alias SalixStore.{Ids, Keys, S3}

  @source "scope|cnx1|@U_A"
  @destination "space|cnx1"

  setup do
    previous_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

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

    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous_store) end)

    {:ok, tenant: tenant, group: group, agent: agent}
  end

  defp request!(ctx, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "source_agent_id" => ctx.agent["agent_id"],
          "source_session_id" => Ids.new_session_id(),
          "tool_call_id" => "call-" <> Integer.to_string(System.unique_integer([:positive])),
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
        System.system_time(:millisecond)
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

    test "a refusal writes nothing at all", ctx do
      request = request!(ctx)
      decide(ctx, request, false)

      assert receipts(ctx) == []
    end
  end

  describe "its own clock" do
    test "a card answered after the request expired grants nothing", ctx do
      request = request!(ctx, %{"expires_at" => System.system_time(:second) - 1})

      decide(ctx, request, true)

      assert receipts(ctx) == []
      assert stored(ctx, request)["status"] == "expired"
      assert stored(ctx, request)["result"]["error_class"] == "capability_request_expired"
    end

    test "a request still inside its window settles normally", ctx do
      request = request!(ctx, %{"expires_at" => System.system_time(:second) + 600})
      decide(ctx, request, true)

      assert stored(ctx, request)["status"] == "completed"
      assert length(receipts(ctx)) == 1
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

  defp rewrite_request(request, changes) do
    key = Keys.ctl_capability_request(request["group_id"], request["request_id"])
    {:ok, %{body: body, etag: etag}} = S3.get(key)
    {:ok, _} = S3.put(key, Jason.encode!(Map.merge(Jason.decode!(body), changes)), if_match: etag)
  end

  describe "deadline reconciliation" do
    test "creation replay preserves the first deadline and creation timestamp", ctx do
      request = request!(ctx, %{"request_type" => "location"})
      assert is_integer(request["expires_at"])
      assert request["expires_at"] <= System.system_time(:second) + 120

      {:ok, replay} =
        CapabilityRequests.create_capability_request(
          request
          |> Map.put("expires_at", request["expires_at"] + 600)
          |> Map.put("created_at", request["created_at"] + 600)
        )

      assert replay["expires_at"] == request["expires_at"]
      assert replay["created_at"] == request["created_at"]
    end

    test "an expired cancellation settles the durable request instead of hiding it", ctx do
      request =
        request!(ctx, %{
          "request_type" => "location",
          "expires_at" => System.system_time(:second) - 1
        })

      assert {:ok, expired} =
               CapabilityRequests.cancel_capability_request(
                 request["source_agent_id"],
                 request["source_session_id"],
                 request["tool_call_id"],
                 "cancel"
               )

      assert expired["status"] == "expired"
      assert {:ok, replay} = reconcile(request, %{"status" => "completed", "content" => "late"})
      assert replay["result"] == expired["result"]
    end

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

    test "expiry wins against an already read completion CAS", ctx do
      request = request!(ctx, %{"request_type" => "location"})
      key = Keys.ctl_capability_request(ctx.group, request["request_id"])
      S3.Fake.set_fault({:pause, :put, key})

      task =
        Task.async(fn -> reconcile(request, %{"status" => "completed", "content" => "late"}) end)

      assert_eventually(fn -> S3.Fake.paused?() end)
      rewrite_request(request, %{"expires_at" => System.system_time(:second) - 1})
      assert {:ok, expired} = reconcile(request)
      assert expired["status"] == "expired"
      S3.Fake.release_pause()
      assert {:ok, loser} = Task.await(task)
      assert loser["result"] == expired["result"]
    end

    test "receipt failure produces a stable failure result and never reports approval", ctx do
      request = request!(ctx, %{"request_payload" => %{"ifc_declassify" => %{}}})
      decide(ctx, request, true)
      assert {:ok, failed} = reconcile(request)
      assert failed["response_payload"]["approved"] == true
      assert failed["result"]["status"] == "failed"
      assert receipts(ctx) == []
      assert {:error, {:conflict, :already_settled}} = decide(ctx, request, true)
      assert {:ok, replay} = reconcile(request)
      assert replay["result"] == failed["result"]
    end

    test "receipt decision awaiting its result converges after its deadline without granting again",
         ctx do
      request = request!(ctx)

      rewrite_request(request, %{
        "status" => "completed",
        "response_payload" => %{"approved" => true},
        "settlement_deadline_ms" => System.system_time(:millisecond) + 30_000
      })

      assert {:ok, waiting} = reconcile(request)
      refute is_map(waiting["result"])

      rewrite_request(request, %{"settlement_deadline_ms" => System.system_time(:millisecond) - 1})

      assert {:ok, failed} = reconcile(request)
      assert failed["result"]["status"] == "failed"
      assert {:error, {:conflict, :already_settled}} = decide(ctx, request, true)
      assert receipts(ctx) == []
      assert {:ok, replay} = reconcile(request, %{"status" => "completed", "content" => "late"})
      assert replay["result"] == failed["result"]
    end
  end

  defp assert_eventually(predicate, attempts \\ 100)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
