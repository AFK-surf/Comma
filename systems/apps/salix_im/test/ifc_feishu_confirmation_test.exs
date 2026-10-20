defmodule SalixIM.IFCFeishuConfirmationTest do
  @moduledoc """
  The human half of declassification, on Feishu
  (`docs/verification.md` §6.2).

  The same properties `SalixIM.IFCSlackConfirmationTest` checks, because they
  are properties of the design and not of Slack: only the person the request
  names can answer it, and answering goes to the durable decision rather than
  to anything in the callback. What differs is the shape of the press and the
  fact that the card's replacement travels back in the callback's own response
  instead of a second API call.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.IFC.FeishuConfirmation

  @group "grp_ifc_feishu_card"
  @tenant "tnt_ifc_feishu_card"
  @connect "cnx_ifc_feishu_card"
  @requester "provider_user|cnx_ifc_feishu_card|ou_a"

  defmodule Capability do
    @moduledoc false

    def get(group_id, request_id, tenant_id) do
      SystemsRuntime.Proc.send(test_pid(), {:get, group_id, request_id, tenant_id})

      case Process.get(:ifc_card_request) do
        nil -> {:error, :not_found}
        request -> {:ok, request}
      end
    end

    def decide_declassification(group_id, request_id, attrs, tenant_id) do
      SystemsRuntime.Proc.send(test_pid(), {:decided, group_id, request_id, attrs, tenant_id})

      case Process.get(:ifc_card_settled) do
        true -> {:error, {:conflict, :already_settled}}
        _open -> {:ok, Process.get(:ifc_card_request)}
      end
    end

    defp test_pid, do: Process.get(:ifc_card_test_pid)
  end

  setup do
    SystemsRuntime.put_env(:salix_im, :capability_request_mod, Capability)
    Process.put(:ifc_card_test_pid, SystemsRuntime.Proc.self())
    on_exit(fn -> SystemsRuntime.delete_env(:salix_im, :capability_request_mod) end)
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
              "source_atoms" => ["scope|#{@connect}|@ou_a"],
              "destination_atoms" => ["scope|#{@connect}|oc_team"],
              "source_names" => ["私聊"],
              "destination_names" => ["项目群"],
              "summary" => "把你私聊里的交接清单发到项目群"
            },
            overrides
          )
      }
    }
  end

  defp connect,
    do: %{"group_id" => @group, "tenant_id" => @tenant, "connect_id" => @connect}

  defp detail(request), do: get_in(request, ["request_payload", "ifc_declassify"])

  defp press(choice, open_id, request_id \\ "req_1") do
    %{
      "schema" => "2.0",
      "header" => %{"event_type" => "card.action.trigger", "event_id" => "evt_1"},
      "event" => %{
        "operator" => %{"open_id" => open_id},
        "action" => %{
          "tag" => "button",
          "value" => %{"ifc_declassify" => choice, "request_id" => request_id}
        }
      }
    }
  end

  describe "recognizing the card" do
  end

  describe "answering it" do
    test "the person the request names decides, and the card is replaced" do
      Process.put(:ifc_card_request, request())

      assert {:ok, response} =
               FeishuConfirmation.apply_action(connect(), press("approve", "ou_a"))

      assert_received {:get, @group, "req_1", @tenant}
      assert_received {:decided, @group, "req_1", %{"approved" => true}, @tenant}

      # The reply *is* the settled card: there is no second API call to lose.
      assert %{"card" => %{"type" => "raw", "data" => %{"elements" => elements}}} = response
      rendered = Jason.encode!(elements)
      assert rendered =~ "已确认转发"

      # And the card still says only where, never what was carried beyond the
      # summary the request already carried.
      refute rendered =~ "scope|"
    end

    test "cancelling is a decision too" do
      Process.put(:ifc_card_request, request())

      assert {:ok, response} = FeishuConfirmation.apply_action(connect(), press("deny", "ou_a"))
      assert_received {:decided, @group, "req_1", %{"approved" => false}, @tenant}
      assert Jason.encode!(response) =~ "已取消"
    end

    for {name, request_overrides, connect_id, user, expected} <- [
          {"anyone else pressing the button", %{}, nil, "ou_b",
           {:error, {:ignored, :ifc_declassify_wrong_user}}},
          {"a card from another workspace's connect", %{}, "cnx_other", "ou_a",
           {:error, {:ignored, :ifc_declassify_wrong_user}}},
          {"a request whose requester is not a provider user", %{"requester" => "system"}, nil,
           "ou_a", {:error, {:ignored, :ifc_declassify_wrong_user}}},
          {"an unknown request", nil, nil, "ou_a", {:error, :not_found}}
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

        assert FeishuConfirmation.apply_action(connect, press("approve", @user)) == @expected
        refute_received {:decided, _group, _request, _attrs, _tenant}
      end
    end

    test "a second press of an already-settled request changes nothing" do
      Process.put(:ifc_card_request, request())
      Process.put(:ifc_card_settled, true)

      assert {:error, {:ignored, :ifc_declassify_settled}} =
               FeishuConfirmation.apply_action(connect(), press("deny", "ou_a"))
    end
  end

  describe "asking" do
    test "the card states the flow, and never the content" do
      rendered = Jason.encode!(FeishuConfirmation.card(request(), detail(request())))

      # Both places by display name, the Router's own one-sentence summary, and
      # what the answer actually grants.
      assert rendered =~ "私聊"
      assert rendered =~ "项目群"
      assert rendered =~ "把你私聊里的交接清单发到项目群"
      assert rendered =~ "不限定于上面这段内容"

      # Never an opaque atom: the card is for a person.
      refute rendered =~ "scope|"

      # And each button carries the request it answers, so a press names one
      # durable row rather than "whatever is pending".
      assert rendered =~ ~s("request_id":"req_1")
    end
  end
end
