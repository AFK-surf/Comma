# Splits BEAM test files across `mix test` processes by recorded duration.
#
#   elixir scripts/ci/beam_test_shard.exs INDEX COUNT TEST_DIR...
#
# Prints the test files of shard INDEX (1-based) out of COUNT, one per line.
# Every test file under the given directories belongs to exactly one
# shard. Files are placed longest first
# on the least-loaded shard, weighted by
# `beam_test_timings.json`; a file without a recorded duration weighs
# @default_seconds. Stale timings only affect balance, never coverage.
#
# Mix's own `--partitions` deals sorted files round-robin, which puts several
# multi-minute modules on the same process; this keeps the slowest process
# close to the average instead.
#
# Plan the BEAM test jobs for a change:
#
#   elixir scripts/ci/beam_test_shard.exs --plan CHANGED_FILES|--full
#
# CHANGED_FILES lists repository paths, one per line. A path under
# systems/apps/APP selects APP alone: the apps that depend on it run on main,
# which always plans `--full`. Markdown files and paths outside systems/ that
# the BEAM tests do not read (clients, other workflows, docs) select nothing.
# Any other path selects every app. Prints the GitHub Actions matrix as JSON.
# The selected apps' recorded test time decides the number of jobs: one per
# @max_partitions processes of @target_seconds each. A job costs its setup
# whatever it runs, so the shards fill whole jobs: every group of selected
# apps gets one, and the rest go to the groups with the most time per shard,
# up to one shard per @target_seconds of a group. A shard holds files of one
# group only, so the apps that share a `mix test` VM are the apps that always
# ran together. Each job runs up to @max_partitions shards as concurrent
# `mix test` processes (MIX_TEST_PARTITION 1..N) on one runner, and lasts as
# long as its longest one: a job takes shards of about the same recorded
# time. `shards` lists each process's `INDEX COUNT TEST_DIR...` arguments,
# separated by `;`.
#
# Refresh the timings from the logs of any Systems CI test-beam run:
# SystemsClock.Formatter prints each test file's duration as
# `beam-test-file apps/APP/test/FILE SECONDS`. Durations are measured as the
# jobs run them, concurrent processes on a shared node, so @target_seconds is
# wall time a process spends on its files. Files absent from the logs keep their
# recorded durations:
#
#   elixir scripts/ci/beam_test_shard.exs --timings JOB_LOG...
defmodule BeamTestShard do
  @timings_path Path.join(__DIR__, "beam_test_timings.json")
  @default_seconds 1.0
  @target_seconds 90
  @max_partitions 12
  @systems_dir Path.expand("../..", __DIR__)
  @apps_dir Path.expand("../../apps", __DIR__)
  # Paths outside an umbrella app that can change a BEAM test result: the rest
  # of systems/, the build and CI inputs of the BEAM jobs, and Storage's MinIO.
  @beam_inputs ~r{^(systems/|\.github/actions/|\.github/scripts/|\.github/workflows/systems-ci\.yml$|scripts/(checkout-pvg|synch-lock)\.sh$|selfhost/Storage\.Dockerfile$|Makefile$)}

  @groups [
    {"salix-runtime-a", ~w(salix_ifc salix_store salix_agent salix_cluster)},
    {"salix-runtime-b",
     ~w(salix_calendar salix_env salix_media salix_im salix_analytics salix_migrate salix_llm
        salix_meet salix_meet_native salix_voice salix_signal_proto salix_signal salix_mcp)},
    {"salix-web", ~w(salix_web)},
    {"product-comma",
     ~w(systems_observability comma comma_log alert_router billing_core comma_core comma_tui
        comma_ssh billing_commerce billing_stripe comma_web systems_clock systems_runtime systems_sim)},
    {"product-bft", ~w(bridge_for_teams_core bridge_for_teams_web)}
  ]

  def main(["--plan", "--full"]), do: plan(:all)

  def main(["--plan", changed_files]) do
    changed_files
    |> File.read!()
    |> String.split("\n", trim: true)
    |> selected_apps()
    |> plan()
  end

  def main(["--timings" | logs]) when logs != [] do
    recorded =
      logs
      |> Enum.flat_map(&module_durations/1)
      |> Enum.reduce(%{}, fn {file, seconds}, acc ->
        Map.update(acc, file, seconds, &(&1 + seconds))
      end)

    timings = Map.merge(recorded_timings(), recorded)

    body =
      timings
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {file, seconds} ->
        ~s(  "#{file}": #{Float.round(seconds, 1)})
      end)

    File.write!(@timings_path, "{\n" <> body <> "\n}\n")
    IO.puts("Recorded #{map_size(recorded)} test files in #{@timings_path}")
  end

  def main([index, count | dirs]) when dirs != [] do
    {index, ""} = Integer.parse(index)
    {count, ""} = Integer.parse(count)

    unless index in 1..count//1 do
      raise ArgumentError, "shard index #{index} is outside 1..#{count}"
    end

    files = native_files(dirs)

    if files == [] do
      raise ArgumentError, "no test files under #{Enum.join(dirs, " ")}"
    end

    shard =
      files
      |> assign(count, recorded_timings())
      |> Map.fetch!(index)

    # An empty file list would make `mix test` run every test path.
    if shard == [] do
      raise ArgumentError, "shard #{index}/#{count} is empty; lower the shard count"
    end

    shard |> Enum.sort() |> Enum.each(&IO.puts/1)
  end

  def main(_args) do
    IO.puts(
      :stderr,
      "usage: beam_test_shard.exs INDEX COUNT TEST_DIR... | --plan CHANGED_FILES|--full | --timings JOB_LOG..."
    )

    System.halt(2)
  end

  defp plan(selection) do
    tested = tested_apps()
    grouped = @groups |> Enum.flat_map(fn {_, apps} -> apps end) |> MapSet.new()

    case MapSet.difference(tested, grouped) |> Enum.sort() do
      [] ->
        :ok

      missing ->
        raise ArgumentError, "apps with tests but no BEAM group: #{Enum.join(missing, ", ")}"
    end

    apps = if selection == :all, do: tested, else: MapSet.intersection(selection, tested)
    timings = recorded_timings()

    groups =
      for {group, group_apps} <- @groups,
          dirs = for(app <- group_apps, app in apps, do: "apps/#{app}/test"),
          files = native_files(dirs),
          files != [] do
        load = files |> Enum.map(&Map.get(timings, &1, @default_seconds)) |> Enum.sum()
        most = min(length(files), max(1, ceil(load / @target_seconds)))
        %{group: group, dirs: dirs, files: length(files), load: load, most: most, count: 1}
      end

    total = groups |> Enum.map(& &1.load) |> Enum.sum()
    processes = max(1, ceil(total / (@target_seconds * @max_partitions))) * @max_partitions

    shards =
      groups
      |> fill(processes)
      |> Enum.sort_by(&(-&1.load / &1.count))
      |> Enum.flat_map(fn %{group: group, dirs: dirs, files: files, load: load, count: count} ->
        IO.puts(:stderr, "#{group}: #{files} files, #{round(load)}s in #{count} shard(s)")
        for index <- 1..count, do: Enum.join([index, count | dirs], " ")
      end)

    include =
      case shards do
        [] ->
          []

        shards ->
          jobs = ceil(length(shards) / @max_partitions)

          shards
          |> even_chunks(jobs)
          |> Enum.with_index(1)
          |> Enum.map(fn {job_shards, index} ->
            %{
              index: index,
              count: jobs,
              partitions: length(job_shards),
              runner: runner(length(job_shards)),
              shards: Enum.join(job_shards, ";")
            }
          end)
      end

    IO.puts(JSON.encode!(%{include: include}))
  end

  defp native_files(dirs) do
    dirs
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*_test.exs")))
    |> Enum.uniq()
  end

  # Gives the groups shards up to `processes` in all: the next one to the
  # group with the most recorded time per shard that may still take one.
  defp fill(groups, processes) do
    open = Enum.filter(groups, &(&1.count < &1.most))

    if open == [] or Enum.sum(Enum.map(groups, & &1.count)) >= processes do
      groups
    else
      next = Enum.max_by(open, &(&1.load / &1.count))

      groups
      |> Enum.map(&if(&1.group == next.group, do: %{&1 | count: &1.count + 1}, else: &1))
      |> fill(processes)
    end
  end

  # `list` in `count` consecutive chunks whose sizes differ by at most one.
  defp even_chunks(list, count) do
    {base, extra} = {div(length(list), count), rem(length(list), count)}

    {chunks, []} =
      Enum.map_reduce(0..(count - 1)//1, list, fn index, rest ->
        Enum.split(rest, base + if(index < extra, do: 1, else: 0))
      end)

    chunks
  end

  # The office ARM64 runners: a 2-CPU pod for up to two `mix test`
  # processes, a 4-CPU pod for up to five, an 8-CPU pod for more. The
  # processes keep every CPU busy: on 2026-10-14 the whole suite took 4.7
  # minutes as 5 processes on 4 CPUs and 2.6 minutes as 12 on 8.
  defp runner(partitions) when partitions <= 2, do: "pvg-linux-arm64"
  defp runner(partitions) when partitions <= 5, do: "pvg-linux-arm64-4c"
  defp runner(_partitions), do: "pvg-linux-arm64-8c"

  defp tested_apps do
    @apps_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join([@apps_dir, &1, "test"])))
    |> MapSet.new()
  end

  defp selected_apps(paths) do
    Enum.reduce_while(paths, MapSet.new(), fn path, acc ->
      cond do
        String.ends_with?(path, ".md") ->
          {:cont, acc}

        # An app's tests run alone; its code also runs the tests of every app
        # that depends on it.
        match = Regex.run(~r{^systems/apps/([^/]+)/(test/)?}, path) ->
          case match do
            [_, app, "test/"] -> {:cont, MapSet.put(acc, app)}
            [_, app | _] -> {:cont, MapSet.union(acc, with_dependents(app))}
          end

        not Regex.match?(@beam_inputs, path) ->
          {:cont, acc}

        true ->
          IO.puts(:stderr, "#{path} is outside an umbrella app: running every app")
          {:halt, :all}
      end
    end)
  end

  # `app` and every app that depends on it, directly or through others.
  defp with_dependents(app) do
    dependents =
      for dir <- File.ls!(@apps_dir),
          mix = Path.join([@apps_dir, dir, "mix.exs"]),
          File.exists?(mix),
          [_, dep] <- Regex.scan(~r/\{:(\w+),\s*in_umbrella: true/, File.read!(mix)),
          reduce: %{} do
        acc -> Map.update(acc, dep, [dir], &[dir | &1])
      end

    Stream.iterate({MapSet.new([app]), [app]}, fn {seen, frontier} ->
      next = for a <- frontier, d <- Map.get(dependents, a, []), d not in seen, uniq: true, do: d
      {MapSet.union(seen, MapSet.new(next)), next}
    end)
    |> Enum.find(fn {_seen, frontier} -> frontier == [] end)
    |> elem(0)
  end

  defp assign(files, count, timings) do
    bins = Map.new(1..count, &{&1, {0.0, []}})

    files
    |> Enum.map(&{Map.get(timings, &1, @default_seconds), &1})
    |> Enum.sort_by(fn {seconds, file} -> {-seconds, file} end)
    |> Enum.reduce(bins, fn {seconds, file}, bins ->
      {index, {load, members}} = Enum.min_by(bins, fn {index, {load, _}} -> {load, index} end)
      Map.put(bins, index, {load + seconds, [file | members]})
    end)
    |> Map.new(fn {index, {_load, members}} -> {index, members} end)
  end

  defp recorded_timings do
    if File.exists?(@timings_path), do: @timings_path |> File.read!() |> JSON.decode!(), else: %{}
  end

  # SystemsClock.Formatter's `beam-test-file apps/APP/test/FILE SECONDS`.
  defp module_durations(log) do
    log
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/beam-test-file (apps\/\S+_test\.exs) ([\d.]+)\s*$/, line) do
        [_, file, seconds] -> [{file, elem(Float.parse(seconds), 0)}]
        nil -> []
      end
    end)
  end
end

BeamTestShard.main(System.argv())
