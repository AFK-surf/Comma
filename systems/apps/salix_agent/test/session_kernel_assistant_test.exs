defmodule SalixAgent.SessionKernelAssistantTest do
  use SystemsClock.Case, async: false
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver
  alias SalixAgent.InternalSession.State

  defp event(extra \\ %{}) do
    Map.merge(
      %{"type" => "assistant", "message_id" => 4, "content" => "done", "created_at" => "now"},
      extra
    )
  end

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp check(state, event) do
    outcome(fn ->
      {:done, next} = Driver.step(state, event)
      next
    end)
  end

  defp private_event(metadata), do: event(%{"do_not_send_to_llm" => metadata})
  defp providers(value), do: private_event(%{"context_provider_states" => value})

  test "assistant appends and updates all six owning fields" do
    initial = %State{
      messages: [%{id: 1, content: "old"}],
      last_seq: 8,
      live_context_bytes: 30,
      next_message_id: 2,
      last_activity_at: "before"
    }

    assert {:returned, next} = check(initial, event())
    assert next.last_seq === 9
    assert next.live_context_bytes === 34
    assert next.next_message_id === 5
    assert next.last_activity_at === "now"
    assert List.last(next.messages).seq === 9
    assert next.input_round_streak === %{"count" => 1}

    written = [
      :messages,
      :last_seq,
      :live_context_bytes,
      :next_message_id,
      :last_activity_at,
      :input_round_streak
    ]

    assert Map.drop(next, written) === Map.drop(initial, written)
  end

  test "legacy migration normalizes integer binary and fallback versions" do
    for {version, expected} <- [
          {7, 7},
          {-2, 0},
          {" +19 \n", 19},
          {"-2", 0},
          {"12x", 0},
          {"", 0},
          {false, 0},
          {<<1::1>>, 0}
        ] do
      assert {:returned, next} =
               check(%State{}, providers(%{runtime_context: %{version: version}}))

      assert List.last(next.messages).do_not_send_to_llm ===
               %{"context_provider_states" => %{"migration_notice" => %{"version" => expected}}}
    end
  end

  test "existing migration key suppresses legacy rewrite even when later discarded" do
    for marker <- [nil, false, %{}, [], %{"version" => 3}] do
      assert {:returned, next} =
               check(
                 %State{},
                 providers(%{
                   "runtime_context" => %{"version" => 8},
                   "migration_notice" => marker
                 })
               )

      normalized = List.last(next.messages).do_not_send_to_llm["context_provider_states"]
      assert normalized["runtime_context"] === %{"version" => 8}
      assert Map.has_key?(normalized, "migration_notice") === (marker === %{"version" => 3})
    end
  end

  test "non-map metadata and provider containers normalize to empty" do
    for value <- [nil, false, [], ["x"], 0, "text"] do
      assert {:returned, next} = check(%State{}, private_event(value))
      refute Map.has_key?(List.last(next.messages), :do_not_send_to_llm)
      assert {:returned, next} = check(%State{}, providers(value))
      refute Map.has_key?(List.last(next.messages), :do_not_send_to_llm)
    end
  end

  test "invalid nested keys fail before a provider can be filtered out" do
    assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
      Driver.step(%State{}, providers(%{"discarded_list" => [%{{} => 1}]}))
    end
  end

  test "provider lists and nested keys reject invalid data" do
    assert {:raised, _, _} = check(%State{}, providers(%{"p" => [1 | :tail]}))

    for value <- [
          %{"p" => %{{} => %{{} => 1}}},
          %{"p" => %{"first" => %{{} => 1}, "second" => [1 | :tail]}}
        ] do
      assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
        Driver.step(%State{}, providers(value))
      end
    end
  end
end
