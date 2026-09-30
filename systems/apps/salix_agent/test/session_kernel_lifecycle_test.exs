defmodule SalixAgent.SessionKernelLifecycleTest do
  @moduledoc """
  Coverage for the kernel-owned Session lifecycle operations.
  """
  use ExUnit.Case, async: true

  alias SalixAgent.InternalSession.State
  alias SalixVerifiedKernel.Session

  @session "ses1_0000000000000000901"
  @fork "ses1_0000000000000000902"

  defp kernel_normalize(state) do
    {:ok, handle} = Session.lifecycle(Session.open(state), :normalize)
    Session.export(handle)
  end

  defp prepare_write(state), do: Session.lifecycle(Session.open(state), :prepare_write)

  defp base(overrides) do
    struct(Session.export(Session.new("agent", @session)), overrides)
  end

  ## normalize/1

  test "normalize prunes, renumbers and sorts the input queue" do
    state =
      base(%{
        queue_ack_id: 2,
        next_queue_id: 1,
        input_queue: [
          %{"queue_id" => 5, "payload" => %{"source_message_id" => "m5"}},
          %{queue_id: 1, payload: %{"dedupe_key" => "skipped"}},
          %{"queue_id" => 3, "dedupe_key" => "k3"},
          %{"queue_id" => 0},
          %{"queue_id" => "not-an-id"},
          "not a map",
          %{"queue_id" => 4, "payload" => %{"runtime_message_id" => "r4"}}
        ],
        input_dedupe: MapSet.new(["existing", "", nil])
      })

    normalized = kernel_normalize(state)
    assert Enum.map(normalized.input_queue, & &1["queue_id"]) == [3, 4, 5]
    assert normalized.next_queue_id == 6
    assert MapSet.member?(normalized.input_dedupe, "existing")
  end

  test "normalize adds queued dedupe keys to a large ledger" do
    ledger = MapSet.new(Enum.map(1..6_804, &"source-#{&1}"))

    state =
      base(%{
        input_dedupe: ledger,
        input_queue: [
          %{"queue_id" => 1, "dedupe_key" => "source-1"},
          %{"queue_id" => 2, "dedupe_key" => "new-source"}
        ]
      })

    normalized = kernel_normalize(state)
    assert normalized.input_dedupe == MapSet.put(ledger, "new-source")
  end

  test "normalize drops unaddressable archive spans and segment entries" do
    state =
      base(%{
        archive_chunks: [[1, 2, 3, 4, 5], [1, 2, 3], [1, 2, 3, 4, "five"], "junk"],
        segment_catalog: [
          [1, 4, 2, 100],
          [0, 4, 2, 100],
          [4, 1, 2, 100],
          [1, 4, 9, 100],
          [1, 4, 2, 0],
          [1, 4, 2],
          "junk"
        ]
      })

    normalized = kernel_normalize(state)
    assert normalized.archive_chunks == [[1, 2, 3, 4, 5]]
    assert normalized.segment_catalog == [[1, 4, 2, 100]]
  end

  test "normalize keeps only recognizable provider reply obligations" do
    state =
      base(%{
        provider_reply_obligations: %{
          "stale" => %{
            "provider" => "slack",
            "connect_id" => "c1",
            "channel" => "C1",
            "thread_ts" => "1.2"
          },
          "card" => %{
            "provider" => "slack",
            "kind" => "task_card",
            "conversation_id" => "conv"
          },
          "bad" => %{"provider" => "teams"},
          "worse" => "not a map"
        }
      })

    normalized = kernel_normalize(state)
    assert map_size(normalized.provider_reply_obligations) == 2
  end

  test "normalize adopts provider states from the newest assistant carrier" do
    state =
      base(%{
        compacted_through: 1,
        messages: [
          %{
            id: 1,
            role: "assistant",
            do_not_send_to_llm: %{"context_provider_states" => %{"skills" => %{"v" => 1}}}
          },
          %{
            id: 2,
            role: "assistant",
            do_not_send_to_llm: %{
              "context_provider_states" => %{"runtime_context" => %{"version" => "4"}}
            }
          },
          %{id: 3, role: "user", content: "later"}
        ]
      })

    normalized = kernel_normalize(state)
    assert normalized.context_provider_states == %{"migration_notice" => %{"version" => 4}}
  end

  test "normalize keeps the stored context provider states out of the result" do
    normalized = kernel_normalize(base(%{context_provider_states: %{"skills" => %{"v" => 2}}}))
    assert normalized.context_provider_states == %{}
  end

  ## prepare_write/1

  test "prepare_write reports a duplicate legacy seq" do
    state =
      base(%{
        storage_format: 1,
        messages: [%{id: 1, seq: 4}, %{id: 2, seq: 4}],
        next_message_id: 3
      })

    assert {:error, {:legacy_normalization_failed, :duplicate_legacy_seq}} =
             prepare_write(state)
  end

  test "prepare_write reports a missing legacy reference" do
    for state <- [
          base(%{
            storage_format: 1,
            messages: [%{id: 1, seq: 1, result_seq: 99}],
            next_message_id: 2
          }),
          base(%{
            storage_format: 1,
            messages: [%{id: 1, seq: 1}],
            async_result_refs: %{"r" => 42}
          }),
          base(%{
            storage_format: 1,
            messages: [%{id: 1, seq: 1}],
            redactions: [%{"seq" => 77}]
          }),
          base(%{
            storage_format: 1,
            messages: [%{"id" => 1, "seq" => 1, "result_seq" => 55}],
            next_message_id: 2
          })
        ] do
      assert {:error, {:legacy_normalization_failed, {:missing_legacy_reference, _}}} =
               prepare_write(state)
    end
  end

  test "normalize raises an arithmetic error on a text watermark" do
    state = base(%{next_message_id: "7"})

    assert_raise ArithmeticError, fn ->
      Session.lifecycle(Session.open(state), :normalize)
    end
  end

  test "fork from an unsupported legacy format fails" do
    for format <- [0, 1.5, "1"] do
      source = base(%{storage_format: format, messages: [%{id: 1}]})

      assert_raise FunctionClauseError, fn ->
        Session.lifecycle(Session.open(source), :fork, {@fork, %{}})
      end
    end
  end

  test "normalize rejects an improper input queue" do
    state = base(%{input_queue: [%{"queue_id" => 1} | "tail"]})

    assert_raise FunctionClauseError, fn ->
      Session.lifecycle(Session.open(state), :normalize)
    end
  end

  test "a persisted snapshot loads back as the normalized state" do
    state =
      base(%{
        storage_format: 3,
        messages: [%{id: 1, seq: 1, role: "user", content: "hi"}],
        context_provider_states: %{"skills" => %{"v" => 1}},
        next_message_id: 2
      })

    bytes = Session.persist(Session.open(state))
    assert {:ok, handle} = Session.load(bytes)

    assert Session.export(handle) ==
             kernel_normalize(%State{state | context_provider_states: %{}})
  end
end
