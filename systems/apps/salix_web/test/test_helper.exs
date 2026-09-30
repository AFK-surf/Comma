# The :multinode tests require BEAM distribution (epmd + a peer node) plus a
# real connector subprocess; exclude them from the default run and opt in with
# `mix test --include multinode`. The :comma_voice_cli test builds the Go
# `comma-voice` CLI; opt in with `mix test --include comma_voice_cli`.
ExUnit.start(exclude: [:multinode, :comma_voice_cli])

# Tenant API keys are Postgres-backed (docs/storage-search.md);
# bring up the shared test repo before the suite boots the apps.
SalixStore.RepoTestSetup.ensure!()
