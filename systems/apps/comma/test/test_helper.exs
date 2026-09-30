ExUnit.start(exclude: [:release_controller_e2e])

# The release plan audits the salix control repo's migration ledger; bring up
# the shared salix_store test database (docs/storage-search.md).
SalixStore.RepoTestSetup.ensure!()
