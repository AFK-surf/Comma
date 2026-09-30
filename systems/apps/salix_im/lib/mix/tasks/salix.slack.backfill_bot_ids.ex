defmodule Mix.Tasks.Salix.Slack.BackfillBotIds do
  use Mix.Task

  @shortdoc "Backfills stable Slack bot identities on OAuth-complete IM connects"

  @moduledoc """
  Scans one bounded page of Slack connects with an incomplete bot identity
  (`bot_id`, `bot_user_id`, or `bot_username`). Pass `--apply` to resolve each
  identity through Slack `auth.test` and persist it. When more connect records
  remain, pass the reported cursor to continue.

      mix salix.slack.backfill_bot_ids --limit 100
      mix salix.slack.backfill_bot_ids --apply --limit 100
      mix salix.slack.backfill_bot_ids --apply --limit 100 --cursor v1...

  The task is deliberately bounded and fails on the first provider or storage
  error so operators can correct drift before retrying.
  """

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [apply: :boolean, limit: :integer, cursor: :string])

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix salix.slack.backfill_bot_ids [--apply] [--limit N] [--cursor CURSOR]")
    end

    limit = Keyword.get(opts, :limit, 100)
    cursor = Keyword.get(opts, :cursor)

    if limit < 1 or limit > 1_000 do
      Mix.raise("--limit must be between 1 and 1000")
    end

    Mix.Task.run("app.start")

    case SalixIM.ProviderConnects.list_slack_bot_identity_backfill_candidates(limit, cursor) do
      {:ok, page} ->
        apply? = Keyword.get(opts, :apply, false)
        process_page(page, apply?, cursor, limit)

      {:error, reason} ->
        Mix.raise("Slack bot identity candidate scan failed: #{inspect(reason)}")
    end
  end

  defp process_page(page, true, cursor, limit) do
    Enum.each(page.candidates, &backfill!(&1, cursor, limit))

    Mix.shell().info(
      page_summary(
        "backfilled #{length(page.candidates)} Slack connect bot identities",
        page,
        :apply,
        limit
      )
    )
  end

  defp process_page(page, false, cursor, limit) do
    Enum.each(page.candidates, fn connect ->
      Mix.shell().info(
        "would backfill connect=#{connect["connect_id"]} workspace=#{connect["workspace_id"]}"
      )
    end)

    summary =
      "dry run: #{length(page.candidates)} need bot identity backfill in this page; " <>
        "rerun with --apply --limit #{limit}#{cursor_arg(cursor)} to apply this page"

    Mix.shell().info(page_summary(summary, page, :dry_run, limit))
  end

  defp page_summary(
         summary,
         %{scan_complete: true, scanned_count: scanned_count},
         _mode,
         _limit
       ) do
    "#{summary}; scanned #{scanned_count} records; scan complete"
  end

  defp page_summary(
         summary,
         %{next_cursor: next_cursor, scanned_count: scanned_count},
         mode,
         limit
       ) do
    continuation =
      case mode do
        :apply -> "continue with --apply --limit #{limit} --cursor #{next_cursor}"
        :dry_run -> "inspect the next page with --limit #{limit} --cursor #{next_cursor}"
      end

    "#{summary}; scanned #{scanned_count} records; scan incomplete, #{continuation}"
  end

  defp backfill!(connect, cursor, limit) do
    case SalixIM.ProviderHTTP.backfill_slack_bot_identity(connect) do
      {:ok, updated} ->
        Mix.shell().info(
          "backfilled connect=#{updated["connect_id"]} workspace=#{updated["workspace_id"]}"
        )

      {:error, reason} ->
        Mix.raise(
          "Slack bot identity backfill failed for #{connect["connect_id"]}: " <>
            "#{inspect(reason)}; retry this page with --apply --limit #{limit}#{cursor_arg(cursor)}"
        )
    end
  end

  defp cursor_arg(nil), do: ""
  defp cursor_arg(""), do: ""
  defp cursor_arg(cursor), do: " --cursor #{cursor}"
end
