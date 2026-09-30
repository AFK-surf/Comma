ExUnit.start()

# Provider and Triage tests use the shared SalixStore projections and expect
# the steady-state cutover markers. Bring up the suite's database explicitly so
# a standalone salix_im run has the same migrated baseline as the umbrella run.
SalixStore.RepoTestSetup.ensure!()
