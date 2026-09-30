defmodule Comma.Repo.Migrations.AddClientPlatformToAuthSessions do
  use Ecto.Migration

  @moduledoc """
  Stores the finite client platform enum the client already reports at login
  (`SessionClientMetadata`) next to the derived `device_label`, so product
  surfaces can show where a request came from without parsing a label string.
  Display-only: never an authentication factor.
  """

  def change do
    alter table(:comma_auth_sessions) do
      add(:client_platform, :string)
    end
  end
end
