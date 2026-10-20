defmodule SalixIM.IFCLarkConfirmationTest do
  @moduledoc """
  The person's side of a declassification, on Lark
  (`docs/verification.md` §6.2): only the person the request names can answer
  it, and the answer goes to the durable decision, not to anything in the
  callback. The card that replaces the question comes back as the answer to
  the callback. The callback itself is covered in `SalixIM.LarkProviderTest`.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
  alias SalixIM.IFC.LarkConfirmation

  @group "grp_ifc_lark_card"
  @tenant "tnt_ifc_lark_card"
  @connect "cnx_ifc_lark_card"
  @requester "provider_user|cnx_ifc_lark_card|ou_a"

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
    test "only a press of an approve or deny button of this card is its action" do
      assert LarkConfirmation.action?(press("approve", "ou_a"))
      assert LarkConfirmation.action?(press("deny", "ou_a"))
      # Lark can deliver the value of a button as its JSON string.
      as_string =
        update_in(press("approve", "ou_a"), ["event", "action", "value"], &Jason.encode!/1)

      assert LarkConfirmation.action?(as_string)

      refute LarkConfirmation.action?(press("later", "ou_a"))

      refute LarkConfirmation.action?(
               put_in(press("approve", "ou_a"), ["header", "event_type"], "im.message.receive_v1")
             )
    end
  end

  describe "answering it" do
    test "the person the request names decides, and the card is replaced" do
      Process.put(:ifc_card_request, request())

      assert {:ok, response} =
               LarkConfirmation.apply_action(connect(), press("approve", "ou_a"))

      assert_received {:get, @group, "req_1", @tenant}
      assert_received {:decided, @group, "req_1", %{"approved" => true}, @tenant}

      # The answer to the callback is the settled card.
      assert %{"card" => %{"type" => "raw", "data" => %{"elements" => elements}}} = response
      rendered = Jason.encode!(elements)
      assert rendered =~ "已确认转发"

      # It names the places as people read them, never as atoms.
      refute rendered =~ "scope|"
    end

    test "cancelling is a decision too" do
      Process.put(:ifc_card_request, request())

      assert {:ok, response} = LarkConfirmation.apply_action(connect(), press("deny", "ou_a"))
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

        assert LarkConfirmation.apply_action(connect, press("approve", @user)) == @expected
        refute_received {:decided, _group, _request, _attrs, _tenant}
      end
    end

    test "a second press of an already-settled request changes nothing" do
      Process.put(:ifc_card_request, request())
      Process.put(:ifc_card_settled, true)

      assert {:error, {:ignored, :ifc_declassify_settled}} =
               LarkConfirmation.apply_action(connect(), press("deny", "ou_a"))
    end
  end

  describe "asking" do
    test "the card states the flow, and never the content" do
      rendered = Jason.encode!(LarkConfirmation.card(request(), detail(request())))

      # Both places by name, the Router's one-sentence summary, and what the
      # answer grants.
      assert rendered =~ "私聊"
      assert rendered =~ "项目群"
      assert rendered =~ "把你私聊里的交接清单发到项目群"
      assert rendered =~ "不限定于上面这段内容"

      # The card is for a person: it shows no atom.
      refute rendered =~ "scope|"

      # Each button names the request it answers.
      assert rendered =~ ~s("request_id":"req_1")
    end
  end
end
