defmodule Mix.Tasks.SalixMeet.GroupProjection.Audit do
  @moduledoc """
  Runs the read-only exact audit for the sealed meeting group projection.

  Repair remains owned by a newly versioned online release migration after the
  projection-first rollout barrier; this task intentionally cannot mutate or
  seal the projection.
  """
  use Mix.Task

  alias SalixMeet.Release

  @shortdoc "Audit the sealed meeting group projection without repairing it"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Release.audit_group_projection() do
      :ok -> Mix.shell().info("meeting group projection audit passed")
      {:error, reason} -> Mix.raise("meeting group projection audit failed: #{inspect(reason)}")
    end
  end
end
