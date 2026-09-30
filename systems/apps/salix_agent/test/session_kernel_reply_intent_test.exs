defmodule SalixAgent.SessionKernelReplyIntentTest do
  use ExUnit.Case, async: false
  alias SalixAgent.InternalSession.State
  alias SalixAgent.TestSupport.SessionData
  alias SalixAgent.TestSupport.SessionKernelDriver, as: Driver

  defmodule AccessValue do
    defstruct overrides: %{}, history_key: nil

    def fetch(value, key) do
      if value.history_key do
        Process.put(value.history_key, [key | Process.get(value.history_key, [])])
      end

      case Map.fetch(value.overrides, key) do
        {:ok, {:raise, message}} -> raise message
        {:ok, result} -> {:ok, result}
        :error -> Map.fetch(value, key)
      end
    end
  end

  defp event(type, extra), do: Map.put(extra, "type", type)

  defp outcome(fun) do
    try do
      {:returned, fun.()}
    catch
      kind, reason -> {:raised, kind, Exception.normalize(kind, reason, __STACKTRACE__)}
    end
  end

  defp check(state, ev) do
    outcome(fn ->
      {:done, next} = Driver.step(state, ev)
      next
    end)
  end

  test "establish copies only selected fields and preserves nil false and opaque state" do
    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      visible_reply_intent: %{old: true},
      last_activity_at: "before",
      events: :unvisited,
      messages: [:unvisited],
      last_seq: 1.5
    }

    ev =
      event("visible_reply_intent", %{
        "assistant_message_id" => nil,
        "content" => false,
        "scope" => %{nested: [%{value: 2}]},
        "idempotency_key" => "key",
        "created_at" => false,
        "ignored" => %{{} => %{pure: :data}}
      })

    assert {:returned, next} = check(state, ev)

    assert next.visible_reply_intent === %{
             "assistant_message_id" => nil,
             "content" => false,
             "scope" => %{"nested" => [%{"value" => 2}]},
             "idempotency_key" => "key",
             "created_at" => false
           }

    assert next.last_activity_at === "before"

    assert Map.drop(next, [:visible_reply_intent, :last_activity_at]) ===
             Map.drop(state, [:visible_reply_intent, :last_activity_at])
  end

  test "selected key collisions follow native conversion order" do
    for payload <- [%{:same => 1, "same" => 2}, [%{:nested => %{:same => 1, "same" => 2}}]] do
      assert {:returned, _} =
               check(
                 %State{
                   status: :active,
                   activity_status: :thinking,
                   activity_status_updated_at: 10
                 },
                 event("visible_reply_intent", %{"content" => payload})
               )
    end
  end

  test "selected conversion rejects malformed nested payloads" do
    for payload <- [%{{} => 1}, %AccessValue{}] do
      assert_raise ArgumentError, ~r/^invalid Session data:/, fn ->
        Driver.step(%State{}, event("visible_reply_intent", %{"scope" => payload}))
      end
    end

    assert {:raised, :error, %FunctionClauseError{}} =
             check(%State{}, event("visible_reply_intent", %{"scope" => [1 | :improper]}))
  end

  test "commit and abort retire matching binary keys including empty and non-UTF8" do
    for type <- ["visible_reply_committed", "visible_reply_aborted"],
        key <- ["key", "", <<255>>] do
      state = %State{
        status: :active,
        activity_status: :thinking,
        activity_status_updated_at: 10,
        visible_reply_intent: %{"idempotency_key" => key},
        last_activity_at: {:opaque, 1},
        events: :unvisited,
        last_seq: 1.5
      }

      ev = event(type, %{"idempotency_key" => key, "created_at" => "ignored"})
      assert {:returned, next} = check(state, ev)
      assert next === %{state | visible_reply_intent: nil}
      assert {:returned, ^next} = check(next, ev)
    end
  end

  test "unmatched and nonbinary keys leave every field unchanged" do
    for type <- ["visible_reply_committed", "visible_reply_aborted"],
        key <- [nil, false, 0, :key, [], <<1::1>>, "different"] do
      state = %State{
        status: :active,
        activity_status: :thinking,
        activity_status_updated_at: 10,
        visible_reply_intent: %{"idempotency_key" => key}
      }

      assert {:returned, ^state} = check(state, event(type, %{"idempotency_key" => "key"}))
    end
  end

  test "current key aliases use binary-first nil and false fallback" do
    for type <- ["visible_reply_committed", "visible_reply_aborted"],
        first <- [nil, false] do
      state = %State{
        status: :active,
        activity_status: :thinking,
        activity_status_updated_at: 10,
        visible_reply_intent: %{"idempotency_key" => first, idempotency_key: "key"}
      }

      assert {:returned, next} = check(state, event(type, %{"idempotency_key" => "key"}))
      assert next.visible_reply_intent === nil
    end
  end

  test "retirement preserves absent and nonmatching plain intent data" do
    for current <- [nil, false, %{"idempotency_key" => 1}] do
      state = %State{status: :active, activity_status: :thinking, visible_reply_intent: current}

      assert {:returned, ^state} =
               check(state, event("visible_reply_aborted", %{"idempotency_key" => "key"}))
    end
  end

  test "real State wrapper keeps session filtering and stable active bookkeeping" do
    state = %State{
      status: :active,
      activity_status: :thinking,
      activity_status_updated_at: 10,
      session_id: "intent-session"
    }

    ev =
      event("visible_reply_intent", %{
        "session_id" => "intent-session",
        "idempotency_key" => "key",
        "created_at" => 20
      })

    assert {:returned, inner} = check(state, ev)
    assert SessionData.apply_event(state, ev) === inner

    assert SessionData.apply_event(
             state,
             Map.put(ev, "session_id", "another-session")
           ) === state

    for type <- ["visible_reply_committed", "visible_reply_aborted"] do
      settled = event(type, %{"session_id" => "intent-session", "idempotency_key" => "key"})
      assert {:returned, expected} = check(inner, settled)
      assert SessionData.apply_event(inner, settled) === expected
    end
  end
end
