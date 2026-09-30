defmodule SalixIM.ProviderPrincipalRefTest do
  use ExUnit.Case, async: true

  alias SalixIM.ProviderPrincipalRef
  alias SalixStore.Ids

  test "Slack member identity is identical for human and app-authored message transports" do
    group = Ids.new_group_id(Ids.new_tenant_id())

    human = %{
      "source_actor_type" => "provider_user",
      "provider" => "slack",
      "group_id" => group,
      "subject_id" => "U_MEMBER",
      "connect_id" => "slack-1"
    }

    app =
      Map.merge(human, %{
        "source_actor_type" => "provider_system",
        "provider_context" => %{"event_type" => "message", "user_id" => "U_MEMBER"}
      })

    principal = ProviderPrincipalRef.seal_connected(human)
    assert principal["subject_id"] == "U_MEMBER"
    assert ProviderPrincipalRef.seal_connected(app) == principal
    assert ProviderPrincipalRef.seal(app) == principal

    for invalid <- [
          put_in(app, ["provider_context", "event_type"], "member_joined_channel"),
          put_in(app, ["provider_context", "user_id"], "U_OTHER"),
          put_in(app, ["provider_context", "user_id"], ""),
          Map.delete(app, "provider_context"),
          Map.put(app, "subject_id", ""),
          Map.put(app, "connect_id", "")
        ] do
      assert ProviderPrincipalRef.seal_connected(invalid) == nil
    end
  end
end
