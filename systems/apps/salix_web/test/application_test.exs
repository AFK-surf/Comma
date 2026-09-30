defmodule SalixWeb.ApplicationTest do
  use ExUnit.Case, async: false

  defmodule TestRuntimeDriver do
    @behaviour SalixMeet.RuntimeDriver

    @impl true
    def join(_meeting), do: :ok

    @impl true
    def leave(_meeting), do: :ok

    @impl true
    def stop(_meeting), do: :ok
  end

  setup do
    prev_web_public_base_url = Application.get_env(:salix_web, :public_base_url)
    prev_im_public_base_url = Application.get_env(:salix_im, :public_base_url)

    on_exit(fn ->
      restore_env(:salix_web, :public_base_url, prev_web_public_base_url)
      restore_env(:salix_im, :public_base_url, prev_im_public_base_url)
    end)

    :ok
  end

  test "native triage evaluation is a fixed composition-root capability" do
    assert [runtime_child, recovery_child, effect_child, companion_reaction_child] =
             SalixWeb.Application.native_triage_children()

    assert runtime_child.id == Salix.Bindings.TriageReviewRuntime

    assert {SalixIM.Triage.Runtime, :start_link, [runtime_opts]} = runtime_child.start
    assert runtime_opts[:id] == Salix.Bindings.TriageReviewRuntime
    assert runtime_opts[:name] == Salix.Bindings.TriageReviewRuntime
    assert runtime_opts[:mode] == :review
    assert runtime_opts[:namespace] == SalixStore.TriageKeys.default_namespace()

    assert runtime_opts[:context_port] == {BridgeForTeams.TriageContext, []}
    assert runtime_opts[:review_projection] == :slack

    assert runtime_opts[:evaluator_port] ==
             {Salix.Bindings.TriageEvaluator,
              [
                provider: SalixLlm.Provider,
                provider_config: :agent_template,
                transport_receipt: :single_attempt
              ]}

    assert recovery_child.id == Salix.Bindings.TriageReceiptRecovery

    assert {SalixIM.Triage.ReceiptRecovery, :start_link, [recovery_opts]} =
             recovery_child.start

    assert recovery_opts[:name] == Salix.Bindings.TriageReceiptRecovery
    assert recovery_opts[:runtime] == Salix.Bindings.TriageReviewRuntime

    assert recovery_opts[:lease_key] ==
             SalixStore.TriageKeys.ctl_im_triage_receipt_recovery_lease(
               SalixStore.TriageKeys.default_namespace()
             )

    assert effect_child.id == SalixIM.Triage.ProductEffectWorker

    assert {SalixIM.Triage.ProductEffectWorker, :start_link, [effect_opts]} =
             effect_child.start

    assert effect_opts[:name] == SalixIM.Triage.ProductEffectWorker
    assert effect_opts[:adapter] == SalixIM.Triage.AuditSink

    assert companion_reaction_child.id == SalixIM.Triage.CompanionReactionEffectWorker

    assert {SalixIM.Triage.ProductEffectWorker, :start_link, [companion_reaction_opts]} =
             companion_reaction_child.start

    assert companion_reaction_opts[:name] == SalixIM.Triage.CompanionReactionEffectWorker
    assert companion_reaction_opts[:adapter] == SalixIM.Triage.AuditSink

    assert companion_reaction_opts[:claim_fun] ==
             (&SalixStore.TriageProductRuntime.claim_companion_reactions/2)

    assert companion_reaction_opts[:settle_fun] ==
             (&SalixStore.TriageProductRuntime.settle_companion_reaction/2)

    assert :ok = Salix.App.configure()
  end

  test "shared audio transcription port is bound at the composition root" do
    assert :ok = Salix.App.configure()

    assert Application.get_env(:salix_agent, :audio_transcriber_mod) ==
             Salix.Bindings.AgentAudioTranscriber
  end

  test "legacy app env cannot disable, retarget, or retune native triage" do
    previous_runtime = Application.get_env(:salix_web, :native_triage_review_runtime)

    on_exit(fn ->
      restore_env(:salix_web, :native_triage_review_runtime, previous_runtime)
    end)

    for legacy <- [
          false,
          [namespace: "legacy-triage"],
          [
            namespace: "legacy-triage",
            debounce_ms: 5_000,
            max_wait_ms: 30_000,
            evaluation_timeout_ms: 20_000,
            engine: :review
          ]
        ] do
      Application.put_env(:salix_web, :native_triage_review_runtime, legacy)

      assert [runtime_child, recovery_child, effect_child, companion_reaction_child] =
               SalixWeb.Application.native_triage_children()

      assert {SalixIM.Triage.Runtime, :start_link, [runtime_opts]} = runtime_child.start
      assert runtime_opts[:namespace] == SalixStore.TriageKeys.default_namespace()
      assert runtime_opts[:mode] == :review
      assert runtime_opts[:context_port] == {BridgeForTeams.TriageContext, []}
      assert runtime_opts[:review_projection] == :slack
      refute Keyword.has_key?(runtime_opts, :debounce_ms)
      refute Keyword.has_key?(runtime_opts, :max_wait_ms)
      refute Keyword.has_key?(runtime_opts, :evaluation_timeout_ms)

      assert {SalixIM.Triage.ReceiptRecovery, :start_link, [recovery_opts]} =
               recovery_child.start

      assert recovery_opts[:lease_key] ==
               SalixStore.TriageKeys.ctl_im_triage_receipt_recovery_lease(
                 SalixStore.TriageKeys.default_namespace()
               )

      assert {SalixIM.Triage.ProductEffectWorker, :start_link, [effect_opts]} =
               effect_child.start

      assert effect_opts[:adapter] == SalixIM.Triage.AuditSink

      assert {SalixIM.Triage.ProductEffectWorker, :start_link, [companion_reaction_opts]} =
               companion_reaction_child.start

      assert companion_reaction_opts[:adapter] == SalixIM.Triage.AuditSink
      assert companion_reaction_opts[:name] == SalixIM.Triage.CompanionReactionEffectWorker
    end
  end

  test "sync_im_public_base_url projects the configured web public base URL into IM connects" do
    Application.put_env(:salix_web, :public_base_url, "https://feishu-smoke.example.test/")
    Application.delete_env(:salix_im, :public_base_url)

    assert :ok = SalixWeb.Application.sync_im_public_base_url()
    assert Application.get_env(:salix_im, :public_base_url) == "https://feishu-smoke.example.test"
  end

  test "calendar autojoin is a static child after Bandit and is reconstructed with its supervisor" do
    previous_calendar = Application.get_env(:salix_meet, :calendar_occurrences_mod)
    previous_channel = Application.get_env(:salix_meet, :meeting_channel_mod)
    previous_worker = Application.get_env(:salix_meet, :calendar_autojoin)
    previous_groups = Application.get_env(:salix_meet, :calendar_autojoin_channels)
    previous_runtime_driver = Application.get_env(:salix_meet, :runtime_driver)

    stop_calendar_autojoin()
    Application.delete_env(:salix_meet, :calendar_occurrences_mod)
    Application.delete_env(:salix_meet, :meeting_channel_mod)

    Application.put_env(:salix_meet, :calendar_autojoin,
      scan_interval_ms: 3_600_000,
      join_interval_ms: 3_600_000,
      max_groups_per_pass: 1,
      max_events_per_group: 1,
      max_concurrency: 1,
      task_timeout_ms: 1_000
    )

    # Keep the worker's immediate ticks side-effect-free. ConfigJson behavior
    # for populated group entries is covered in the store config tests.
    Application.put_env(:salix_meet, :calendar_autojoin_channels, [])
    Application.put_env(:salix_meet, :runtime_driver, TestRuntimeDriver)

    on_exit(fn ->
      Application.delete_env(:salix_meet, :calendar_autojoin)
      Application.delete_env(:salix_meet, :calendar_autojoin_channels)
      stop_calendar_autojoin()
      restore_env(:salix_meet, :calendar_occurrences_mod, previous_calendar)
      restore_env(:salix_meet, :meeting_channel_mod, previous_channel)
      restore_env(:salix_meet, :calendar_autojoin, previous_worker)
      restore_env(:salix_meet, :calendar_autojoin_channels, previous_groups)
      restore_env(:salix_meet, :runtime_driver, previous_runtime_driver)
    end)

    assert :ok = Salix.App.configure()

    assert Application.get_env(:salix_meet, :calendar_occurrences_mod) ==
             Salix.Bindings.MeetingCalendar

    assert Application.get_env(:salix_meet, :meeting_channel_mod) ==
             Salix.Bindings.MeetingChannel

    assert Application.get_env(:salix_agent, :calendar_mod) ==
             Salix.Bindings.AgentCalendar

    assert :ok = Salix.App.configure()
    refute Process.whereis(SalixMeet.CalendarAutojoin)

    assert SalixWeb.MeetingIngressSupervisor in SalixWeb.Application.children()

    children = SalixWeb.MeetingIngressSupervisor.children()
    bandit_index = Enum.find_index(children, &match?({Bandit, _}, &1))
    worker_index = Enum.find_index(children, &match?(%{id: SalixMeet.CalendarAutojoin}, &1))

    assert is_integer(bandit_index)
    assert is_integer(worker_index)
    assert bandit_index < worker_index

    assert {:ok, {%{strategy: :rest_for_one}, _child_specs}} =
             SalixWeb.MeetingIngressSupervisor.init([])

    worker_children = SalixWeb.Application.calendar_autojoin_children()
    assert [%{id: SalixMeet.CalendarAutojoin}] = worker_children

    assert {:error, :calendar_callback_endpoint_not_ready} =
             SalixWeb.MeetingIngressSupervisor.start_calendar_autojoin(
               Application.fetch_env!(:salix_meet, :calendar_autojoin),
               :missing_calendar_callback_listener
             )

    {:ok, supervisor} = Supervisor.start_link(worker_children, strategy: :one_for_one)
    first_pid = Process.whereis(SalixMeet.CalendarAutojoin)
    assert is_pid(first_pid) and Process.alive?(first_pid)
    first_ref = Process.monitor(first_pid)
    :ok = Supervisor.stop(supervisor)
    assert_receive {:DOWN, ^first_ref, :process, ^first_pid, :shutdown}, 1_000

    {:ok, restarted_supervisor} = Supervisor.start_link(worker_children, strategy: :one_for_one)
    restarted_pid = Process.whereis(SalixMeet.CalendarAutojoin)
    assert is_pid(restarted_pid) and Process.alive?(restarted_pid)
    refute restarted_pid == first_pid
    :ok = Supervisor.stop(restarted_supervisor)

    Application.delete_env(:salix_meet, :calendar_autojoin)

    refute Enum.any?(
             SalixWeb.MeetingIngressSupervisor.children(),
             &match?(%{id: SalixMeet.CalendarAutojoin}, &1)
           )
  end

  test "configure refuses to start autojoin without a ready meeting runtime driver" do
    previous_worker = Application.get_env(:salix_meet, :calendar_autojoin)
    previous_groups = Application.get_env(:salix_meet, :calendar_autojoin_channels)
    previous_runtime_driver = Application.get_env(:salix_meet, :runtime_driver)
    previous_runtime_url = Application.get_env(:salix_meet, :runtime_base_url)

    stop_calendar_autojoin()

    Application.put_env(:salix_meet, :calendar_autojoin,
      scan_interval_ms: 60_000,
      join_interval_ms: 30_000,
      max_groups_per_pass: 1,
      max_events_per_group: 1,
      max_concurrency: 1,
      task_timeout_ms: 1_000
    )

    Application.put_env(:salix_meet, :calendar_autojoin_channels, [])
    Application.delete_env(:salix_meet, :runtime_driver)
    Application.delete_env(:salix_meet, :runtime_base_url)

    on_exit(fn ->
      stop_calendar_autojoin()
      restore_env(:salix_meet, :calendar_autojoin, previous_worker)
      restore_env(:salix_meet, :calendar_autojoin_channels, previous_groups)
      restore_env(:salix_meet, :runtime_driver, previous_runtime_driver)
      restore_env(:salix_meet, :runtime_base_url, previous_runtime_url)
    end)

    assert :ok = Salix.App.configure()

    assert_raise RuntimeError,
                 "calendar autojoin requires a configured meeting runtime driver",
                 fn -> SalixWeb.Application.calendar_autojoin_children() end

    refute Process.whereis(SalixMeet.CalendarAutojoin)

    Application.put_env(:salix_meet, :runtime_driver, SalixMeet.RuntimeDriver.HTTP)
    refute SalixMeet.RuntimeDriver.configured?()

    Application.put_env(:salix_meet, :runtime_base_url, "http://meeting-runtime:8080")
    assert SalixMeet.RuntimeDriver.configured?()
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp stop_calendar_autojoin do
    for supervisor <- [
          SalixMeet.Supervisor,
          SalixWeb.Supervisor,
          SalixWeb.MeetingIngressSupervisor
        ],
        Process.whereis(supervisor) do
      case Supervisor.terminate_child(supervisor, SalixMeet.CalendarAutojoin) do
        :ok -> _ = Supervisor.delete_child(supervisor, SalixMeet.CalendarAutojoin)
        {:error, :not_found} -> :ok
      end
    end

    if pid = Process.whereis(SalixMeet.CalendarAutojoin) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    :ok
  end
end
