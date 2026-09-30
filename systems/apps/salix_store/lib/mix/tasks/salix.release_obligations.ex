defmodule Mix.Tasks.Salix.ReleaseObligations do
  @shortdoc "Run one bounded allocation-release backfill or audit page"

  @moduledoc """
  Runs one keyset-bounded rollout page for allocation-owned release obligations.

      mix salix.release_obligations --mode backfill --limit 100
      mix salix.release_obligations --mode audit --after ALLOCATION_ID --limit 100

  Repeat with the returned cursor until `done` is true. A rollout is complete
  only after an audit pass reaches `done` with zero issues across every page.
  This task is an operator-invoked rollout step; no timer starts it at runtime.
  """

  use Mix.Task

  alias SalixStore.ReleaseObligationBackfill

  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [mode: :string, after: :string, limit: :integer]
      )

    if rest != [] or invalid != [], do: usage!()

    mode = Keyword.get(opts, :mode)
    after_id = Keyword.get(opts, :after)
    limit = Keyword.get(opts, :limit, 100)

    if mode not in ["backfill", "audit"] or limit not in 1..500, do: usage!()

    {:ok, _started} = Application.ensure_all_started(:salix_store)

    result =
      case mode do
        "backfill" -> ReleaseObligationBackfill.backfill_page(after_id, limit)
        "audit" -> ReleaseObligationBackfill.audit_page(after_id, limit)
      end

    Mix.shell().info(Jason.encode!(result))

    if result.issues != [], do: Mix.raise("release-obligation #{mode} found actionable issues")
  end

  defp usage! do
    Mix.raise("expected --mode backfill|audit [--after ALLOCATION_ID] [--limit 1..500]")
  end
end
