defmodule SalixAgent.TriageReasoningFloorTest do
  use SystemsClock.Case, async: true

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.LlmResolver
  alias SalixAgent.Models
  alias SalixAgent.RoundConfig

  @triage_origin %{
    "provider" => "internal",
    "source_actor_type" => "system",
    "source_message_id" => "triage-src-1",
    "triage_investigation" => %{"conversation_id" => "conv_triage_1"}
  }

  @ordinary_origin %{
    "provider" => "slack",
    "source_actor_type" => "provider_user",
    "source_message_id" => "slack-src-1"
  }

  describe "apply_triage_reasoning_floor/2" do
    test "upgrades gpt-6.1-terra low, nil, omitted, and medium effort to high in triage_investigation context" do
      triage_ctx = %{trusted_origins: [@triage_origin]}

      for current <- ["low", nil, "medium"] do
        llm_opts = %{"catalog_model" => "gpt-6.1-terra", "reasoning_effort" => current}
        upgraded = LlmResolver.apply_triage_reasoning_floor(llm_opts, triage_ctx)
        assert upgraded["reasoning_effort"] == "high"
        refute Map.has_key?(upgraded, :reasoning_effort)
      end

      omitted = %{"catalog_model" => "gpt-6.1-terra"}

      assert LlmResolver.apply_triage_reasoning_floor(omitted, triage_ctx)["reasoning_effort"] ==
               "high"

      atom_opts = %{model: "gpt-6.1-terra", reasoning_effort: "low"}

      atom_upgraded =
        LlmResolver.apply_triage_reasoning_floor(atom_opts, %{triage_investigation: true})

      assert atom_upgraded.reasoning_effort == "high"
      refute Map.has_key?(atom_upgraded, "reasoning_effort")
    end

    test "preserves higher reasoning effort levels without downgrading" do
      triage_ctx = %{trusted_origin: @triage_origin}

      for higher <- ["xhigh", "max", "ultra"] do
        llm_opts = %{"catalog_model" => "gpt-6.1-terra", "reasoning_effort" => higher}
        assert LlmResolver.apply_triage_reasoning_floor(llm_opts, triage_ctx) == llm_opts
      end
    end

    test "leaves ordinary non-triage worker and router contexts unchanged" do
      llm_opts = %{"catalog_model" => "gpt-6.1-terra", "reasoning_effort" => "low"}

      for ctx <- [
            %{},
            %{trusted_origin: @ordinary_origin},
            %{trusted_origins: [@ordinary_origin]},
            %{role: "router"},
            %{role: "worker", triage_investigation: false}
          ] do
        assert LlmResolver.apply_triage_reasoning_floor(llm_opts, ctx) == llm_opts
      end
    end

    test "does not inject reasoning_effort for models without efforts or unknown model ids" do
      triage_ctx = %{trusted_origins: [@triage_origin]}

      no_effort_model =
        Models.list()
        |> Enum.find(fn model -> model["efforts"] in [nil, []] end)

      if no_effort_model do
        llm_opts = %{"catalog_model" => no_effort_model["id"]}
        assert LlmResolver.apply_triage_reasoning_floor(llm_opts, triage_ctx) == llm_opts
      end

      unknown_opts = %{"catalog_model" => "custom-nonexistent-model-xyz"}
      assert LlmResolver.apply_triage_reasoning_floor(unknown_opts, triage_ctx) == unknown_opts
    end

    test "detects triage_investigation from real InternalSession handles" do
      llm_opts = %{"catalog_model" => "gpt-6.1-terra", "reasoning_effort" => "low"}

      triage_session =
        InternalSession.open(%State{
          agent_id: "worker-triage",
          session_id: "sess-triage",
          next_message_id: 2,
          last_seq: 1,
          messages: [
            %{
              id: 1,
              seq: 1,
              role: "user",
              source_message_id: "triage-src-1",
              trusted_origin: @triage_origin
            }
          ]
        })

      triage_sources = InternalSession.current_source_ids(triage_session)

      assert [@triage_origin] =
               InternalSession.current_turn_trusted_origins(triage_session, triage_sources)

      assert LlmResolver.apply_triage_reasoning_floor(llm_opts, triage_session)[
               "reasoning_effort"
             ] ==
               "high"

      ordinary_session =
        InternalSession.open(%State{
          agent_id: "worker-ordinary",
          session_id: "sess-ordinary",
          next_message_id: 2,
          last_seq: 1,
          messages: [
            %{
              id: 1,
              seq: 1,
              role: "user",
              source_message_id: "slack-src-1",
              trusted_origin: @ordinary_origin
            }
          ]
        })

      assert LlmResolver.apply_triage_reasoning_floor(llm_opts, ordinary_session) == llm_opts
    end
  end

  describe "RoundConfig.materialize_round_snapshot/3" do
    test "upgrades reasoning_effort for triage_investigation workers and preserves low for ordinary workers" do
      {:ok, skill_materialization} =
        SalixAgent.SkillProjection.prepare_materialization(%{
          agent_id: "worker-1",
          tenant_id: "tenant-1",
          group_id: "group-1"
        })

      snapshot = %{
        role: "worker",
        runtime_config: %{
          tenant_id: "tenant-1",
          group_id: "group-1",
          disabled_tools: [],
          inspector_policy: nil,
          purpose: nil,
          prompts: %{}
        },
        llm_opts: %{
          "catalog_model" => "gpt-6.1-terra",
          "reasoning_effort" => "low"
        },
        plugin_projection: SalixAgent.TestSupport.with_plugin_projection(%{})[:plugin_projection],
        skill_materialization: skill_materialization,
        config_inputs: %{
          group_flags: %{
            task_model_selection: false,
            memory_ask_worker_enabled: false,
            condensed_workspace_enabled: false,
            cloud_vm_retired: false,
            router_reply_style: nil
          },
          mcp_entries: [],
          mcp_state: %{}
        },
        session_config: %{platform: "slack"}
      }

      assert {:ok, triage_round} =
               RoundConfig.materialize_round_snapshot("worker-1", snapshot, %{
                 platform: "slack",
                 source_message_ids: ["triage-src-1"],
                 trusted_origins: [@triage_origin]
               })

      assert triage_round.llm_opts["reasoning_effort"] == "high"

      assert {:ok, ordinary_round} =
               RoundConfig.materialize_round_snapshot("worker-1", snapshot, %{
                 platform: "slack",
                 source_message_ids: ["slack-src-1"],
                 trusted_origins: []
               })

      assert ordinary_round.llm_opts["reasoning_effort"] == "low"
    end
  end
end
