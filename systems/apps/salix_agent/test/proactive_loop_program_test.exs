defmodule SalixAgent.ProactiveLoopProgramTest do
  use ExUnit.Case, async: false
  alias SalixAgent.{Loops.Host, SpinfoamFixture}

  @source Path.expand(
            "../../../../resources/salix-system-files/skills/proactive/scripts/watch.c",
            __DIR__
          )
  @moduletag :spinfoam
  @moduletag skip:
               if(SpinfoamFixture.available?(), do: false, else: "spinfoam binary unavailable")

  setup_all do
    case Host.start_link(reconciler: nil) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    %{elf: SpinfoamFixture.compile!(File.read!(@source))}
  end

  test "one compiled program reads exact mail, PR and internal Task without provider-specific tools",
       %{elf: elf} do
    for {tool, arguments, value} <- [
          {"composio.execute", %{"tool_slug" => "mail-read", "arguments" => %{}},
           %{"successful" => true, "data" => %{"body" => "deadline"}}},
          {"composio.execute", %{"tool_slug" => "pr-read", "arguments" => %{}},
           %{"successful" => true, "data" => %{"merged" => true}}},
          {"im_api.internal.read_conversation", %{}, %{"status" => "ready_for_review"}}
        ] do
      calls = run(elf, tool, arguments, value, "notify")
      {_name, read} = hd(calls)
      assert get_in(read, ["arguments", "id"]) == "exact-source" or read["id"] == "exact-source"
      assert {"decide", decision} = Enum.find(calls, &(elem(&1, 0) == "decide"))
      assert decision["state"]["source"] == value
      assert decision["state"]["context"] == %{"messages" => ["Owner wants an update"]}
      assert {"agent.notify", notification} = Enum.find(calls, &(elem(&1, 0) == "agent.notify"))
      assert notification["dedup_key"] == "event-1"
      assert Jason.decode!(notification["content"])["source_ref"] == "source://exact"

      assert List.last(calls) ==
               {"loop.ack",
                %{
                  "event_id" => "event-1",
                  "topic" => "source",
                  "payload" => %{"id" => "exact-source"}
                }}
    end
  end

  test "oversized evidence retains an executable exact source recipe", %{elf: elf} do
    calls =
      run(
        elf,
        "composio.execute",
        %{"tool_slug" => "mail-read", "connected_account_id" => "owner", "arguments" => %{}},
        %{"body" => String.duplicate("x", 9000)},
        "notify"
      )

    {"agent.notify", notification} = Enum.find(calls, &(elem(&1, 0) == "agent.notify"))
    content = Jason.decode!(notification["content"])
    assert byte_size(notification["content"]) < 7800
    assert get_in(content, ["source_read", "arguments", "arguments", "id"]) == "exact-source"
    assert get_in(content, ["source_read", "arguments", "connected_account_id"]) == "owner"
    assert Enum.any?(calls, &(elem(&1, 0) == "loop.ack"))
  end

  test "complete confident quiet checkpoints and acknowledges without notification", %{elf: elf} do
    calls = run(elf, "composio.execute", %{}, %{"successful" => true, "data" => %{}}, "quiet")
    refute Enum.any?(calls, &(elem(&1, 0) == "agent.notify"))
    assert Enum.any?(calls, &(elem(&1, 0) == "loop.ack"))
  end

  test "Home timer passes selected Routine items and freshness to the Router", %{elf: elf} do
    routine = %{
      "state" => "stale",
      "snapshot" => %{"cards" => [%{"id" => "github-review"}]},
      "lastError" => "source_collection_failed"
    }

    calls =
      run(elf, "im_api.internal.read_conversation", %{"limit" => 12}, %{}, "notify", "queued",
        poll: %{},
        related: %{"tool" => "recommendation.read", "arguments" => %{}},
        related_result: routine
      )

    {"agent.notify", notification} = Enum.find(calls, &(elem(&1, 0) == "agent.notify"))
    evidence = Jason.decode!(notification["content"])
    assert evidence["source"]["related"] == routine
    assert evidence["related_read"] == %{"tool" => "recommendation.read", "arguments" => %{}}
    assert evidence["source_read"]["tool"] == "im_api.internal.read_conversation"
  end

  test "related thread read uses the returned identity and keeps its exact recipe", %{elf: elf} do
    related = %{
      "tool" => "composio.execute",
      "arguments" => %{"tool_slug" => "thread-read", "arguments" => %{}},
      "event_argument" => "thread_id",
      "event_field" => "data.threadId"
    }

    calls =
      run(
        elf,
        "composio.execute",
        %{"arguments" => %{}},
        %{"data" => %{"threadId" => "returned-thread"}},
        "notify",
        "queued",
        related: related
      )

    assert {"composio.execute",
            %{"tool_slug" => "thread-read", "arguments" => %{"thread_id" => "returned-thread"}}} in calls

    {"agent.notify", notification} = Enum.find(calls, &(elem(&1, 0) == "agent.notify"))
    evidence = Jason.decode!(notification["content"])

    assert get_in(evidence, ["related_read", "arguments", "arguments", "thread_id"]) ==
             "returned-thread"

    assert get_in(evidence, ["source", "related", "messages"]) == ["Fresh reply"]
  end

  test "provider error wakes Router without treating missing evidence as quiet", %{elf: elf} do
    calls =
      run(
        elf,
        "composio.execute",
        %{},
        %{"successful" => false, "error" => "unavailable"},
        "quiet"
      )

    refute Enum.any?(calls, &(elem(&1, 0) == "decide"))
    assert Enum.any?(calls, &(elem(&1, 0) == "agent.notify"))
  end

  test "low confidence quiet still asks the Router", %{elf: elf} do
    calls = run(elf, "composio.execute", %{}, %{}, "quiet", "queued", confidence: 6000)
    assert Enum.any?(calls, &(elem(&1, 0) == "agent.notify"))
  end

  test "decision failure wakes Router and an unsuccessful wake never ACKs", %{elf: elf} do
    calls = run(elf, "composio.execute", %{}, %{"successful" => true}, "error", "failed")
    assert Enum.count(calls, &(elem(&1, 0) == "agent.notify")) == 2
    refute Enum.any?(calls, &(elem(&1, 0) == "loop.ack"))
  end

  test "failed checkpoint cannot discard an accepted event", %{elf: elf} do
    calls =
      run(elf, "composio.execute", %{}, %{"successful" => true}, "notify", "queued",
        save: "failed"
      )

    assert Enum.any?(calls, &(elem(&1, 0) == "agent.notify"))
    refute Enum.any?(calls, &(elem(&1, 0) == "loop.ack"))
  end

  test "missing context and truncated source cannot settle as quiet", %{elf: elf} do
    for options <- [[context: %{"error" => "unavailable"}], [source: %{"truncated" => true}]] do
      calls =
        run(
          elf,
          "composio.execute",
          %{},
          Keyword.get(options, :source, %{}),
          "quiet",
          "queued",
          options
        )

      refute Enum.any?(calls, &(elem(&1, 0) == "decide"))
      assert Enum.any?(calls, &(elem(&1, 0) == "agent.notify"))
    end
  end

  test "poll resumes its saved identity and observation across guest replacement", %{elf: elf} do
    pending = %{"event_id" => "poll:7", "topic" => "poll", "payload" => %{}}

    checkpoint = %{
      "poll_sequence" => 7,
      "pending_poll" => pending,
      "observation" => %{"old" => true}
    }

    calls =
      run(elf, "composio.execute", %{}, %{"new" => true}, "notify", "duplicate", poll: checkpoint)

    {"agent.notify", notification} = Enum.find(calls, &(elem(&1, 0) == "agent.notify"))
    assert notification["dedup_key"] == "poll:7"
    {"decide", decision} = Enum.find(calls, &(elem(&1, 0) == "decide"))
    assert decision["state"]["previous"] == %{"old" => true}

    assert List.last(calls) ==
             {"loop.state.put",
              %{
                "state" => %{
                  "poll_sequence" => 7,
                  "pending_poll" => nil,
                  "observation" => %{"new" => true}
                }
              }}

    refute Enum.any?(calls, &(elem(&1, 0) == "loop.ack"))
  end

  defp run(elf, tool, arguments, source, choice, wake \\ "queued", options \\ []) do
    config = %{
      "source" => %{
        "tool" => tool,
        "arguments" => arguments,
        "event_argument" => "id",
        "event_field" => "id"
      },
      "context" => %{
        "tool" => "im_api.internal.read_conversation",
        "arguments" => %{"limit" => 12}
      },
      "intent" => "Tell me when action is needed",
      "source_ref" => "source://exact"
    }

    config = if options[:related], do: Map.put(config, "related", options[:related]), else: config

    config =
      if checkpoint = options[:poll] do
        config
        |> Map.put("state", checkpoint)
        |> Map.put("poll_interval_ms", 300_000)
        |> Map.put("source", %{"tool" => tool, "arguments" => arguments})
      else
        config
      end

    capabilities =
      Enum.map(
        Enum.uniq([
          tool,
          "im_api.internal.read_conversation",
          "decide",
          "agent.notify",
          "loop.state.put",
          "loop.ack",
          get_in(options[:related] || %{}, ["tool"])
        ])
        |> Enum.reject(&is_nil/1),
        &%{"name" => &1, "arguments" => %{}}
      )

    {:ok, id} =
      Host.object_load(
        %{kind: :script, owner: self(), agent_id: "test"},
        elf,
        config,
        capabilities
      )

    try do
      :ok = Host.object_start(id)

      unless options[:poll],
        do: Host.event_deliver(id, "event-1", "source", %{"id" => "exact-source"})

      collect(id, tool, source, choice, wake, options, [])
    after
      Host.object_unload(id)
    end
  end

  defp collect(id, tool, source, choice, wake, options, calls) do
    receive do
      {:script_host_call, ^id, rpc, name, args} ->
        result =
          case {name, args} do
            {"im_api.internal.read_conversation", %{"limit" => 12}} ->
              envelope(Keyword.get(options, :context, %{"messages" => ["Owner wants an update"]}))

            {"composio.execute", %{"tool_slug" => "thread-read"}} ->
              envelope(%{"messages" => ["Fresh reply"]})

            {"recommendation.read", _} ->
              envelope(Keyword.fetch!(options, :related_result))

            {^tool, _} ->
              envelope(source)

            {"decide", _} ->
              envelope(
                if(choice == "error",
                  do: %{"error" => "unavailable"},
                  else: %{
                    "answers" => %{
                      "attention" => %{
                        "choice" => choice,
                        "confidence_bp" => Keyword.get(options, :confidence, 9500)
                      }
                    }
                  }
                )
              )

            {"agent.notify", _} ->
              %{"status" => wake}

            {"loop.state.put", _} ->
              %{"status" => Keyword.get(options, :save, "stored")}

            {"loop.ack", _} ->
              %{"status" => "acked"}
          end

        Host.host_reply(rpc, {:ok, result})
        calls = calls ++ [{name, args}]

        if name == "loop.ack" or
             ((name == "loop.state.put" and options[:poll]) &&
                is_nil(args["state"]["pending_poll"])),
           do: calls,
           else: collect(id, tool, source, choice, wake, options, calls)

      {:script_terminal, ^id, _status} ->
        calls
    after
      10_000 -> flunk("program did not settle: #{inspect(calls)}")
    end
  end

  defp envelope(value), do: %{"error" => false, "content" => Jason.encode!(value)}
end
