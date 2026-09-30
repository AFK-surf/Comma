defmodule SalixIM.IFCSlackConfirmationTest do
  @moduledoc """
  The human half of declassification
  (`docs/verification.md` §6.2).

  What matters here is not that a card renders, but that only the person the
  request names can answer it, and that answering it goes to the durable
  decision rather than to anything in the interaction payload.
  """

  use ExUnit.Case, async: false

  alias SalixIM.IFC.SlackConfirmation

  @group "grp_ifc_card"
  @tenant "tnt_ifc_card"
  @connect "cnx_ifc_card"
  @requester "provider_user|cnx_ifc_card|U_A"

  defmodule Capability do
    @moduledoc false

    def get(group_id, request_id, tenant_id) do
      send(test_pid(), {:get, group_id, request_id, tenant_id})

      case Process.get(:ifc_card_request) do
        nil -> {:error, :not_found}
        request -> {:ok, request}
      end
    end

    def decide_declassification(group_id, request_id, attrs, tenant_id) do
      send(test_pid(), {:decided, group_id, request_id, attrs, tenant_id})
      {:ok, Process.get(:ifc_card_request)}
    end

    defp test_pid, do: Process.get(:ifc_card_test_pid)
  end

  setup do
    Application.put_env(:salix_im, :capability_request_mod, Capability)
    Process.put(:ifc_card_test_pid, self())
    on_exit(fn -> Application.delete_env(:salix_im, :capability_request_mod) end)
    :ok
  end

  defp request(overrides \\ %{}) do
    %{
      "request_id" => "req_1",
      "group_id" => @group,
      "tenant_id" => @tenant,
      "request_type" => "ifc_declassify",
      "status" => "pending",
      "request_payload" => %{
        "ifc_declassify" =>
          Map.merge(
            %{
              "capability" => "ifc_declassify",
              "requester" => @requester,
              "source_atoms" => ["scope|cnx_ifc_card|@U_A"],
              "destination_atoms" => ["scope|cnx_ifc_card|C_TEAM"],
              "source_names" => ["私聊"],
              "destination_names" => ["#team"],
              "summary" => "把你私聊里的交接清单发到 #team"
            },
            overrides
          )
      }
    }
  end

  defp connect,
    do: %{"group_id" => @group, "tenant_id" => @tenant, "connect_id" => @connect}

  defp payload(action_id, user_id, value \\ "req_1") do
    %{
      "actions" => [%{"action_id" => action_id, "value" => value}],
      "user" => %{"id" => user_id},
      "channel" => %{"id" => "D1"},
      "message" => %{"ts" => "1.1"}
    }
  end

  describe "recognizing the card" do
    test "only its own two actions" do
      assert SlackConfirmation.action?(payload("ifc_declassify:approve", "U_A"))
      assert SlackConfirmation.action?(payload("ifc_declassify:deny", "U_A"))
      refute SlackConfirmation.action?(payload("triage_checkbox", "U_A"))
      refute SlackConfirmation.action?(%{"actions" => []})
      refute SlackConfirmation.action?(%{})
    end
  end

  describe "answering it" do
    test "the person the request names decides" do
      Process.put(:ifc_card_request, request())

      assert {:ok, :accepted} =
               SlackConfirmation.apply_action(connect(), payload("ifc_declassify:approve", "U_A"))

      assert_received {:get, @group, "req_1", @tenant}
      assert_received {:decided, @group, "req_1", %{"approved" => true}, @tenant}
    end

    test "cancelling is a decision too, and writes no receipt" do
      Process.put(:ifc_card_request, request())

      assert {:ok, :accepted} =
               SlackConfirmation.apply_action(connect(), payload("ifc_declassify:deny", "U_A"))

      assert_received {:decided, @group, "req_1", %{"approved" => false}, @tenant}
    end

    for {name, request_overrides, connect_id, user, expected} <- [
          {"anyone else pressing the button", %{}, nil, "U_B",
           {:error, {:ignored, :ifc_declassify_wrong_user}}},
          {"a card from another workspace's connect", %{}, "cnx_other", "U_A",
           {:error, {:ignored, :ifc_declassify_wrong_user}}},
          {"a request whose requester is not a provider user", %{"requester" => "system"}, nil,
           "U_A", {:error, {:ignored, :ifc_declassify_wrong_user}}},
          {"an unknown request", nil, nil, "U_A", {:error, :not_found}}
        ] do
      @request_overrides request_overrides
      @connect_id connect_id
      @user user
      @expected expected
      test "#{name} decides nothing" do
        if @request_overrides,
          do: Process.put(:ifc_card_request, request(@request_overrides)),
          else: Process.delete(:ifc_card_request)

        connect =
          if @connect_id, do: Map.put(connect(), "connect_id", @connect_id), else: connect()

        assert SlackConfirmation.apply_action(connect, payload("ifc_declassify:approve", @user)) ==
                 @expected

        refute_received {:decided, _group, _request, _attrs, _tenant}
      end
    end

    test "a malformed payload is ignored, not retried" do
      assert {:error, {:ignored, :invalid_interaction_payload}} =
               SlackConfirmation.apply_action(connect(), %{})

      assert {:error, {:ignored, :invalid_interaction_payload}} =
               SlackConfirmation.apply_action(
                 connect(),
                 payload("ifc_declassify:approve", "U_A", "")
               )
    end
  end

  describe "asking" do
    test "an unreachable connect never fails the request that raised it" do
      assert :ok = SlackConfirmation.post(request())
    end
  end
end
