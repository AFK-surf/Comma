------------------------- MODULE WebhookJournal -------------------------
EXTENDS Naturals, FiniteSets, TLC
CONSTANTS Workers, UnsafeAckProcessing
VARIABLES journal, owner, phase, grants, acknowledged
vars == <<journal, owner, phase, grants, acknowledged>>

(* BillingStripe.Webhooks: durable journal insertion precedes the SQL
   transaction. The event row lock spans domain writes and the processed
   marker. PG commit is atomic; disconnect/restart aborts an open transaction.
   Deliver models duplicate/redelivered requests. Arbitrary scheduling models
   delay/reordering; absent Deliver models loss. No delivery liveness claimed. *)
Init ==
  /\ journal = "absent" /\ owner = "none"
  /\ phase = [w \in Workers |-> "idle"]
  /\ grants = 0 /\ acknowledged = FALSE
Deliver(w) ==
  /\ phase[w] = "idle"
  /\ journal' = IF journal = "absent" THEN "processing" ELSE journal
  /\ phase' = [phase EXCEPT ![w] = "waiting"]
  /\ UNCHANGED <<owner, grants, acknowledged>>
Lock(w) ==
  /\ phase[w] = "waiting" /\ owner = "none"
  /\ IF journal = "processed"
       THEN /\ phase' = [phase EXCEPT ![w] = "ackable"]
            /\ UNCHANGED owner
       ELSE /\ phase' = [phase EXCEPT ![w] = "writing"]
            /\ owner' = w
  /\ UNCHANGED <<journal, grants, acknowledged>>
Commit(w) ==
  /\ phase[w] = "writing" /\ owner = w
  /\ journal' = "processed" /\ grants' = grants + 1
  /\ owner' = "none" /\ phase' = [phase EXCEPT ![w] = "ackable"]
  /\ UNCHANGED acknowledged
Crash(w) ==
  /\ phase[w] # "idle"
  /\ phase' = [phase EXCEPT ![w] = "idle"]
  /\ owner' = IF owner = w THEN "none" ELSE owner
  /\ UNCHANGED <<journal, grants, acknowledged>>
Fail(w) ==
  /\ phase[w] = "writing" /\ owner = w
  /\ journal' = "failed" /\ owner' = "none"
  /\ phase' = [phase EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<grants, acknowledged>>
Ack(w) ==
  /\ phase[w] = "ackable" \/
       (UnsafeAckProcessing /\ phase[w] = "waiting" /\ journal = "processing")
  /\ acknowledged' = TRUE
  /\ phase' = [phase EXCEPT ![w] = "idle"]
  /\ UNCHANGED <<journal, owner, grants>>
Next == \E w \in Workers : Deliver(w) \/ Lock(w) \/ Commit(w) \/ Crash(w) \/ Fail(w) \/ Ack(w)
Spec == Init /\ [][Next]_vars
TypeOK ==
  /\ journal \in {"absent", "processing", "failed", "processed"}
  /\ owner \in Workers \cup {"none"}
  /\ phase \in [Workers -> {"idle", "waiting", "writing", "ackable"}]
  /\ acknowledged \in BOOLEAN /\ grants \in Nat
AtMostOnce == grants <= 1
AckHasCommittedEffects == acknowledged => grants = 1
ProcessedHasCommittedEffects == journal = "processed" => grants = 1
Safety == TypeOK /\ AtMostOnce /\ AckHasCommittedEffects /\ ProcessedHasCommittedEffects
=============================================================================
