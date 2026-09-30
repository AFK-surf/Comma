defmodule AlertRouter.LifecycleEventReader do
  @moduledoc "Reads the immutable lifecycle snapshot rendered by a root delivery grant."

  alias AlertRouter.Data.EventRecord

  @callback for_revision(String.t(), pos_integer()) :: [EventRecord.t()]
end

defmodule AlertRouter.LifecycleEventReader.Repo do
  @moduledoc false

  @behaviour AlertRouter.LifecycleEventReader

  import Ecto.Query

  alias AlertRouter.Data.EventRecord
  alias AlertRouter.Repo, as: AlertRepo

  @impl true
  def for_revision(incident_key, target_revision) do
    AlertRepo.all(
      from(event in EventRecord,
        where:
          event.incident_key == ^incident_key and event.disposition == "accepted" and
            event.timeline_state != "skipped" and not is_nil(event.render_revision) and
            event.render_revision <= ^target_revision,
        order_by: [asc: event.render_revision, asc: event.inserted_at, asc: event.event_id]
      )
    )
  end
end
