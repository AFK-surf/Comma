defmodule SalixWeb.ApplicationTest do
  require SystemsRuntime.Proc

  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle,
    scope: ["Elixir.SalixWeb", "Elixir.SalixEnv", "Elixir.SalixMeet"]

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
    prev_web_public_base_url = SystemsRuntime.get_env(:salix_web, :public_base_url)
    prev_im_public_base_url = SystemsRuntime.get_env(:salix_im, :public_base_url)

    on_exit(fn ->
      restore_env(:salix_web, :public_base_url, prev_web_public_base_url)
      restore_env(:salix_im, :public_base_url, prev_im_public_base_url)
    end)

    :ok
  end

  test "sync_im_public_base_url projects the configured web public base URL into IM connects" do
    SystemsRuntime.put_env(:salix_web, :public_base_url, "https://feishu-smoke.example.test/")
    SystemsRuntime.delete_env(:salix_im, :public_base_url)

    assert :ok = SalixWeb.Application.sync_im_public_base_url()

    assert SystemsRuntime.get_env(:salix_im, :public_base_url) ==
             "https://feishu-smoke.example.test"
  end

  test "calendar autojoin is a static child after Bandit and is reconstructed with its supervisor" do
    previous_calendar = SystemsRuntime.get_env(:salix_meet, :calendar_occurrences_mod)
    previous_channel = SystemsRuntime.get_env(:salix_meet, :meeting_channel_mod)
    previous_worker = SystemsRuntime.get_env(:salix_meet, :calendar_autojoin)
    previous_groups = SystemsRuntime.get_env(:salix_meet, :calendar_autojoin_channels)
    previous_runtime_driver = SystemsRuntime.get_env(:salix_meet, :runtime_driver)

    stop_calendar_autojoin()
    SystemsRuntime.delete_env(:salix_meet, :calendar_occurrences_mod)
    SystemsRuntime.delete_env(:salix_meet, :meeting_channel_mod)

    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin,
      scan_interval_ms: 3_600_000,
      join_interval_ms: 3_600_000,
      max_groups_per_pass: 1,
      max_events_per_group: 1,
      max_concurrency: 1,
      task_timeout_ms: 1_000
    )

    # Keep the worker's immediate ticks side-effect-free. ConfigJson behavior
    # for populated group entries is covered in the store config tests.
    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin_channels, [])
    SystemsRuntime.put_env(:salix_meet, :runtime_driver, TestRuntimeDriver)

    on_exit(fn ->
      SystemsRuntime.delete_env(:salix_meet, :calendar_autojoin)
      SystemsRuntime.delete_env(:salix_meet, :calendar_autojoin_channels)
      stop_calendar_autojoin()
      restore_env(:salix_meet, :calendar_occurrences_mod, previous_calendar)
      restore_env(:salix_meet, :meeting_channel_mod, previous_channel)
      restore_env(:salix_meet, :calendar_autojoin, previous_worker)
      restore_env(:salix_meet, :calendar_autojoin_channels, previous_groups)
      restore_env(:salix_meet, :runtime_driver, previous_runtime_driver)
    end)

    assert :ok = Salix.App.configure()

    assert SystemsRuntime.get_env(:salix_meet, :calendar_occurrences_mod) ==
             Salix.Bindings.MeetingCalendar

    assert SystemsRuntime.get_env(:salix_meet, :meeting_channel_mod) ==
             Salix.Bindings.MeetingChannel

    assert SystemsRuntime.get_env(:salix_agent, :calendar_mod) ==
             Salix.Bindings.AgentCalendar

    assert :ok = Salix.App.configure()
    refute SystemsRuntime.Proc.whereis(SalixMeet.CalendarAutojoin)

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
               SystemsRuntime.fetch_env!(:salix_meet, :calendar_autojoin),
               :missing_calendar_callback_listener
             )

    {:ok, supervisor} = Supervisor.start_link(worker_children, strategy: :one_for_one)
    first_pid = SystemsRuntime.Proc.whereis(SalixMeet.CalendarAutojoin)
    assert SystemsRuntime.Proc.is_process(first_pid) and SystemsRuntime.Proc.alive?(first_pid)
    first_ref = SystemsRuntime.Proc.monitor(first_pid)
    :ok = Supervisor.stop(supervisor)
    settle_receive({:DOWN, ^first_ref, :process, ^first_pid, :shutdown})
    {:ok, restarted_supervisor} = Supervisor.start_link(worker_children, strategy: :one_for_one)
    restarted_pid = SystemsRuntime.Proc.whereis(SalixMeet.CalendarAutojoin)

    assert SystemsRuntime.Proc.is_process(restarted_pid) and
             SystemsRuntime.Proc.alive?(restarted_pid)

    refute restarted_pid == first_pid
    :ok = Supervisor.stop(restarted_supervisor)

    SystemsRuntime.delete_env(:salix_meet, :calendar_autojoin)

    refute Enum.any?(
             SalixWeb.MeetingIngressSupervisor.children(),
             &match?(%{id: SalixMeet.CalendarAutojoin}, &1)
           )
  end

  test "configure refuses to start autojoin without a ready meeting runtime driver" do
    previous_worker = SystemsRuntime.get_env(:salix_meet, :calendar_autojoin)
    previous_groups = SystemsRuntime.get_env(:salix_meet, :calendar_autojoin_channels)
    previous_runtime_driver = SystemsRuntime.get_env(:salix_meet, :runtime_driver)
    previous_runtime_url = SystemsRuntime.get_env(:salix_meet, :runtime_base_url)

    stop_calendar_autojoin()

    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin,
      scan_interval_ms: 60_000,
      join_interval_ms: 30_000,
      max_groups_per_pass: 1,
      max_events_per_group: 1,
      max_concurrency: 1,
      task_timeout_ms: 1_000
    )

    SystemsRuntime.put_env(:salix_meet, :calendar_autojoin_channels, [])
    SystemsRuntime.delete_env(:salix_meet, :runtime_driver)
    SystemsRuntime.delete_env(:salix_meet, :runtime_base_url)

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

    refute SystemsRuntime.Proc.whereis(SalixMeet.CalendarAutojoin)

    SystemsRuntime.put_env(:salix_meet, :runtime_driver, SalixMeet.RuntimeDriver.HTTP)
    refute SalixMeet.RuntimeDriver.configured?()

    SystemsRuntime.put_env(:salix_meet, :runtime_base_url, "http://meeting-runtime:8080")
    assert SalixMeet.RuntimeDriver.configured?()
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)

  defp stop_calendar_autojoin do
    for supervisor <- [
          SalixMeet.Supervisor,
          SalixWeb.Supervisor,
          SalixWeb.MeetingIngressSupervisor
        ],
        SystemsRuntime.Proc.whereis(supervisor) do
      case Supervisor.terminate_child(supervisor, SalixMeet.CalendarAutojoin) do
        :ok -> _ = Supervisor.delete_child(supervisor, SalixMeet.CalendarAutojoin)
        {:error, :not_found} -> :ok
      end
    end

    if pid = SystemsRuntime.Proc.whereis(SalixMeet.CalendarAutojoin) do
      ref = SystemsRuntime.Proc.monitor(pid)
      SystemsRuntime.Proc.exit(pid, :shutdown)
      settle_receive({:DOWN, ^ref, :process, ^pid, _reason})
    end

    :ok
  end
end
