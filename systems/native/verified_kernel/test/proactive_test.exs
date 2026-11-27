defmodule SalixVerifiedKernel.ProactiveTest do
  use ExUnit.Case, async: true

  alias SalixVerifiedKernel.Proactive

  describe "step_stop/4 and router_replied/1" do
    test "presents a stop once, absorbs router replies, closes once on working, and rearms on new stop" do
      since = 1_000

      assert {{:open, 1, 1_500}, {:present, {1, 1_500}, :ordinary, :high}} =
               Proactive.step_stop(:unseen, {:need, :options}, 1_500, since)

      # Repeating the same stop while open is a no-op
      assert {{:open, 1, 1_500}, :noop} =
               Proactive.step_stop({:open, 1, 1_500}, {:need, :options}, 1_500, since)

      # Router reply transitions open -> handled and absorbs stale index snapshots
      assert {{:handled, 1, 1_500}, true} = Proactive.router_replied({:open, 1, 1_500})

      assert {{:handled, 1, 1_500}, :noop} =
               Proactive.step_stop({:handled, 1, 1_500}, {:need, :options}, 1_500, since)

      # Returning to working closes into :left once
      assert {{:left, 1, 1_500}, {:close, {1, 1_500}}} =
               Proactive.step_stop({:handled, 1, 1_500}, :working, 1_600, since)

      assert {{:left, 1, 1_500}, :noop} =
               Proactive.step_stop({:left, 1, 1_500}, :working, 1_700, since)

      # Next stop rearms cleanly
      assert {{:open, 2, 2_000}, {:present, {2, 2_000}, :ordinary, :normal}} =
               Proactive.step_stop({:left, 1, 1_500}, :done, 2_000, since)
    end

    test "routes interactive system cards (login, secret, signin, device, rig) to code pool with high urgency" do
      for card <- [:login, :secret, "vault", :signin, :device, "adb", :rig] do
        assert {{:open, 1, 500}, {:present, {1, 500}, :code, :high}} =
                 Proactive.step_stop(:unseen, {:need, card}, 500, 10_000)
      end

      assert {{:open, 1, 500}, {:present, {1, 500}, :ordinary, :normal}} =
               Proactive.step_stop(:unseen, {:need, :options}, 500, 10_000)
    end
  end

  describe "effective_busy_until/2 and schedule_deferral/7" do
    test "code and reserve pools bypass calendar meeting deferral" do
      assert Proactive.effective_busy_until(:code, 9_000) == nil
      assert Proactive.effective_busy_until(:reserve, 9_000) == nil
      assert Proactive.effective_busy_until(:ordinary, 9_000) == 9_000
    end

    test "schedule_deferral strictly advances past now_ms and caps actionable deadlines at reserve_window_at" do
      assert {1_001, nil} =
               Proactive.schedule_deferral(900, 1_000, 60_000, nil, nil, nil, true)

      # Meeting ends at 50_000, ordinary opens at 20_000, but reserve window opens at 15_000:
      assert {15_000, 15_000} =
               Proactive.schedule_deferral(20_000, 10_000, 5_000, 50_000, 30_000, 15_000, true)
    end
  end

  describe "absorb_by_worker?/5 and gate_jev/3" do
    test "absorbs passive alerts sharing strong anchors with an in_progress station worker, never direct human or codes" do
      worker = ["github:AFK-surf/Cue/5451", "slack:C0BEVT4QPC7/1795064843.000100"]

      assert Proactive.absorb_by_worker?(
               false,
               false,
               false,
               ["github:AFK-surf/Cue/5451"],
               worker
             ) == true

      assert Proactive.absorb_by_worker?(
               true,
               false,
               false,
               ["github:AFK-surf/Cue/5451"],
               worker
             ) == false

      assert Proactive.absorb_by_worker?(
               false,
               true,
               false,
               ["github:AFK-surf/Cue/5451"],
               worker
             ) == false

      assert Proactive.absorb_by_worker?(
               false,
               false,
               true,
               ["github:AFK-surf/Cue/5451"],
               worker
             ) == false

      assert Proactive.absorb_by_worker?(
               false,
               false,
               false,
               ["github:AFK-surf/Cue/9999"],
               worker
             ) == false
    end

    test "gate_jev enforces calibrated [5000, 10000] bp floor" do
      assert Proactive.gate_jev(true, 9_200, 9_000) == :quiet
      assert Proactive.gate_jev(true, 8_999, 9_000) == :escalate_to_llm
      assert Proactive.gate_jev(false, 9_900, 9_000) == :escalate_to_llm
      assert Proactive.gate_jev(true, 4_999, 1_000) == :escalate_to_llm
    end
  end

  describe "CFT Triage verified gates and still.fail coordination" do
    test "triage_target_route, triage_boundary_action, and triage_intake? enforce recipient boundaries" do
      assert Proactive.triage_target_route("clickhouse_etl", "self", true) == :none
      assert Proactive.triage_target_route("clickhouse_etl", "self", false) == :self
      assert Proactive.triage_target_route("periodic_patrol", "other", false) == :other

      assert Proactive.triage_boundary_action(:none) == :allow
      assert Proactive.triage_boundary_action(:other) == :force_silence_outside_authority
      assert Proactive.triage_boundary_action(:self) == :force_silence_duplicate
      assert Proactive.triage_boundary_action(:mixed) == :force_silence_duplicate
      assert Proactive.triage_boundary_action(:invalid) == :reject_target

      assert Proactive.triage_intake?("callback", "none", false) == true
      assert Proactive.triage_intake?("clickhouse_etl", "mixed", true) == true
      assert Proactive.triage_intake?("clickhouse_etl", "mixed", false) == false
      assert Proactive.triage_intake?("scheduled_recheck", "none", false) == false
      assert Proactive.triage_intake?("periodic_patrol", "other", false) == false
    end

    test "decide_delegation_effect enforces double freshness and matching authority_ref" do
      assert Proactive.decide_delegation_effect({:fresh, "auth-1"}, :prepared, {:fresh, "auth-1"}) ==
               :commit

      assert Proactive.decide_delegation_effect({:fresh, "auth-1"}, :prepared, {:fresh, "auth-2"}) ==
               :suppress_authority_drift

      assert Proactive.decide_delegation_effect({:fresh, "auth-1"}, :prepared, :stale) ==
               :suppress_stale

      assert Proactive.decide_delegation_effect(:stale, :prepared, {:fresh, "auth-1"}) ==
               :suppress_stale

      assert Proactive.decide_delegation_effect(
               {:fresh, "auth-1"},
               :retryable_error,
               {:fresh, "auth-1"}
             ) == :retry_later

      assert Proactive.decide_delegation_effect(
               {:fresh, "auth-1"},
               :non_retryable_error,
               {:fresh, "auth-1"}
             ) == :block_permanent
    end

    test "settle_investigation_outcome bounds stale retries at 3 attempts" do
      assert Proactive.settle_investigation_outcome(:applied, 1) == :completed
      assert Proactive.settle_investigation_outcome(:stale, 1) == :retry
      assert Proactive.settle_investigation_outcome(:stale, 2) == :retry
      assert Proactive.settle_investigation_outcome(:stale, 3) == :failed
      assert Proactive.settle_investigation_outcome(:failed, 1) == :failed
    end

    test "triage_stillfail_guidance and clamp_follow_up_hours coordinate CFT Triage with still.fail" do
      assert Proactive.triage_stillfail_guidance(true, false, false, :working) ==
               :defer_silence_already_handled

      assert Proactive.triage_stillfail_guidance(false, true, true, {:need, :login}) ==
               :surface_blocker_with_follow_up

      assert Proactive.triage_stillfail_guidance(true, false, true, :failed) ==
               :surface_blocker_with_follow_up

      assert Proactive.triage_stillfail_guidance(false, true, false, :done) ==
               :verify_public_evidence

      assert Proactive.triage_stillfail_guidance(false, false, true, :failed) == :no_overlap

      assert Proactive.clamp_follow_up_hours(0) == 1
      assert Proactive.clamp_follow_up_hours(24) == 24
      assert Proactive.clamp_follow_up_hours(999) == 720
    end
  end
end
