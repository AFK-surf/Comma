defmodule SalixAgent.EventArchiveEmitTest do
  @moduledoc """
  The loop-safety contract for the archive emitters.

  These emitters sit directly in `SalixAgent.Round` and
  `AgentActor.SessionDelivery`. The invariant they must hold is not "archiving
  works" but "archiving cannot hurt the loop" — so most of this file is about
  what happens when things go wrong.
  """

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle
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
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:archived, fact})
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
    previous = SystemsRuntime.get_env(:salix_agent, :event_archive_mod)
    SystemsRuntime.put_env(:salix_agent, :event_archive_mod, module)

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :event_archive_mod, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :event_archive_mod)
    end)
  end

  describe "when no archive is configured" do
  end

  describe "loop safety" do
    test "an archive that raises never propagates into the caller" do
      use_archive(Exploding)

      assert {:error, _} = Emit.llm_response(:complete, {:final, "x"}, [])
      assert {:error, _} = Emit.delivery("agt", %{payload: %{}})
    end
  end

  describe "fact construction" do
    setup do
      use_archive(Recorder)
      :ok
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
