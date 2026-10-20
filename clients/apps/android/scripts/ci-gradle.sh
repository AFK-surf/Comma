#!/usr/bin/env bash
# Runs Gradle on Linux CI. If memory or disk runs low, it prints the largest
# processes and stops the build, so the job fails with a log instead of the
# runner losing contact with GitHub and taking the log with it.
set -euo pipefail

min_memory_mb=2048
min_disk_mb=2048

report() {
  free -m
  df -h .
  echo "Threads: $(ps -eLo pid --no-headers | wc -l)"
  ps -eo pid,rss,nlwp,etime,args --sort=-rss | head -15 | cut -c1-200
}

# The SDK comes whole from .github/actions/setup-android: a package Gradle
# would download mid-build (minutes from Google, on every run) fails instead.
gradle_args=(--no-daemon --max-workers=2 --console=plain --build-cache -Pandroid.builder.sdkDownload=false)

# The watch reads Linux's /proc; elsewhere (the macOS unit test runner) Gradle
# runs unwatched.
if [[ "$(uname)" != Linux ]]; then
  exec ./gradlew "${gradle_args[@]}" "$@"
fi

setsid ./gradlew "${gradle_args[@]}" "$@" &
gradle=$!
seconds=0
while kill -0 "$gradle" 2>/dev/null; do
  sleep 2
  seconds=$((seconds + 2))
  memory=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
  # In a container the cgroup limit, not the host's free memory, is what
  # runs out. Its inactive page cache is reclaimable, as in MemAvailable.
  if [[ -r /sys/fs/cgroup/memory.max && "$(< /sys/fs/cgroup/memory.max)" != max ]]; then
    inactive=$(awk '/^inactive_file / { print $2 }' /sys/fs/cgroup/memory.stat)
    limit=$((($(< /sys/fs/cgroup/memory.max) - $(< /sys/fs/cgroup/memory.current) + inactive) / 1048576))
    if ((limit < memory)); then memory=$limit; fi
  fi
  disk=$(df -Pm . | awk 'NR == 2 { print $4 }')
  if ((seconds % 60 == 0)); then
    echo "[ci-gradle] ${seconds}s: ${memory} MB memory and ${disk} MB disk available"
  fi
  if ((memory < min_memory_mb || disk < min_disk_mb)); then
    echo "::error::Stopping Gradle: ${memory} MB memory and ${disk} MB disk available."
    report
    # Gradle, its test workers and the Kotlin daemon are this job's only Java processes.
    kill -KILL -- "-$gradle" 2>/dev/null || true
    pkill -KILL java || true
    exit 1
  fi
done
wait "$gradle"
