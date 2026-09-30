defmodule SalixAgent.EventArchiveCompletenessTest do
  @moduledoc """
  The completeness contract: nothing the loop sends or receives escapes the
  archive, and anything that does escape consumes its `seq` on the way out — so
  it is reportable whenever a later item lands on the same run to bound the
  hole. Consuming the seq is necessary, not sufficient: see
  `SalixAnalytics.EventArchive.Completeness` for what a tail loss looks like
  from a reader's side, which is "nothing".

  These are the tests for the holes found after the first implementation —
  provider traffic outside `Round` (compaction especially), streamed private
  reasoning, and async tool settlement. Each was a silent omission, and a
  silent omission is the one failure the design cannot tolerate.
  """

  use ExUnit.Case, async: false

  alias SalixAgent.EventArchive
  alias SalixAgent.EventArchive.{Accumulator, Emit}

  defmodule Recorder do
    @moduledoc false
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(fact) do
      send(Application.get_env(:salix_agent, :archive_test_pid), {:archived, fact})
      :ok
    end
  end

  defmodule RecordingMetering do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(fact) do
      send(
        Application.get_env(:salix_agent, :archive_test_pid),
        {:metered, :before_llm_call, fact}
      )

      :ok
    end

    @impl true
    def after_llm_call(_fact), do: :ok
  end

  defmodule ScriptedProvider do
    @moduledoc false

    def complete(_messages, _tools), do: {:final, "sync answer"}
    def complete(_messages, _tools, _opts), do: {:final, "sync answer"}

    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    def complete_stream(_messages, _tools, on_delta, opts) do
      on_delta.("Hello ")
      on_delta.("world")

      if reasoning = opts[:on_reasoning_delta] do
        reasoning.(%SalixAgent.LLM.ReasoningDelta{
          visibility: :public_summary,
          text: "I will greet them"
        })

        reasoning.(%SalixAgent.LLM.ReasoningDelta{
          visibility: :private_reasoning,
          text: "SECRET CHAIN OF THOUGHT"
        })
      end

      {:final, "Hello world"}
    end

    def compact_context(_messages, _tools, _opts),
      do: {:ok, [%{"type" => "summary", "text" => "compacted"}], %{provider: "test"}}
  end

  setup do
    previous_mod = Application.get_env(:salix_agent, :event_archive_mod)
    previous_llm = Application.get_env(:salix_agent, :llm)

    Application.put_env(:salix_agent, :event_archive_mod, Recorder)
    Application.put_env(:salix_agent, :archive_test_pid, self())
    Application.put_env(:salix_agent, :llm, ScriptedProvider)
    Accumulator.create_table()

    on_exit(fn ->
      restore(:event_archive_mod, previous_mod)
      restore(:llm, previous_llm)
      Application.delete_env(:salix_agent, :archive_test_pid)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore(key, value), do: Application.put_env(:salix_agent, key, value)

  defp llm_opts do
    [
      metering: false,
      billing_context: %{"tenant_id" => "tnt", "agent_id" => "agt", "session_id" => "ses"}
    ]
  end

  # Already in receive order: request first, then response.
  defp collect do
    receive do
      {:archived, fact} -> [fact | collect()]
    after
      0 -> []
    end
  end

  describe "every provider call site is archived" do
    # The first implementation instrumented Round's call site only, and
    # silently missed compaction, titles and the eval judge. Archiving at the
    # LLM dispatch seam covers them all by construction — including call sites
    # that do not exist yet.

    test "a plain complete/3 is archived" do
      assert {:final, "sync answer"} = SalixAgent.LLM.complete([%{role: "user"}], [], llm_opts())

      assert [request, response] = collect()
      assert request.boundary == :llm_request
      assert request.payload["call"] == "complete"
      assert response.boundary == :llm_response
      assert response.payload["content"] == "sync answer"
    end

    test "compaction is archived — it ships the whole history to the model" do
      messages = [%{role: "user", content: "conversation to be discarded"}]

      assert {:ok, _items, _meta} = SalixAgent.LLM.compact_context(messages, [], llm_opts())

      assert [request, response] = collect()
      assert request.payload["call"] == "compact_context"
      # This is the last point the pre-compaction history exists anywhere.
      assert Jason.encode!(request.payload) =~ "conversation to be discarded"
      assert response.payload["kind"] == "compacted"
    end

    test "streaming is archived" do
      assert {:final, "Hello world"} =
               SalixAgent.LLM.complete_stream([%{role: "user"}], [], fn _ -> :ok end, llm_opts())

      assert [request, response] = collect()
      assert request.payload["call"] == "complete_stream"
      assert response.payload["content"] == "Hello world"
    end

    test "a provider that raises still archives the request and an error response" do
      Application.put_env(:salix_agent, :llm, __MODULE__.Raising)

      assert_raise RuntimeError, fn ->
        SalixAgent.LLM.complete([%{role: "user"}], [], llm_opts())
      end

      # A request with no response would look like an anomaly; an explicit
      # error response says what happened.
      assert [request, response] = collect()
      assert request.boundary == :llm_request
      assert response.payload["kind"] == "error"
    end
  end

  describe "attribution" do
    # Archiving a call and being able to FIND it later are different
    # properties, and the seam only had the first. `llm_opts` is the template's
    # provider config — model, protocol, key, base url — resolved per template
    # and identical for every agent that shares one, so it names nobody. Every
    # round therefore archived with four empty header columns and landed on the
    # stream `agent::inbox`: one shared run for every agent and tenant on the
    # node, which `mix salix.archive.verify` cannot group and a per-tenant
    # `ALTER TABLE ... DELETE` — the only erasure that works without a key —
    # cannot find.

    # A canonical id, so the tenant can actually be derived from it.
    @agent "agt1_2092243300810489856_2092243300810489857_2092243300810489858"
    @identity [agent_id: @agent, session_id: "ses_live", round_id: "round-abc"]

    # The round's real shape: provider config, nothing else.
    defp template_opts, do: [metering: false, model: "some-model"]

    defp assert_attributed(fact) do
      assert fact.agent_id == @agent
      assert fact.session_id == "ses_live"
      assert fact.round_id == "round-abc"
      # Derived from the agent id rather than left empty — an unattributed
      # tenant is the field a purge actually needs.
      assert fact.tenant_id == SalixStore.Ids.tenant_id_from_agent!(@agent)
    end

    for {name, dispatch} <- [
          {"a streamed round is attributed from the call site's identity", :complete_stream},
          {"a plain complete is attributed", :complete},
          {"compaction is attributed", :compact_context}
        ] do
      test name do
        assert_dispatched(unquote(dispatch))

        assert [request, response] = collect()
        assert_attributed(request)
        assert_attributed(response)
      end
    end

    defp assert_dispatched(:complete_stream) do
      assert {:final, "Hello world"} =
               SalixAgent.LLM.complete_stream(
                 [%{role: "user"}],
                 [],
                 fn _ -> :ok end,
                 template_opts(),
                 @identity
               )
    end

    defp assert_dispatched(:complete) do
      assert {:final, "sync answer"} =
               SalixAgent.LLM.complete([%{role: "user"}], [], template_opts(), @identity)
    end

    defp assert_dispatched(:compact_context) do
      assert {:ok, _items, _meta} =
               SalixAgent.LLM.compact_context([%{role: "user"}], [], template_opts(), @identity)
    end

    test "a failed dispatch archives its error response attributed too" do
      # The arm that matters most for an audit: a request with an
      # unattributable error response beside it is a hole an operator has to
      # chase across every tenant on the node.
      Application.put_env(:salix_agent, :llm, __MODULE__.Raising)

      assert_raise RuntimeError, fn ->
        SalixAgent.LLM.complete([%{role: "user"}], [], template_opts(), @identity)
      end

      assert [request, response] = collect()
      assert_attributed(request)
      assert response.payload["kind"] == "error"
      assert_attributed(response)
    end

    test "dispatch metering is attributed from the same identity" do
      # The archive was not the only reader left guessing.
      # `BillingCore.Metering.LLMMetering.row_attrs/1` reads `salix_agent_id`,
      # `session_id` and `round_id` from the fact's TOP LEVEL — never nested
      # into `billing_context` — so every dispatch metered at this seam
      # (compaction, titles, the eval judge) wrote those columns null. Round is
      # unaffected: it builds its own meter context and dispatches with
      # metering off.
      previous = Application.get_env(:salix_agent, :llm_metering_mod)
      Application.put_env(:salix_agent, :llm_metering_mod, __MODULE__.RecordingMetering)
      on_exit(fn -> restore(:llm_metering_mod, previous) end)

      assert {:final, "sync answer"} =
               SalixAgent.LLM.complete([%{role: "user"}], [], template_opts(), @identity)

      assert_received {:metered, :before_llm_call, fact}
      assert fact.salix_agent_id == @agent
      assert fact.session_id == "ses_live"
      assert fact.round_id == "round-abc"
    end

    test "a keyword-list billing context does not fail the turn" do
      # Every producer builds a map today, so this never fired — but the seam's
      # billing reads used plain Access, which RAISES on a binary key against a
      # list, and they sit in the `do` arm of `metered_call/5`. A raise there
      # turns a provider call that SUCCEEDED into a failed turn, which is
      # exactly what observation code may never do.
      opts = [
        billing_context: [salix_agent_id: @agent, salix_tenant_id: "tnt_kw", surface: "internal"]
      ]

      assert {:final, "sync answer"} = SalixAgent.LLM.complete([%{role: "user"}], [], opts)

      assert [request, _response] = collect()
      assert request.agent_id == @agent
      assert request.tenant_id == "tnt_kw"
    end

    test "the seam cannot invent an identity nobody passed" do
      # Provider configuration cannot supply dispatch identity. Each caller must
      # pass identity and exercise attribution through its runtime boundary.
      assert {:final, "sync answer"} =
               SalixAgent.LLM.complete([%{role: "user"}], [], template_opts())

      assert [request, _response] = collect()
      assert request.agent_id == nil
      assert request.session_id == nil
    end
  end

  describe "streamed deltas" do
    test "private reasoning is captured even though it never reaches the result" do
      SalixAgent.LLM.complete_stream(
        [%{role: "user"}],
        [],
        fn _ -> :ok end,
        Keyword.put(llm_opts(), :on_reasoning_delta, fn _ -> :ok end)
      )

      [_request, response] = collect()
      deltas = response.payload["deltas"]

      assert deltas["text"] == "Hello world"
      assert deltas["delta_count"] == 4
      refute deltas["truncated"]

      visibilities = Enum.map(deltas["reasoning"], & &1["visibility"])
      assert "public_summary" in visibilities
      assert "private_reasoning" in visibilities

      # The whole point: this text exists nowhere in the terminal result.
      refute response.payload["content"] =~ "SECRET CHAIN OF THOUGHT"
      assert Jason.encode!(deltas) =~ "SECRET CHAIN OF THOUGHT"
    end

    test "the caller's own reasoning callback still runs" do
      parent = self()

      SalixAgent.LLM.complete_stream(
        [%{role: "user"}],
        [],
        fn _ -> :ok end,
        Keyword.put(llm_opts(), :on_reasoning_delta, fn delta ->
          send(parent, {:passed_through, delta.visibility})
        end)
      )

      assert_received {:passed_through, :public_summary}
      assert_received {:passed_through, :private_reasoning}
    end

    test "a non-streaming call archives no deltas key" do
      SalixAgent.LLM.complete([%{role: "user"}], [], llm_opts())
      [_request, response] = collect()
      refute Map.has_key?(response.payload, "deltas")
    end
  end

  describe "accumulator" do
    test "is inert when archiving is disabled" do
      Application.delete_env(:salix_agent, :event_archive_mod)

      assert Accumulator.new() == nil
      assert Accumulator.text(nil, "x") == :ok
      assert Accumulator.reasoning(nil, %{visibility: :private_reasoning, text: "x"}) == :ok
      assert Accumulator.drain(nil) == nil
    end

    test "caps a runaway stream and says so rather than buffering it whole" do
      key = Accumulator.new()
      chunk = :binary.copy("x", 1024 * 1024)
      for _ <- 1..12, do: Accumulator.text(key, chunk)

      drained = Accumulator.drain(key)

      assert drained["truncated"]
      assert drained["delta_count"] == 12
      assert byte_size(drained["text"]) <= 8 * 1024 * 1024
    end

    test "frees its row on drain" do
      key = Accumulator.new()
      Accumulator.text(key, "x")
      assert Accumulator.drain(key)
      assert Accumulator.drain(key) == nil
    end
  end

  describe "async tool settlement" do
    test "a result that settles after its dispatch window is archived" do
      # Async tools return async_running synchronously and land their terminal
      # result later in the actor. Missing them left no seq behind, so the
      # omission was invisible to verify — the one thing completeness cannot
      # tolerate.
      pending = %{
        session_id: "ses",
        tool_name: "long_running",
        tool_call_id: "call_1",
        call_index: 2,
        billing_context: %{"tenant_id" => "tnt"}
      }

      assert :ok =
               Emit.async_tool_result("agt", "ses", pending, %{
                 id: "call_1",
                 name: "long_running",
                 content: "finished later"
               })

      assert [fact] = collect()
      assert fact.boundary == :tool_result
      assert fact.direction == :in
      assert fact.session_id == "ses"
      assert fact.tenant_id == "tnt"
      assert fact.payload["async"] == true
      assert fact.payload["tool_call_id"] == "call_1"
      assert Jason.encode!(fact.payload) =~ "finished later"
    end
  end

  describe "the boundary set is closed" do
    test "every declared boundary maps to a known direction" do
      for boundary <- [:delivery, :llm_request, :llm_response, :tool_call, :tool_result, :egress] do
        assert :ok = EventArchive.record(%{boundary: boundary, payload: %{}})
        assert_received {:archived, %{boundary: ^boundary, direction: direction}}
        assert direction in [:in, :out]
      end
    end
  end

  defmodule Raising do
    @moduledoc false
    def complete(_messages, _tools), do: raise("provider exploded")
    def complete(_messages, _tools, _opts), do: raise("provider exploded")
  end
end
