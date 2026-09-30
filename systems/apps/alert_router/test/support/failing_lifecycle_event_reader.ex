defmodule AlertRouter.FailingLifecycleEventReader do
  @moduledoc false

  @behaviour AlertRouter.LifecycleEventReader

  @impl true
  def for_revision(_incident_key, _target_revision) do
    raise "injected lifecycle snapshot read failure"
  end
end
