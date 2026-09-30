defmodule SalixAgent.EventArchiveEmitTest do
  @moduledoc """
  The loop-safety contract for the archive emitters.

  These emitters sit directly in `SalixAgent.Round` and
  `AgentActor.SessionDelivery`. The invariant they must hold is not "archiving
  works" but "archiving cannot hurt the loop" — so most of this file is about
  what happens when things go wrong.
  """

  use ExUnit.Case, async: false

  alias SalixAgent.EventArchive
  alias SalixAgent.EventArchive.Emit

  # A canonical agent id, so `SalixStore.Ids.tenant_id_from_agent!/1` can
  # actually derive a tenant from it. A made-up id would make the fallback
  # tests pass for the wrong reason.
  @canonical_agent "agt1_2092243300810489856_2092243300810489857_2092243300810489858"

  defmodule Recorder do
    @moduledoc false
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(fact) do
      send(self(), {:archived, fact})
      :ok
    end
  end

  defmodule Exploding do
    @moduledoc false
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(_fact), do: raise("archive is on fire")
  end

  defmodule Exiting do
    @moduledoc false
    @behaviour SalixAgent.EventArchive

    @impl true
    def record(_fact), do: exit(:boom)
  end

  defp use_archive(module) do
    previous = Application.get_env(:salix_agent, :event_archive_mod)
    Application.put_env(:salix_agent, :event_archive_mod, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:salix_agent, :event_archive_mod, previous),
        else: Application.delete_env(:salix_agent, :event_archive_mod)
    end)
  end

  describe "when no archive is configured" do
    test "every emitter is a no-op" do
      Application.delete_env(:salix_agent, :event_archive_mod)

      refute EventArchive.enabled?()
      assert :ok = Emit.delivery("agt", %{payload: %{}})
      assert :ok = Emit.llm_request(:complete, [], [], [])
      assert :ok = Emit.llm_response(:complete, {:final, "hi"}, [])
      assert :ok = Emit.tool_calls(%{agent_id: "a"}, [%{name: "x"}])
      assert :ok = Emit.tool_results(%{agent_id: "a"}, [%{ok: true}])
      assert :ok = Emit.egress(%{agent_id: "a"}, "s", %{})
    end

    test "does not evaluate payload shaping" do
      Application.delete_env(:salix_agent, :event_archive_mod)

      # A payload that would raise if shaped must not raise when disabled:
      # the guard has to come before the work, not after.
      assert :ok = Emit.llm_request(:complete, [], [], [{:a, :b, :c}])
    end
  end

  describe "loop safety" do
    test "an archive that raises never propagates into the caller" do
      use_archive(Exploding)

      assert {:error, _} = Emit.llm_response(:complete, {:final, "x"}, [])
      assert {:error, _} = Emit.delivery("agt", %{payload: %{}})
    end

    test "an archive that exits never propagates into the caller" do
      use_archive(Exiting)

      assert {:error, _} = Emit.egress(%{agent_id: "a"}, "s", %{"content" => "x"})
    end

    test "unencodable payload shapes are captured, not raised" do
      use_archive(Recorder)

      # PIDs, functions and refs all appear in real loop context maps.
      assert :ok =
               Emit.tool_calls(%{agent_id: "a", session_id: "s"}, [
                 %{name: "x", args: %{pid: self(), fun: &String.length/1, ref: make_ref()}}
               ])

      assert_received {:archived, fact}
      assert {:ok, _json} = Jason.encode(fact.payload)
    end

    test "the result is JSON-encodable for every provider response shape" do
      use_archive(Recorder)

      shapes = [
        {:assistant, "c", [%{id: "1", name: "t", args: %{}}]},
        {:assistant, "c", [], %{tokens: 1}},
        {:assistant, "c", [], %{tokens: 1}, %{trace: "x"}},
        {:final, "done"},
        {:final, "done", %{trace: "x"}},
        {:final, "done", %{p: 1}, %{trace: "x"}},
        {:error, %{reason: :timeout}},
        {:unsupported, :not_implemented},
        {:ok, [%{"type" => "summary"}], %{trace: "x"}},
        {:something_new, "forward compatible"}
      ]

      for shape <- shapes do
        assert :ok = Emit.llm_response(:complete, shape, [])
        assert_received {:archived, fact}
        assert {:ok, _} = Jason.encode(fact.payload), "not encodable: #{inspect(shape)}"
      end
    end
  end

  describe "fact construction" do
    setup do
      use_archive(Recorder)
      :ok
    end

    test "direction is derived from the boundary, not supplied by callers" do
      Emit.llm_request(:complete, [], [], [])
      assert_received {:archived, %{boundary: :llm_request, direction: :out}}

      Emit.llm_response(:complete, {:final, "x"}, [])
      assert_received {:archived, %{boundary: :llm_response, direction: :in}}

      Emit.tool_calls(%{agent_id: "a"}, [%{name: "t"}])
      assert_received {:archived, %{boundary: :tool_call, direction: :out}}

      Emit.tool_results(%{agent_id: "a"}, [%{ok: true}])
      assert_received {:archived, %{boundary: :tool_result, direction: :in}}

      Emit.delivery("agt", %{payload: %{}})
      assert_received {:archived, %{boundary: :delivery, direction: :in}}

      Emit.egress(%{agent_id: "a"}, "s", %{})
      assert_received {:archived, %{boundary: :egress, direction: :out}}
    end

    test "tenant, agent and session come from the billing context" do
      Emit.llm_request(:complete, [], [],
        billing_context: %{"tenant_id" => "tnt_7", "agent_id" => "a", "session_id" => "ses"}
      )

      assert_received {:archived, fact}
      assert fact.tenant_id == "tnt_7"
      assert fact.agent_id == "a"
      assert fact.session_id == "ses"
    end

    test "a real billing context is read under the names it actually uses" do
      # The unprefixed keys above are not what any producer in this system
      # writes. `SalixIm.AgentDeliveryPayload`, `Comma.Conversations`,
      # `SalixMeet.Runtime` and BridgeForTeams all emit the `salix_`-prefixed
      # form, so reading only the unprefixed names left these fields empty on
      # every path that HAD a billing context.
      Emit.llm_request(:complete, [], [],
        billing_context: %{
          "salix_tenant_id" => "tnt_real",
          "salix_agent_id" => @canonical_agent,
          "surface" => "internal"
        }
      )

      assert_received {:archived, fact}
      assert fact.tenant_id == "tnt_real"
      assert fact.agent_id == @canonical_agent
    end

    test "the prefixed agent id wins over a foreign one under the plain name" do
      # BridgeForTeams is the only producer that sets a plain `agent_id`, and
      # it holds ITS OWN record id. Preferring it would put a foreign id in a
      # plaintext, key-free index and name a stream after it — attribution that
      # looks valid while pointing at nothing in Salix.
      Emit.llm_request(:complete, [], [],
        billing_context: %{
          "agent_id" => "bft-11111111-2222-3333-4444-555555555555",
          "salix_agent_id" => @canonical_agent,
          "salix_tenant_id" => "tnt_bft"
        }
      )

      assert_received {:archived, fact}
      assert fact.agent_id == @canonical_agent
      assert fact.tenant_id == "tnt_bft"
    end

    test "the call site's identity is authoritative over everything else" do
      Emit.llm_request(
        :complete,
        [],
        [],
        [billing_context: %{"salix_agent_id" => "agt_stale", "salix_tenant_id" => "tnt_stale"}],
        agent_id: @canonical_agent,
        session_id: "ses_live",
        round_id: "round-abc",
        tenant_id: "tnt_live"
      )

      assert_received {:archived, fact}
      assert fact.agent_id == @canonical_agent
      assert fact.session_id == "ses_live"
      assert fact.round_id == "round-abc"
      assert fact.tenant_id == "tnt_live"
    end

    test "identity alone attributes a dispatch that has no billing context" do
      # This is the round's shape exactly: `llm_opts` is the template's
      # provider config and nothing else. Reading only those archived every
      # round with four empty columns onto one shared `agent::inbox` stream,
      # which a per-tenant erasure cannot find and `archive.verify` cannot
      # group. The tenant is derived from the agent id rather than stored
      # empty.
      Emit.llm_request(
        :complete,
        [],
        [],
        [model: "some-model", api_key: "sk-live-SECRET"],
        agent_id: @canonical_agent,
        session_id: "ses_live",
        round_id: "round-abc"
      )

      assert_received {:archived, fact}
      assert fact.agent_id == @canonical_agent
      assert fact.session_id == "ses_live"
      assert fact.round_id == "round-abc"
      assert fact.tenant_id == SalixStore.Ids.tenant_id_from_agent!(@canonical_agent)
    end

    test "a response and its reservation carry the same identity as the request" do
      # The reservation names the stream the response will land on. If it
      # disagreed with the response's own identity the redemption would miss
      # and the reserved position would stay unfilled — a reported gap for an
      # item that was never actually lost.
      identity = [agent_id: @canonical_agent, session_id: "ses_live", round_id: "round-abc"]

      Emit.llm_response(:complete, {:final, "x"}, [model: "m"], nil, nil, identity)

      assert_received {:archived, fact}
      assert fact.agent_id == @canonical_agent
      assert fact.session_id == "ses_live"
      assert fact.round_id == "round-abc"
      assert fact.tenant_id == SalixStore.Ids.tenant_id_from_agent!(@canonical_agent)
    end

    test "a keyword-list billing context does not lose the item" do
      # Access with a binary key RAISES on a keyword list, and that raise lands
      # in `safe/1` — which would drop the whole item rather than merely
      # leaving a field empty.
      Emit.tool_calls(
        %{agent_id: @canonical_agent, billing_context: [salix_tenant_id: "tnt_kw"]},
        [%{name: "t"}]
      )

      assert_received {:archived, fact}
      assert fact.tenant_id == "tnt_kw"
    end

    test "an async settlement takes its tenant from the pending record" do
      # A pending record keeps `tenant_id` copied from the tool context at
      # dispatch, and its billing context can be absent entirely. Reading only
      # the billing context left `tenant_id` nil on ordinary settlements, the
      # row stored "", and a per-tenant `ALTER TABLE ... DELETE` — the only
      # erasure that works without a key — skipped it.
      Emit.async_tool_result(@canonical_agent, "ses", %{tenant_id: "tnt_pending"}, %{ok: true})

      assert_received {:archived, fact}
      assert fact.tenant_id == "tnt_pending"
    end

    test "an async settlement falls back to the billing context, then to the agent id" do
      Emit.async_tool_result(
        @canonical_agent,
        "ses",
        %{billing_context: %{"tenant_id" => "tnt_billing"}},
        %{ok: true}
      )

      assert_received {:archived, %{tenant_id: "tnt_billing"}}

      # Neither present: the agent id names its own tenant, so there is no
      # excuse for storing "".
      Emit.async_tool_result(@canonical_agent, "ses", %{tool_name: "x"}, %{ok: true})

      assert_received {:archived, fact}
      assert fact.tenant_id == SalixStore.Ids.tenant_id_from_agent!(@canonical_agent)
    end

    test "an async settlement with no derivable tenant still archives" do
      # Archiving without a tenant beats not archiving at all — the fallback is
      # total, never a reason to abort the emit.
      Emit.async_tool_result("not-a-canonical-id", "ses", %{}, %{ok: true})

      assert_received {:archived, %{boundary: :tool_result, tenant_id: nil}}
    end

    test "empty tool call and result lists are skipped" do
      Emit.tool_calls(%{agent_id: "a"}, [])
      Emit.tool_results(%{agent_id: "a"}, [])
      refute_received {:archived, _}
    end

    test "an app revision is always stamped" do
      Emit.egress(%{agent_id: "a"}, "s", %{})
      assert_received {:archived, %{app_revision: revision}}
      assert is_binary(revision) and revision != ""
    end
  end

  describe "provider credentials" do
    setup do
      use_archive(Recorder)
      :ok
    end

    test "are scrubbed from archived LLM options" do
      # These are a THIRD party's credentials, not agent content. Archiving
      # them would put live provider keys in an object nobody can rotate them
      # out of.
      Emit.llm_request(:complete, [], [],
        model: "some-model",
        api_key: "sk-live-SECRET",
        base_url: "https://provider.example",
        headers: [{"authorization", "Bearer sk-live-SECRET"}]
      )

      assert_received {:archived, fact}
      encoded = Jason.encode!(fact.payload)

      refute encoded =~ "sk-live-SECRET"
      assert encoded =~ "[redacted]"

      # Keyword-list options sanitize to a list of pairs, not a map, so assert
      # on the encoded form — which is what actually reaches storage.
      assert encoded =~ ~s(["api_key","[redacted]"])

      # Non-credential options survive: they are what makes the request
      # reproducible for an auditor. Header VALUES are redacted by name rather
      # than the whole container, so anthropic-version and routing headers stay.
      assert encoded =~ ~s(["model","some-model"])
      assert encoded =~ ~s(["base_url","https://provider.example"])
    end

    test "message content is never scrubbed" do
      Emit.llm_request(:complete, [%{role: "user", content: "my password is hunter2"}], [], [])

      assert_received {:archived, fact}
      # The archive exists to capture exactly this. Redaction is the key
      # holder's job, not the writer's.
      assert Jason.encode!(fact.payload) =~ "hunter2"
    end

    test "resident provider requests archive the exact body with dispatch identity" do
      body = ~s({"model":"test","messages":[{"role":"user","content":"雪"}]})

      Emit.llm_request(
        :complete_stream,
        {:encoded_provider_request, "chat", body},
        [],
        [api_key: "never-archive-this-key"],
        agent_id: @canonical_agent,
        session_id: "session",
        round_id: "round"
      )

      assert_received {:archived, fact}
      assert fact.payload["request_body"] == body
      assert fact.payload["protocol"] == "chat"
      assert fact.session_id == "session"
      assert fact.round_id == "round"
      refute Jason.encode!(fact.payload) =~ "never-archive-this-key"
    end
  end
end
