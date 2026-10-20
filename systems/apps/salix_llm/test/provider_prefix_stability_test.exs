defmodule SalixLlm.ProviderPrefixStabilityTest do
  @moduledoc """
  A provider caches a request prefix. Each projection decides a message from the
  earlier messages only, so a later message keeps the projection of the earlier
  history as a prefix.
  """
  use SystemsClock.Case, async: true

  alias SalixLlm.{Convert, ConvertOpenAI}

  defp call(id, name), do: %{"id" => id, "name" => name, "args" => %{"path" => "/x"}}

  test "an atom role projects like a text role" do
    atom = [%{role: :user, content: "hello"}, %{role: :assistant, content: "hi"}]
    text = [%{role: "user", content: "hello"}, %{role: "assistant", content: "hi"}]

    assert Convert.to_anthropic(atom) == Convert.to_anthropic(text)
    assert ConvertOpenAI.to_chat(atom) == ConvertOpenAI.to_chat(text)
  end

  test "a later unsafe call keeps an earlier Responses output native" do
    history = [
      %{role: "user", content: "read it"},
      %{role: "assistant", content: "", tool_calls: [call("c1", "call")]},
      %{role: "tool", tool_call_id: "c1", content: "done"}
    ]

    later = [%{role: "assistant", content: "", tool_calls: [call("c1", "fs.read_file")]}]

    earlier = ConvertOpenAI.to_responses(history)
    extended = ConvertOpenAI.to_responses(history ++ later)

    assert List.starts_with?(extended, earlier)
    assert Enum.any?(earlier, &(&1["type"] == "function_call_output" and &1["call_id"] == "c1"))
  end

  test "a later call id does not rename an earlier Chat call" do
    history = [
      %{role: "user", content: "read twice"},
      %{role: "assistant", content: "", tool_calls: [call("c", "call")]},
      %{role: "tool", tool_call_id: "c", content: "first"},
      %{role: "assistant", content: "", tool_calls: [call("c", "call")]},
      %{role: "tool", tool_call_id: "c", content: "second"}
    ]

    later = [
      %{role: "assistant", content: "", tool_calls: [call("c__2", "call")]},
      %{role: "tool", tool_call_id: "c__2", content: "third"}
    ]

    earlier = ConvertOpenAI.to_chat(history)
    extended = ConvertOpenAI.to_chat(history ++ later)

    assert List.starts_with?(extended, earlier)

    ids =
      for %{"role" => "assistant", "tool_calls" => calls} <- extended,
          call <- calls,
          do: call["id"]

    assert ids == Enum.uniq(ids)
  end
end
