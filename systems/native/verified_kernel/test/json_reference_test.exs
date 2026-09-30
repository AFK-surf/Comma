Code.require_file("support/activation_fixture.exs", __DIR__)

defmodule SalixVerifiedKernel.JsonReferenceTest do
  use ExUnit.Case, async: true
  alias SalixVerifiedKernel.Session
  alias SalixVerifiedKernel.Test.ActivationFixture, as: Fixture

  test "JSON reference pruning preserves grammar, Unicode, and first duplicate key semantics" do
    ref = Fixture.ref(1)
    other = Fixture.ref(2)

    cases = [
      {~s({"result_ref":"#{ref}"}), [ref]},
      {" \n\t[ {\"nested\":{\"result_ref\":\"#{ref}\"}}, null, true, false, -12.5e+2 ]\r", [ref]},
      {~s({"result_\\u0072ef":"#{ref}","text":"你好😀"}), [ref]},
      {~s({"result_ref":"#{ref}","text":"\\uD83D\\uDE00\\n\\t\\r\\b\\f\\/\\\\\\\""}), [ref]},
      {~s({"result_ref":"#{ref}","result_ref":"#{other}"}), [ref]},
      {~s({"result_ref":null,"result_ref":"#{ref}"}), []},
      {~s({"result_ref":null,"nested":{"result_ref":"#{other}"}}), [other]},
      {~s({"result_ref":"#{ref}","n":01}), []},
      {~s({"result_ref":"#{ref}","n":1.}), []},
      {~s({"result_ref":"#{ref}","n":+1}), []},
      {~s({"result_ref":"#{ref}","n":1e}), []},
      {~s({"result_ref":"#{ref}","n":1e9999}), []},
      {~s({"result_ref":"#{ref}",}), []},
      {~s([{"result_ref":"#{ref}"},]), []},
      {~s({"result_ref":"#{ref}"} trailing), []},
      {~s({"result_ref":"#{ref}"}{"x":1}), []},
      {~s({"result_ref":"#{ref}","text":"\\uD800"}), []},
      {~s({"result_ref":"#{ref}","text":"\\uDC00"}), []},
      {~s({"result_ref":"#{ref}","text":"\\x20"}), []},
      {~s({"result_ref":"#{ref}","text":") <> <<0>> <> ~s("}), []},
      {~s({"result_ref":"#{ref}","text":") <> <<255>> <> ~s("}), []},
      {~s({"result_ref":"#{ref}), []}
    ]

    initial = Fixture.build("agent", "session", messages: 1, refs: 2, padding: 0)
    snapshot = Session.export(initial)
    [message] = snapshot.messages

    for {content, expected} <- cases do
      session = Session.open(%{snapshot | messages: [%{message | content: content}]})
      next = Fixture.apply_events(session, [%{"type" => "queue_ack", "queue_ack_id" => 1}])

      assert Map.keys(Session.get(next, :async_result_refs)) |> Enum.sort() == Enum.sort(expected),
             "unexpected reference retention for #{inspect(content)}"
    end
  end
end
