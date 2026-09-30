defmodule Comma.Repo.Migrations.RetireCommaConversationState do
  use Ecto.Migration

  @moduledoc """
  Records the application-level retirement of Comma-owned conversation state.

  The obsolete tables and queued rows deliberately remain untouched in this
  rolling release. Older instances can still be alive while migrations run;
  deleting their tables or jobs here would violate mixed-version safety. The
  new application has no schemas, workers, routes, or read/write paths for
  this state. Physical cleanup belongs to a later contract release after the
  old writer version is proven absent.
  """

  def change do
    :ok
  end
end
