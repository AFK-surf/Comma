# ruby recovery_test.rb  (host: /usr/bin/ruby 2.6; RECOVERY_RB=<path> tests a deployed copy)
require 'minitest/autorun'
require File.expand_path(ENV.fetch('RECOVERY_RB', File.join(__dir__, 'recovery.rb')))

class StuckAcquireTest < Minitest::Test
  DATA = ENV.fetch('TESTDATA', File.join(__dir__, 'testdata'))
  STUCK_LOG = File.read(File.join(DATA, 'Runner_stuck_ci05.log'))
  HEALTHY_LOG = File.read(File.join(DATA, 'Runner_healthy.log'))
  T = Time.utc(2026, 10, 8, 2, 45, 0) # ~10 min after ci-05's last line

  def probe(log, o = {})
    {listener: true, worker: false, work_entries: 0, log: log}.merge(o)
  end

  def test_ci05_saved_log_is_stuck_only_after_threshold
    assert_equal :stuck, StuckAcquire.classify(probe(STUCK_LOG), T)
    assert_equal :healthy, StuckAcquire.classify(probe(STUCK_LOG), Time.utc(2026, 10, 8, 2, 37, 0))
  end

  def test_normal_job_log_is_healthy
    assert_equal :healthy, StuckAcquire.classify(probe(HEALTHY_LOG, worker: true, work_entries: 1), T + 3600)
    # Even if worker/_work probes miss, "Running job" after the ack keeps it healthy.
    assert_equal :healthy, StuckAcquire.classify(probe(HEALTHY_LOG), T + 3600)
  end

  def test_worker_or_work_dir_means_healthy
    assert_equal :healthy, StuckAcquire.classify(probe(STUCK_LOG, worker: true), T)
    assert_equal :healthy, StuckAcquire.classify(probe(STUCK_LOG, work_entries: 2), T)
  end

  def test_idle_listener_without_ack_is_healthy
    idle = STUCK_LOG[0...STUCK_LOG.index('Acknowledging')]
    assert_equal :healthy, StuckAcquire.classify(probe(idle), T + 3600)
  end

  def test_probe_failure_is_unknown
    assert_equal :unknown, StuckAcquire.classify(nil, T)
    assert_equal :unknown, StuckAcquire.classify(probe(nil), T)
  end
end

class WatchdogTickTest < Minitest::Test
  class FakeAdapter
    attr_accessor :vm, :probe_result, :probes, :stops, :diags
    def initialize(probe_result)
      @vm = {'state' => 'running', 'identity' => 'a'}
      @probe_result, @probes, @stops, @diags = probe_result, 0, [], 0
    end
    def snapshot; @vm.dup; end
    def probe; @probes += 1; @probe_result; end
    def save_diag(_now); @diags += 1; '/diag'; end
    def stop_vm(expected); @stops << expected; end
  end

  STUCK = {now: StuckAcquireTest::T, listener: true, worker: false, work_entries: 0,
           log: StuckAcquireTest::STUCK_LOG}.freeze

  def run_ticks(adapter, times)
    recovery = RunnerRecovery.new(adapter, {})
    results = times.map { |t| recovery.tick(t) }
    [recovery, results]
  end

  def test_second_stuck_probe_stops_vm_once
    adapter = FakeAdapter.new(STUCK)
    recovery, results = run_ticks(adapter, [0, 30, 299, 300, 330])
    assert_equal [:observing, :preserved_running, :preserved_running, :preserved_running, :recycled_stuck_acquire], results
    assert_equal 2, adapter.probes # nothing probed before the VM is 5 minutes old
    assert_equal [adapter.vm], adapter.stops
    assert_equal ['watchdog stuck 1', 'watchdog stuck 2', 'RECYCLED_STUCK_ACQUIRE diag=/diag'], recovery.notes
  end

  def test_unknown_or_healthy_probe_breaks_the_streak
    adapter = FakeAdapter.new(STUCK)
    recovery = RunnerRecovery.new(adapter, {})
    [0, 300].each { |t| recovery.tick(t) }
    adapter.probe_result = nil
    assert_equal :preserved_running, recovery.tick(330)
    adapter.probe_result = STUCK
    assert_equal :preserved_running, recovery.tick(360)
    assert_empty adapter.stops
    assert_equal ['watchdog stuck 1', 'watchdog unknown', 'watchdog stuck 1'], recovery.notes
  end

  def test_new_vm_does_not_inherit_a_stuck_count
    adapter = FakeAdapter.new(STUCK)
    recovery = RunnerRecovery.new(adapter, {})
    [0, 300].each { |t| recovery.tick(t) }
    adapter.vm = {'state' => 'running', 'identity' => 'b'}
    assert_equal :observing, recovery.tick(330)
    assert_equal :preserved_running, recovery.tick(630)
    assert_empty adapter.stops
  end

  def test_healthy_vm_is_reported_once_and_kept
    adapter = FakeAdapter.new(STUCK.merge(worker: true))
    recovery, results = run_ticks(adapter, [0, 300, 330, 360])
    assert_equal [:preserved_running] * 3, results.drop(1)
    assert_empty adapter.stops
    assert_equal ['watchdog healthy'], recovery.notes
  end
end

class SessionAlertTest < Minitest::Test
  class FakeAdapter
    attr_accessor :session, :markers
    def initialize; @session, @markers = false, []; end
    def session?; @session; end
    def write_session_marker(text); @markers << text; end
    def clear_session_marker; @markers << :cleared; end
  end

  def test_one_alert_per_episode_after_ten_minutes
    adapter = FakeAdapter.new
    recovery = RunnerRecovery.new(adapter, {})
    assert_equal [false] * 3, [0, 300, 600].map { |t| recovery.session_ok?(1_000 + t) }
    assert_empty recovery.notes # exactly 10 minutes is not yet "more than 10 minutes"
    recovery.session_ok?(1_000 + 601)
    recovery.session_ok?(1_000 + 3_600)
    assert_equal 1, recovery.notes.grep(/\ASESSION_LOST no GUI login session since 1970-01-01T00:16:40Z/).length
    assert_equal ["since=1970-01-01T00:16:40Z\n"], adapter.markers
    adapter.session = true
    assert recovery.session_ok?(1_000 + 3_630)
    assert_equal 'SESSION_RESTORED after 3630s', recovery.notes.last
    assert_equal :cleared, adapter.markers.last
    assert_equal({}, recovery.state)
  end

  def test_short_gap_is_silent_and_restarts_the_clock
    adapter = FakeAdapter.new
    recovery = RunnerRecovery.new(adapter, {})
    recovery.session_ok?(0)
    recovery.session_ok?(500)
    adapter.session = true
    assert recovery.session_ok?(530)
    adapter.session = false
    [560, 1_100].each { |t| recovery.session_ok?(t) }
    assert_empty recovery.notes
    assert_empty adapter.markers
  end

  def test_launchctl_failure_means_no_session
    adapter = MacAdapter.allocate
    adapter.instance_variable_set(:@uid, 501)
    adapter.define_singleton_method(:command) { |*_args| raise 'command failed' }
    refute adapter.session?
    adapter.define_singleton_method(:command) { |*_args| "gui/501 = {\n" }
    assert adapter.session?
  end
end

class MacAdapterProbeTest < Minitest::Test
  def adapter_returning(output)
    adapter = MacAdapter.allocate
    adapter.define_singleton_method(:tart) { |*_args| output.respond_to?(:call) ? output.call : output.dup }
    adapter
  end

  def test_parses_guest_output
    log = "[2026-10-08 02:34:45Z INFO BrokerMessageListener] Acknowledging runner request 'x'.\n"
    probe = adapter_returning("1791427200\n1\n0\n       0\n#{log}").probe
    assert_equal({now: Time.at(1791427200), listener: true, worker: false, work_entries: 0, log: log}, probe)
  end

  def test_unreadable_guest_is_nil
    assert_nil adapter_returning("garbage\n").probe
    assert_nil adapter_returning(-> { raise 'command timeout' }).probe
  end
end
