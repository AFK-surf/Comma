defmodule SalixStore.QueueCase do
  @moduledoc """
  `use SalixStore.QueueCase, queues: [...]` in a test module, after its
  `use` of a case, for tests that take work from a queue of `SalixStore.Repo`:
  every test of the module starts with the named queues empty.

  `SalixStore.Repo` is not in the SQL sandbox, so a test sees the rows other
  suites wrote. A test that looks a row up by its id never meets them. A queue
  reader does: it claims the oldest pending row of the whole table, whoever
  wrote it. The queues are emptied while no other test runs, so the module is
  `async: false`: ExUnit runs such modules one at a time, after every
  asynchronous one has ended.

  The `queue-reader-without-queue-case` rule in `lint/rules` fails for a test
  file that calls a queue reader without this. Never started in production.
  """

  alias SalixStore.{Repo, RepoTestSetup}

  # A queue's tables: the one its reader claims from and those that refer to
  # its rows.
  @queues %{
    conversation_log_recovery: ~w(conversation_log_recovery),
    conversation_search_jobs: ~w(conversation_search_jobs),
    feishu_mirror_backfill: ~w(feishu_mirror_backfill_connects),
    feishu_mirror_outbox: ~w(feishu_mirror_outbox),
    lark_mirror_backfill: ~w(lark_mirror_backfill_connects),
    lark_mirror_outbox: ~w(lark_mirror_outbox),
    qq_mirror_outbox: ~w(qq_mirror_outbox),
    slack_mirror_backfill: ~w(slack_mirror_backfill_connects),
    slack_mirror_outbox: ~w(slack_mirror_outbox slack_mirror_source_writes),
    triage_patrol_cursors: ~w(triage_patrol_cursors),
    triage_product_effects:
      ~w(triage_product_effect_attempts triage_companion_reaction_obligations triage_product_obligations)
  }

  defmacro __using__(opts) do
    queues = Keyword.fetch!(opts, :queues)

    for queue <- queues, not is_map_key(@queues, queue) do
      raise ArgumentError,
            "unknown queue #{inspect(queue)}; SalixStore.QueueCase knows " <>
              inspect(Map.keys(@queues))
    end

    quote do
      @moduletag queues: unquote(queues)
      setup {SalixStore.QueueCase, :start_empty}
    end
  end

  @doc """
  The `setup` callback: empties the module's queues. It fails in an
  asynchronous module, and when a queue holds a row again right after it was
  emptied: a process of the node writes it beside the tests.
  """
  def start_empty(%{async: true, module: module}) do
    raise ArgumentError,
          "#{inspect(module)} empties queues of SalixStore.Repo, which every test of the node " <>
            "shares: make it `async: false`"
  end

  def start_empty(%{queues: queues}) do
    tables = Enum.flat_map(queues, &Map.fetch!(@queues, &1))

    # A queue no suite has written since it was last emptied stays as it is.
    if written(tables) != [] do
      # While this process owns every pooled connection (see
      # `SalixStore.RepoTestSetup.exclusively/1`).
      RepoTestSetup.exclusively(fn -> Repo.query!("TRUNCATE " <> Enum.join(tables, ", ")) end)

      case written(tables) do
        [] ->
          :ok

        again ->
          raise "#{Enum.join(again, ", ")} of SalixStore.Repo was written while the test " <>
                  "started: a process of the node fills this queue beside the tests " <>
                  "(see SystemsClock.NodeTimers)"
      end
    end

    :ok
  end

  # The tables among `tables` that hold a row.
  defp written(tables) do
    %{rows: rows} =
      tables
      |> Enum.map_join(" UNION ALL ", &"SELECT '#{&1}' WHERE EXISTS (SELECT 1 FROM #{&1})")
      |> Repo.query!()

    List.flatten(rows)
  end
end
