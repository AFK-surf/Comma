defmodule SalixStore.Repo.Migrations.IndexPendingLocationRequests do
  @moduledoc """
  A person's open phone reads the pending location requests their own messages
  led to, across every Group (`SalixAgent.CapabilityRequests.pending_location_requests/2`).
  This partial index keeps that read to those rows.
  """
  use Ecto.Migration

  def change do
    create(
      index(:salix_capability_requests, ["(surface_ref->>'requester')"],
        name: :salix_capability_requests_location_requester,
        where: "request_type = 'location' AND status = 'pending'"
      )
    )
  end
end
