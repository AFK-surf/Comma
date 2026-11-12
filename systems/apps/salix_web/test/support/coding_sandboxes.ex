defmodule SalixWeb.TestSupport.CodingSandboxes do
  @moduledoc """
  The coding sandboxes earlier tests left in the shared test database.

  Tests do not empty the database between them, and
  `SalixWeb.CodingSandboxes.check_due/0` takes a page of the due sandboxes
  across every Group. A sandbox an earlier test left becomes due once the
  clock passes its next check, and its check then runs against this test's
  fakes (its Station, its L4ES stub). A test that calls `check_due/0` calls
  `park_left!/0` in its `setup` first.
  """

  import Ecto.Query, only: [from: 2]

  @doc "Makes every coding sandbox in the database never due again."
  def park_left! do
    SalixStore.Repo.update_all(
      from(w in SalixStore.Compute.Workload,
        where: w.kind == ^SalixStore.CodingSandboxes.kind(),
        update: [
          set: [
            spec:
              fragment(
                "jsonb_set(?, '{next_check_at}', to_jsonb('9999-12-31T00:00:00Z'::text))",
                w.spec
              )
          ]
        ]
      ),
      []
    )

    :ok
  end
end
