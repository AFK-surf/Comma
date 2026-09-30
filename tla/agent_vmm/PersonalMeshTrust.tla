---- MODULE PersonalMeshTrust ----
EXTENDS FiniteSets, Naturals, TLC

CONSTANTS Devices, Genesis, MaxRevision, EnableRevokes, EnablePairingAbort,
          UnsafeRejoin, UnsafeRouteReplay, UnsafePairingBypass

VARIABLES active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
          replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
          routeRequests, routeIssuances, activeRoutes, pairing, pakeConfirmed

vars == <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
          replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
          routeRequests, routeIssuances, activeRoutes, pairing, pakeConfirmed>>

DevicePairs == Devices \X Devices
PairStates == {"idle", "invited", "pake", "confirmed", "proposal", "manager_ok", "both_ok", "committed"}

Init ==
  /\ active = {Genesis}
  /\ managers = {Genesis}
  /\ tombstones = {}
  /\ revokedEver = {}
  /\ invites = {}
  /\ revision = 1
  /\ policyEpoch = 1
  /\ replicas = [d \in Devices |-> IF d = Genesis THEN {Genesis} ELSE {}]
  /\ replicaRevision = [d \in Devices |-> IF d = Genesis THEN 1 ELSE 0]
  /\ pendingRevokes = {}
  /\ registryCommitted = {}
  /\ localDenied = {}
  /\ routeRequests = {}
  /\ routeIssuances = {}
  /\ activeRoutes = {}
  /\ pairing = [d \in Devices |-> IF d = Genesis THEN "committed" ELSE "idle"]
  /\ pakeConfirmed = {}

IssueInvite(manager, subject) ==
  /\ manager \in managers /\ subject \in Devices \ active
  /\ (subject \notin tombstones \/ UnsafeRejoin) /\ subject \notin invites
  /\ pairing[subject] = "idle"
  /\ invites' = invites \union {subject}
  /\ pairing' = [pairing EXCEPT ![subject] = "invited"]
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, revision, policyEpoch,
                  replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pakeConfirmed>>

BeginPairing(subject) ==
  /\ subject \in invites /\ pairing[subject] = "invited"
  /\ pairing' = [pairing EXCEPT ![subject] = "pake"]
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
                  replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pakeConfirmed>>

ConfirmPAKE(subject) ==
  /\ pairing[subject] = "pake"
  /\ pairing' = [pairing EXCEPT ![subject] = "confirmed"]
  /\ pakeConfirmed' = pakeConfirmed \union {subject}
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
                  replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes>>

AcceptEncryptedProposal(subject) ==
  /\ pairing[subject] = "confirmed" \/ (UnsafePairingBypass /\ pairing[subject] = "pake")
  /\ pairing' = [pairing EXCEPT ![subject] = "proposal"]
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
                  replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pakeConfirmed>>

ManagerConfirm(subject) ==
  /\ pairing[subject] = "proposal"
  /\ pairing' = [pairing EXCEPT ![subject] = "manager_ok"]
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
                  replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pakeConfirmed>>

JoinerConfirm(subject) ==
  /\ pairing[subject] = "manager_ok"
  /\ pairing' = [pairing EXCEPT ![subject] = "both_ok"]
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
                  replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pakeConfirmed>>

AbortPairing(subject) ==
  /\ EnablePairingAbort /\ subject \notin active
  /\ pairing[subject] \in {"invited", "pake", "confirmed", "proposal", "manager_ok", "both_ok"}
  /\ pairing' = [pairing EXCEPT ![subject] = "idle"]
  /\ pakeConfirmed' = pakeConfirmed \ {subject}
  /\ invites' = invites \ {subject}
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, revision, policyEpoch,
                  replicas, replicaRevision, pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes>>

CommitJoin(subject) ==
  /\ subject \in invites /\ pairing[subject] = "both_ok"
  /\ revision < MaxRevision
  /\ (subject \notin tombstones \/ UnsafeRejoin)
  /\ active' = active \union {subject}
  /\ managers' = managers \union {subject}
  /\ invites' = invites \ {subject}
  /\ tombstones' = IF UnsafeRejoin THEN tombstones \ {subject} ELSE tombstones
  /\ revision' = revision + 1
  /\ pairing' = [pairing EXCEPT ![subject] = "committed"]
  /\ UNCHANGED <<revokedEver, policyEpoch, replicas, replicaRevision,
                  pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pakeConfirmed>>

RequestRoute(source, destination) ==
  /\ source \in active /\ destination \in active /\ source # destination
  /\ source \notin localDenied /\ destination \notin localDenied
  /\ <<source, destination>> \notin routeRequests
  /\ routeRequests' = routeRequests \union {<<source, destination>>}
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision,
                  policyEpoch, replicas, replicaRevision, pendingRevokes,
                  registryCommitted, localDenied, routeIssuances, activeRoutes,
                  pairing, pakeConfirmed>>

IssueRoute(source, destination) ==
  /\ <<source, destination>> \in routeRequests
  /\ source \in active /\ destination \in active
  /\ source \notin localDenied /\ destination \notin localDenied
  /\ routeIssuances' = routeIssuances \union {<<source, destination>>}
  /\ activeRoutes' = activeRoutes \union {<<source, destination>>}
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision,
                  policyEpoch, replicas, replicaRevision, pendingRevokes,
                  registryCommitted, localDenied, routeRequests, pairing, pakeConfirmed>>

RetryIssuedRoute(source, destination) ==
  /\ <<source, destination>> \in routeIssuances
  /\ <<source, destination>> \notin activeRoutes
  /\ (UnsafeRouteReplay \/
       /\ source \in active /\ destination \in active
       /\ source \notin localDenied /\ destination \notin localDenied)
  /\ activeRoutes' = activeRoutes \union {<<source, destination>>}
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision,
                  policyEpoch, replicas, replicaRevision, pendingRevokes,
                  registryCommitted, localDenied, routeRequests, routeIssuances,
                  pairing, pakeConfirmed>>

BeginRevoke(manager, subject) ==
  /\ EnableRevokes /\ manager \in managers /\ subject \in active
  /\ subject # Genesis /\ manager # subject
  /\ subject \notin pendingRevokes /\ subject \notin registryCommitted
  /\ pendingRevokes' = pendingRevokes \union {subject}
  /\ localDenied' = localDenied \union {subject}
  /\ activeRoutes' = {pair \in activeRoutes : pair[1] # subject /\ pair[2] # subject}
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision,
                  policyEpoch, replicas, replicaRevision, registryCommitted,
                  routeRequests, routeIssuances, pairing, pakeConfirmed>>

RegistryCommitRevoke(subject) ==
  /\ subject \in pendingRevokes /\ subject \notin registryCommitted
  /\ revision < MaxRevision
  /\ active' = active \ {subject}
  /\ managers' = managers \ {subject}
  /\ tombstones' = tombstones \union {subject}
  /\ revokedEver' = revokedEver \union {subject}
  /\ invites' = invites \ {subject}
  /\ revision' = revision + 1
  /\ policyEpoch' = policyEpoch + 1
  /\ registryCommitted' = registryCommitted \union {subject}
  /\ pairing' = IF UnsafeRejoin
                THEN [pairing EXCEPT ![subject] = "idle"]
                ELSE pairing
  /\ UNCHANGED <<replicas, replicaRevision, pendingRevokes, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pakeConfirmed>>

ApplyRevokeReceipt(subject) ==
  /\ subject \in pendingRevokes /\ subject \in registryCommitted
  /\ pendingRevokes' = pendingRevokes \ {subject}
  /\ localDenied' = localDenied \ {subject}
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision,
                  policyEpoch, replicas, replicaRevision, registryCommitted,
                  routeRequests, routeIssuances, activeRoutes, pairing, pakeConfirmed>>

Sync(device) ==
  /\ device \in active
  /\ replicaRevision[device] < revision
  /\ replicas' = [replicas EXCEPT ![device] = active]
  /\ replicaRevision' = [replicaRevision EXCEPT ![device] = revision]
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
                  pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pairing, pakeConfirmed>>

ExpireStaleReplica(device) ==
  /\ device \in Devices /\ device \notin active /\ replicas[device] # {}
  /\ replicas' = [replicas EXCEPT ![device] = {}]
  /\ replicaRevision' = [replicaRevision EXCEPT ![device] = 0]
  /\ UNCHANGED <<active, managers, tombstones, revokedEver, invites, revision, policyEpoch,
                  pendingRevokes, registryCommitted, localDenied,
                  routeRequests, routeIssuances, activeRoutes, pairing, pakeConfirmed>>

Next ==
  (\E manager, subject \in Devices: IssueInvite(manager, subject)) \/
  (\E subject \in Devices: BeginPairing(subject)) \/
  (\E subject \in Devices: ConfirmPAKE(subject)) \/
  (\E subject \in Devices: AcceptEncryptedProposal(subject)) \/
  (\E subject \in Devices: ManagerConfirm(subject)) \/
  (\E subject \in Devices: JoinerConfirm(subject)) \/
  (\E subject \in Devices: AbortPairing(subject)) \/
  (\E subject \in Devices: CommitJoin(subject)) \/
  (\E source, destination \in Devices: RequestRoute(source, destination)) \/
  (\E source, destination \in Devices: IssueRoute(source, destination)) \/
  (\E source, destination \in Devices: RetryIssuedRoute(source, destination)) \/
  (\E manager, subject \in Devices: BeginRevoke(manager, subject)) \/
  (\E subject \in Devices: RegistryCommitRevoke(subject)) \/
  (\E subject \in Devices: ApplyRevokeReceipt(subject)) \/
  (\E device \in Devices: Sync(device)) \/
  (\E device \in Devices: ExpireStaleReplica(device))

Spec == Init /\ [][Next]_vars
  /\ (\A manager, subject \in Devices: WF_vars(IssueInvite(manager, subject)))
  /\ (\A subject \in Devices: WF_vars(BeginPairing(subject)))
  /\ (\A subject \in Devices: WF_vars(ConfirmPAKE(subject)))
  /\ (\A subject \in Devices: WF_vars(AcceptEncryptedProposal(subject)))
  /\ (\A subject \in Devices: WF_vars(ManagerConfirm(subject)))
  /\ (\A subject \in Devices: WF_vars(JoinerConfirm(subject)))
  /\ (\A subject \in Devices: WF_vars(CommitJoin(subject)))
  /\ (\A subject \in Devices: WF_vars(RegistryCommitRevoke(subject)))
  /\ (\A subject \in Devices: WF_vars(ApplyRevokeReceipt(subject)))
  /\ (\A device \in Devices: WF_vars(Sync(device)))
  /\ (\A device \in Devices: WF_vars(ExpireStaleReplica(device)))

TypeOK ==
  /\ active \subseteq Devices /\ managers \subseteq active
  /\ tombstones \subseteq Devices /\ revokedEver \subseteq Devices /\ invites \subseteq Devices
  /\ revision \in 1..MaxRevision /\ policyEpoch \in 1..MaxRevision
  /\ replicas \in [Devices -> SUBSET Devices]
  /\ replicaRevision \in [Devices -> Nat]
  /\ pendingRevokes \subseteq Devices /\ registryCommitted \subseteq Devices
  /\ localDenied \subseteq Devices
  /\ routeRequests \subseteq DevicePairs
  /\ routeIssuances \subseteq routeRequests
  /\ activeRoutes \subseteq routeIssuances
  /\ pairing \in [Devices -> PairStates]
  /\ pakeConfirmed \subseteq Devices

RemoveWins == active \intersect tombstones = {}
TombstonesDurable == tombstones = revokedEver
NoRevokedManager == managers \intersect tombstones = {}
ReplicaOnlyKnowsMeshMembers == \A d \in Devices: replicas[d] \subseteq Devices
PendingRevokeFailsClosed == pendingRevokes \subseteq localDenied
LocalDenyHasDurableCause == localDenied \subseteq pendingRevokes \union tombstones
RouteAuthorizationCurrent ==
  \A pair \in activeRoutes:
    /\ pair[1] \in active /\ pair[2] \in active
    /\ pair[1] \notin localDenied /\ pair[2] \notin localDenied
PairingPayloadConfidential ==
  \A d \in Devices:
    d # Genesis /\ pairing[d] \in {"proposal", "manager_ok", "both_ok", "committed"} => d \in pakeConfirmed
NoHalfMembership == \A d \in active \ {Genesis}: pairing[d] = "committed"

AllJoined == active = Devices
AllActiveReplicasConverged == \A d \in active: replicas[d] = active
FullMeshEventuallyConverges == AllJoined ~> AllActiveReplicasConverged
PendingRevokesEventuallyDrain == pendingRevokes # {} ~> pendingRevokes = {}

====
