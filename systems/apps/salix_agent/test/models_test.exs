defmodule SalixAgent.ModelsTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.Models

  test "one catalog model carries each source's own request id" do
    assert {:ok, %{"model" => "gpt-5.5", "protocol" => "responses"}} =
             Models.route("gpt-5.5", "openai")

    assert {:ok, %{"model" => "openai/gpt-5.5"}} = Models.route("gpt-5.5", "openrouter")
    assert {:ok, %{"model" => "gpt-5.5"}} = Models.route("gpt-5.5", "codex")
    assert {:ok, %{"kind" => "subscription"}} = Models.source("codex")
  end

  test "served_by lists only models some given source can reach" do
    served = Models.served_by(["deepseek"])

    assert Enum.any?(served, &(&1["id"] == "deepseek-v4-pro"))
    refute Enum.any?(served, &(&1["vendor"] == "openai"))
    assert Models.served_by([]) == []
  end

  test "every route names a source and a protocol Salix speaks" do
    for model <- Models.list(), {source, route} <- model["routes"] do
      assert {:ok, _} = Models.source(source), "#{model["id"]} routes to unknown #{source}"
      assert route["protocol"] in ~w(anthropic chat_completions responses)
      assert is_binary(route["model"]) and route["model"] != ""
    end
  end

  # The clients read the whole catalog with one schema, where a token limit is a number or left out:
  # one null fails the read and the Model & API page shows nothing.
  test "every token limit is a positive number" do
    for model <- Models.list(), field <- ~w(context_tokens max_tokens) do
      value = model[field]
      assert is_integer(value) and value > 0, "#{model["id"]} #{field} is #{inspect(value)}"
    end
  end
end
