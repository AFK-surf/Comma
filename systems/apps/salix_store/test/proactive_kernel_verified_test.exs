defmodule SalixStore.ProactiveKernelVerifiedTest do
  use ExUnit.Case, async: true

  alias SalixStore.ProactiveKernel

  test "gate_jev_decision enforces machine-checked Jevons screening invariants" do
    assert ProactiveKernel.gate_jev_decision(%{
             "choice" => "quiet",
             "probability_bp" => 9_400,
             "quiet_threshold_bp" => 9_000
           }) == :quiet

    assert ProactiveKernel.gate_jev_decision(%{
             "choice" => "quiet",
             "probability_bp" => 8_500,
             "quiet_threshold_bp" => 9_000
           }) == :escalate_to_llm

    assert ProactiveKernel.gate_jev_decision(%{
             "choice" => "escalate",
             "probability_bp" => 9_900,
             "quiet_threshold_bp" => 9_000
           }) == :escalate_to_llm

    assert ProactiveKernel.gate_jev_decision(%{
             mode: :recall,
             probability_bp: 3_000,
             recall_threshold_bp: 2_500
           }) == :promote
  end

  test "absorb_by_worker? settles passive alerts on active worker strong anchors while preserving direct mentions and codes" do
    worker_anchors = ["github:acme/cue#42", "slack_thread:T1:C1:1700000000.000100"]

    assert ProactiveKernel.absorb_by_worker?(
             false,
             false,
             false,
             ["github:acme/cue#42"],
             worker_anchors
           )

    refute ProactiveKernel.absorb_by_worker?(
             true,
             false,
             false,
             ["github:acme/cue#42"],
             worker_anchors
           )

    refute ProactiveKernel.absorb_by_worker?(
             false,
             true,
             false,
             ["github:acme/cue#42"],
             worker_anchors
           )

    refute ProactiveKernel.absorb_by_worker?(
             false,
             false,
             true,
             ["github:acme/cue#42"],
             worker_anchors
           )

    refute ProactiveKernel.absorb_by_worker?(
             false,
             false,
             false,
             ["github:acme/cue#99"],
             worker_anchors
           )
  end

  test "effective_busy_until bypasses meeting deferral for code pool and preserves meeting end for ordinary pool" do
    assert ProactiveKernel.effective_busy_until(:code, 9_500_000) == nil
    assert ProactiveKernel.effective_busy_until(:ordinary, 9_500_000) == 9_500_000
    assert ProactiveKernel.effective_busy_until(:ordinary, nil) == nil
  end

  test "step_station_stop and station_router_replied enforce single-fire per stop and urgent code pool routing" do
    since = 1_000

    assert {{:open, 1, 5_000}, {:present, {1, 5_000}, :code, :high}} =
             ProactiveKernel.step_station_stop(:unseen, {:need, "login"}, 5_000, since)

    assert {{:open, 1, 5_000}, {:present, {1, 5_000}, :ordinary, :high}} =
             ProactiveKernel.step_station_stop(:unseen, {:need, "options"}, 5_000, since)

    assert {{:open, 1, 5_000}, :noop} =
             ProactiveKernel.step_station_stop({:open, 1, 5_000}, {:need, "login"}, 5_000, since)

    assert {{:handled, 1, 5_000}, true} =
             ProactiveKernel.station_router_replied({:open, 1, 5_000})

    assert {{:handled, 1, 5_000}, :noop} =
             ProactiveKernel.step_station_stop(
               {:handled, 1, 5_000},
               {:need, "login"},
               5_000,
               since
             )

    assert {{:open, 1, 6_000}, {:present, {1, 6_000}, :ordinary, :high}} =
             ProactiveKernel.step_station_stop(
               {:handled, 1, 5_000},
               {:need, "options"},
               6_000,
               since
             )
  end
end
