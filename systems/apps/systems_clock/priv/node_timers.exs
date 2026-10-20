# The services of the test node that hold a timer on SystemsClock, each with
# what its timer does there (`SystemsClock.NodeTimers`). They held one before
# the check existed. The list only loses entries: a service is taken out when
# the test configuration stops starting it or it stops arming a timer. A new
# worker gets a switch in config/test.exs, never a line here: the Determinism
# workflow (`scripts/determinism.sh check`) fails for one. Keep each entry on
# a line of its own, `Service => "what its timer does"`.
%{
  # --- Timed work that changes nothing a test reads -------------------------

  # Sweeps of entries that have already expired. A read takes an expired entry
  # as absent, so a sweep changes no answer.
  BridgeForTeams.Cache => "every minute, deletes cache entries past their expiry",
  BridgeForTeams.Salix.ReadCache => "every minute, deletes cache entries past their expiry",
  Salix.Control.PluginCatalogCache => "every minute, deletes catalogs past their expiry",
  SalixEnv.Transfer.Tokens => "every 30 s, deletes transfer tokens past their expiry",
  SalixWeb.SiteAPI.State =>
    "every 5 minutes, deletes site configurations fetched over 2 minutes ago; a read uses one for 5 s",

  # Gauges of the node's own tables.
  SalixAgent.RouterRequestMonitor => "every 15 s, publishes a gauge of the requests it has seen",
  SalixStore.Inflight.Poller => "every 10 s, publishes the in-flight gauges",
  SalixAgent.SessionResidency =>
    "every hour, samples the fixed healthy node of the test configuration: no pressure, no eviction",

  # Reads only.
  SalixMeet.MeetingGroupProjectionAuditor =>
    "every 5 minutes, reads one page of the bucket and of the projection and reports drift",

  # First due after any run has ended: no BEAM test process lasts an hour
  # (a CI job is stopped after 10 minutes).
  BridgeForTeams.Observability.Pruner => "prunes 24 hours after the node starts",
  SalixStore.SlackRouterThreadParticipationSweeper => "sweeps an hour after the node starts",
  SalixStore.AgentVMMSettlementSweeper =>
    "one pass as the node starts, before any test, then every hour (agent_vmm_settlement_sweep_interval_ms)",

  # Each reads one cutover marker every second until it is there, then arms no
  # more. SalixStore.RepoTestSetup seeds the markers before the first test of
  # a new database; a check changes only the answer of its own ready?/0.
  SalixStore.MeetingGroupProjectionReadiness => "rereads its marker until it is present",
  SalixStore.OAuthAppsReadiness => "rereads its marker until it is present",
  SalixStore.ProviderCredentialsReadiness => "rereads its marker until it is present",
  SalixStore.SchedulesReadiness => "rereads its marker until it is present",
  SalixStore.TenantApiKeyReadiness => "rereads its marker until it is present",
  SalixStore.TenantConfigsReadiness => "rereads its marker until it is present",

  # A timer per request: armed for the caller that asked, about its own
  # request, and none while nothing asks.
  BillingCore.FeeControl.Server =>
    "the deadline of a fee check, cancelled when the check answers",
  SalixAgent.Decide.Limits =>
    "the end of the rate window of the Tenant and Group that just called",
  SalixAgent.DependencyRunner => "the deadline of a dependency job it started",
  SalixAgent.SubscriptionWorker => "the deadline of a subscription request",
  SalixStore.S3.Fake => "the delay a test scripted for one request",
  SalixAgent.Loops.Reconciler =>
    "the deadline of a call to the Loops host while it adopts the Loops of an Agent",
  SalixAgent.Loops.Host =>
    "the deadline of a request to its child process, and the wait before it starts the child again",
  SalixWeb.ConnectorDisconnectQueue =>
    "the deadline and the retry of a disconnect a socket submitted",

  # --- Timed work on what tests write ---------------------------------------

  # Flush the node's analytics buffers to their sink every second. The
  # product reaches both workers by name, to insert and to enqueue, so they
  # run on the test node, and their fixed-size buffers must be emptied:
  # without the flush they fill, and later rows are dropped. A test that
  # asserts on a flush starts its own worker (config/test.exs,
  # typed_sink_flush_ms).
  SalixAnalytics.TypedSinkWorker => "every second, flushes the buffered analytics rows",
  SalixAnalytics.AgentObservabilitySinkWorker =>
    "every second, flushes the buffered observability rows"
}
