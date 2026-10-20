#!/usr/bin/ruby
# Repairs only the explicitly disposable afk-ci-base-v1-1 clone.
require 'json'
require 'open3'
require 'timeout'
require 'time'
require 'fileutils'
require 'etc'

# A runner that acknowledged a job but never started a Worker (ci-05, 2026-10-08:
# last line 02:34:47Z after "Acknowledging runner request") keeps its VM running
# while GitHub declares the job lost. Any probe failure is :unknown (leave VM alone).
module StuckAcquire
  STALE_SECONDS = 300
  LINE_TIME = /\A\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\dZ) /

  # probe: {listener: bool, worker: bool, work_entries: Integer, log: String}; now: VM clock
  def self.classify(probe, now)
    return :unknown if probe.nil? || probe[:log].nil? || now.nil?
    return :healthy unless probe[:listener]
    return :healthy if probe[:worker] || probe[:work_entries].to_i > 0
    log = probe[:log]
    ack = log.rindex('Acknowledging runner request')
    return :healthy if ack.nil?
    return :healthy if log.index('Running job', ack)
    last = log.lines.reverse_each.lazy.map { |l| l[LINE_TIME, 1] }.find { |t| t }
    return :unknown if last.nil?
    now - Time.parse(last.sub('Z', ' UTC')) >= STALE_SECONDS ? :stuck : :healthy
  end
end

class RunnerRecovery
  attr_reader :state, :notes
  def initialize(adapter, state = {})
    @adapter, @state, @notes = adapter, state, []
  end

  def tick(now)
    current = @adapter.snapshot
    fingerprint = [current['state'], current['identity']]
    if @state['observed'] != fingerprint
      @state['observed'], @state['since'] = fingerprint, now
      @state.delete('stuck')
      @state.delete('watch')
      return :observing
    end
    if current['state'] == 'running'
      if now - @state.fetch('since', now) >= 120
        @state['attempts'] = 0
        @state['next_retry'] = 0
      end
      return :recycled_stuck_acquire if stuck_acquire?(current, now)
      return :preserved_running
    end
    # Normal VM shutdown/clone turnover gets time to finish without intervention.
    grace = current['state'] == 'missing' ? 120 : 30
    return :observing if now - @state.fetch('since', now) < grace
    return :backoff if now < @state.fetch('next_retry', 0)
    @state['attempts'] = [@state.fetch('attempts', 0) + 1, 5].min
    @state['next_retry'] = now + [30 * (2 ** @state['attempts']), 300].min
    @adapter.stop_manager
    after = @adapter.snapshot
    # Never delete a VM that started, was replaced, or became unreadable.
    unless after == current
      return :changed_preserved
    end
    @adapter.delete_stopped_clone(current) if current['state'] == 'stopped'
    @adapter.start_manager
    @state.delete('observed')
    :restarted
  end

  SESSION_ALERT_SECONDS = 600

  # The GUI session can end without a reboot (ci-00, 2026-10-07: a WindowServer
  # watchdog kill logged ci-00 out); auto-login only runs at boot, so nothing brings
  # Tartelet back. After 10 min without a session: one SESSION_LOST line and a
  # marker file per episode, cleared with SESSION_RESTORED.
  def session_ok?(now)
    if @adapter.session?
      since = @state.delete('session_lost_since')
      if @state.delete('session_alerted')
        @adapter.clear_session_marker
        @notes << "SESSION_RESTORED after #{now - since}s"
      end
      return true
    end
    since = (@state['session_lost_since'] ||= now)
    if now - since > SESSION_ALERT_SECONDS && !@state['session_alerted']
      lost = Time.at(since).utc.iso8601
      @adapter.write_session_marker("since=#{lost}\n")
      @state['session_alerted'] = true
      @notes << "SESSION_LOST no GUI login session since #{lost}; Tartelet cannot run until the user logs in (reboot auto-logs in)"
    end
    false
  end

  # Stops a VM up >= 5 min whose runner looked stuck on two ticks in a row; the
  # stopped-VM path above then replaces it.
  def stuck_acquire?(current, now)
    return false if now - @state.fetch('since', now) < 300
    probe = @adapter.probe
    verdict = StuckAcquire.classify(probe, probe && probe[:now])
    @state['stuck'] = verdict == :stuck ? @state.fetch('stuck', 0) + 1 : 0
    note = verdict == :stuck ? "watchdog stuck #{@state['stuck']}" : "watchdog #{verdict}"
    @notes << note unless @state['watch'] == note
    @state['watch'] = note
    return false if @state['stuck'] < 2
    diag = @adapter.save_diag(now)
    @adapter.stop_vm(current)
    @notes << "RECYCLED_STUCK_ACQUIRE diag=#{diag}"
    true
  end
end

class MacAdapter
  VM = 'afk-ci-base-v1-1'.freeze
  SESSION_MARKER = '/Library/AFK-CI/runner-deploy/recovery/SESSION_LOST'.freeze
  def initialize(user)
    raise 'invalid user' unless user.match?(/\Aci-0[0-8]\z/)
    @user, @uid, @home = user, Etc.getpwnam(user).uid, "/Users/#{user}"
    @service = "gui/#{@uid}/com.afk.ci.tartelet"
  end

  def command(*argv)
    output = ''
    status = nil
    Open3.popen2e(*argv, pgroup: true) do |input, stream, thread|
      input.close
      begin
        Timeout.timeout(15) { output = stream.read; status = thread.value }
      rescue Timeout::Error
        Process.kill('KILL', -thread.pid) rescue nil
        raise 'command timeout'
      end
    end
    raise 'command failed' unless status.success?
    output
  end

  def tart(*args)
    command('/usr/bin/sudo', '-n', '-u', @user, '/usr/bin/env',
            "HOME=#{@home}", "TART_HOME=#{@home}/.tart", '/usr/local/bin/tart', *args)
  end

  def snapshot
    rows = JSON.parse(tart('list', '--source', 'local', '--format', 'json'))
    raise 'invalid VM inventory' unless rows.is_a?(Array)
    matches = rows.select { |r| r['Name'] == VM && r['Source'] == 'local' }
    raise 'ambiguous VM inventory' if matches.length > 1
    path = "#{@home}/.tart/vms/#{VM}"
    if matches.empty?
      raise 'incomplete VM inventory' if File.exist?(path) || File.symlink?(path)
      return {'state' => 'missing', 'identity' => nil}
    end
    row = matches.first
    raise 'unexpected VM state' unless ['running', 'stopped'].include?(row['State'])
    raise 'inconsistent VM state' unless row['Running'] == (row['State'] == 'running')
    raise 'refuse linked VM' if File.symlink?(path)
    stat = File.stat(path)
    {'state' => row['State'], 'identity' => "#{stat.dev}:#{stat.ino}:#{stat.birthtime.to_f}"}
  end

  # False when the user's GUI login session is gone; Tartelet cannot run without it.
  def session?
    command('/bin/launchctl', 'print', "gui/#{@uid}")
    true
  rescue StandardError
    false
  end

  def write_session_marker(text)
    temporary = "#{SESSION_MARKER}.new"
    File.write(temporary, text, mode: 'w', perm: 0644)
    File.rename(temporary, SESSION_MARKER)
  end

  def clear_session_marker
    FileUtils.rm_f(SESSION_MARKER)
  end

  def ready?
    d = '/Library/AFK-CI/runner-deploy'
    File.file?("#{d}/base.ready") && File.file?("#{d}/rollout-approved")
  end

  def stop_manager
    if system('/bin/launchctl', 'print', @service, out: File::NULL, err: File::NULL)
      command('/bin/launchctl', 'bootout', @service)
    end
    # Refuse to clean up while an independently launched Tartelet still exists.
    if system('/usr/bin/pgrep', '-u', @uid.to_s, '-x', 'Tartelet', out: File::NULL)
      raise 'manager still running'
    end
  end

  def delete_stopped_clone(expected)
    # Third state check immediately before invoking Tart; no wildcard paths.
    raise 'VM changed before deletion' unless expected['state'] == 'stopped' && snapshot == expected
    tart('delete', VM)
  end

  RUNNER = '/Users/admin/actions-runner'.freeze
  PROBE = "date -u +%s; pgrep -x Runner.Listener >/dev/null && echo 1 || echo 0; " \
          "pgrep -x Runner.Worker >/dev/null && echo 1 || echo 0; ls -A #{RUNNER}/_work 2>/dev/null | wc -l; " \
          "f=$(ls -1 #{RUNNER}/_diag/Runner_*.log 2>/dev/null | tail -1); [ -n \"$f\" ] && tail -c 65536 \"$f\"; true".freeze

  # Returns nil when the guest cannot be read; the watchdog treats that as unknown.
  def probe
    head = tart('exec', VM, '/bin/sh', '-c', PROBE).force_encoding('UTF-8').scrub.split("\n", 5)
    return nil unless head.length >= 4 && head[0..3].all? { |v| v.strip.match?(/\A\d+\z/) }
    {now: Time.at(head[0].to_i), listener: head[1] == '1', worker: head[2] == '1',
     work_entries: head[3].to_i, log: head[4].to_s}
  rescue StandardError
    nil
  end

  # Best effort: a failed copy must not keep a stuck VM alive.
  def save_diag(now)
    dir = "/Library/AFK-CI/runner-deploy/recovery/stuck-#{Time.at(now).utc.strftime('%Y%m%dT%H%M%SZ')}"
    FileUtils.mkdir_p(dir, mode: 0700)
    File.binwrite("#{dir}/_diag.tgz", tart('exec', VM, '/bin/sh', '-c', "cd #{RUNNER} && tar -czf - _diag 2>/dev/null"))
    command('/usr/bin/tar', '-xzf', "#{dir}/_diag.tgz", '-C', dir)
    dir
  rescue StandardError => error
    "#{dir} (failed: #{error.class})"
  end

  def stop_vm(expected)
    raise 'VM changed before stop' unless expected['state'] == 'running' && snapshot == expected
    tart('stop', '--timeout', '10', VM)
  end

  def start_manager
    command('/bin/launchctl', 'asuser', @uid.to_s, '/bin/launchctl', 'bootstrap',
            "gui/#{@uid}", '/Library/LaunchAgents/com.afk.ci.tartelet.plist')
  end
end

if $PROGRAM_NAME == __FILE__
  abort 'root required' unless Process.uid.zero?
  user = ARGV.fetch(0)
  directory = '/Library/AFK-CI/runner-deploy/recovery'
  FileUtils.mkdir_p(directory, mode: 0700)
  File.open("#{directory}/lock", File::RDWR | File::CREAT, 0600) do |lock|
    exit 0 unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    state_path = "#{directory}/state.json"
    recovery = nil
    begin
      adapter = MacAdapter.new(user)
      state = File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {}
      recovery = RunnerRecovery.new(adapter, state)
      exit 0 unless recovery.session_ok?(Time.now.to_i) && adapter.ready?
      result = recovery.tick(Time.now.to_i)
      puts "#{Time.now.utc.iso8601} #{user} #{result}" if [:restarted, :changed_preserved].include?(result)
    rescue StandardError => error
      # Do not print command outputs, credentials, or exception payloads.
      warn "#{Time.now.utc} #{user} RECOVERY_DEFERRED #{error.class}"
    ensure
      if recovery
        recovery.notes.each { |note| puts "#{Time.now.utc.iso8601} #{user} #{note}" }
        temporary = state_path + '.new'
        File.write(temporary, JSON.generate(recovery.state), mode: 'w', perm: 0600)
        File.rename(temporary, state_path)
      end
    end
  end
end
