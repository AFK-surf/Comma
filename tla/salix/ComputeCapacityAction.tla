---------------------- MODULE ComputeCapacityAction ----------------------
(***************************************************************************)
(* A workload import that exhausts Guest storage or the single import slot *)
(* becomes action_required. Periodic reconciler passes cannot retry it.     *)
(* A later operator action can retry only after capacity is available.      *)
(***************************************************************************)
EXTENDS Naturals

CONSTANT BlindTimerRetry

VARIABLES state, attempts, capacityAvailable

vars == <<state, attempts, capacityAvailable>>
States == {"pending", "action_required", "ready"}

Init ==
  /\ state = "pending"
  /\ attempts = 0
  /\ capacityAvailable = FALSE

Attempt ==
  /\ state = "pending"
  /\ attempts' = attempts + 1
  /\ state' = IF capacityAvailable THEN "ready" ELSE "action_required"
  /\ UNCHANGED capacityAvailable

CapacityChanges ==
  /\ ~capacityAvailable
  /\ capacityAvailable' = TRUE
  /\ UNCHANGED <<state, attempts>>

OperatorRetries ==
  /\ state = "action_required"
  /\ capacityAvailable
  /\ state' = "pending"
  /\ UNCHANGED <<attempts, capacityAvailable>>

TimerRetries ==
  /\ state = "action_required"
  /\ BlindTimerRetry
  /\ state' = "pending"
  /\ UNCHANGED <<attempts, capacityAvailable>>

Next == Attempt \/ CapacityChanges \/ OperatorRetries \/ TimerRetries
Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ state \in States
  /\ attempts \in Nat
  /\ capacityAvailable \in BOOLEAN

ReadyHasCapacity == state = "ready" => capacityAvailable

NoAutomaticRetry ==
  state = "pending" /\ attempts > 0 => capacityAvailable

=============================================================================
