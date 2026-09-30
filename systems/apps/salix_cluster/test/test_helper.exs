# The :multinode tests require BEAM distribution (epmd + a peer node). Exclude
# them from the default run; opt in with `mix test --include multinode`.
ExUnit.start(exclude: [:multinode])

# Control-plane Postgres: schedules live in SalixStore.Repo
# (docs/storage-search.md).
SalixStore.RepoTestSetup.ensure!()
