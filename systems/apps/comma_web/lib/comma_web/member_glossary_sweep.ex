defmodule CommaWeb.MemberGlossarySweep do
  @moduledoc """
  Daily cron: queues today's glossary refresh (`CommaWeb.MemberGlossary`) of
  every active standard Workspace whose owner used Comma in the last 24 hours
  (an auth session seen since then), so a Workspace without source
  collections is refreshed too. The refreshes queued are at most the daily
  active owners.

  One job reads one page of 500 Workspaces by id, looks up which of their
  owners have a session seen since then through the `(user_id, last_seen_at)`
  index, and queues the next page, so each job is bounded however many
  Workspaces exist. A refresh the
  portrait's collection queued the same day absorbs the sweep's.
  """
  use Oban.Worker, queue: :comma_external, max_attempts: 3

  import Ecto.Query
  alias Comma.Accounts.AuthSession
  alias Comma.Data.Workspace
  alias Comma.Repo

  @page 500

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    after_id = args["after"] || ""
    since = DateTime.add(SystemsClock.utc_now(), -86_400, :second)

    page =
      Repo.all(
        from(w in Workspace,
          where: w.status == "active" and w.kind == "standard" and w.id > ^after_id,
          order_by: [asc: w.id],
          select: {w.id, w.owner_user_id},
          limit: @page
        )
      )

    owners = page |> Enum.map(&elem(&1, 1)) |> Enum.filter(&is_binary/1) |> Enum.uniq()

    active =
      Repo.all(
        from(s in AuthSession,
          where: s.user_id in ^owners and s.last_seen_at >= ^since,
          distinct: true,
          select: s.user_id
        )
      )
      |> MapSet.new()

    for {id, owner} <- page,
        MapSet.member?(active, owner),
        do: CommaWeb.MemberGlossary.enqueue(id)

    if length(page) == @page,
      do:
        %{"after" => page |> List.last() |> elem(0)}
        |> new()
        |> then(&Oban.insert(Comma.Oban, &1))

    :ok
  end
end
