defmodule BridgeForTeams.Repo do
  @moduledoc """
  The BridgeForTeams Ecto repo (Postgres). System of record for the commercial
  domain (design §1, §5). First Ecto user in the umbrella.

  Configured per OTP app `:bridge_for_teams_core` (see `config/*.exs`). Started in
  `BridgeForTeams.Application`'s supervision tree.
  """
  use Ecto.Repo,
    otp_app: :bridge_for_teams_core,
    adapter: Ecto.Adapters.Postgres
end
