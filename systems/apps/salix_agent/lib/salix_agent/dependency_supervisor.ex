defmodule SalixAgent.DependencySupervisor do
  @moduledoc """
  Lifecycle cohort for dependency admission and its dynamic tasks.

  Admission owns the only authoritative global/per-tenant counts. Keeping it
  in a `:one_for_all` group with `DependencyTaskSup` guarantees that an
  admission crash terminates every previously admitted task before an empty
  admission process can accept replacements. A task-supervisor crash likewise
  discards admission state that refers to children which no longer exist.

  Modeled in `tla/salix/DependencyJob.tla`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Task.Supervisor, name: SalixAgent.DependencyTaskSup},
        SalixAgent.DependencyAdmission
      ],
      strategy: :one_for_all
    )
  end
end
