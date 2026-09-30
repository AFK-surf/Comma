------------------------------- MODULE S3 -------------------------------
(***************************************************************************)
(* The object-store contract Salix relies on (`SalixStore.S3` behaviour):  *)
(* per-object linearizable reads and conditional writes.  Each object is a *)
(* cell record [present, val, ver].  `ver` models the ETag: it changes on  *)
(* every applied mutation and is only ever compared for equality.          *)
(*                                                                         *)
(* Deliberate strengthening vs. real ETags (documented in                  *)
(* docs/verification.md): `ver` is monotone across delete and   *)
(* recreate, so an old ETag can never be reproduced.  Real ETags are       *)
(* content hashes (md5 in S3 and in SalixStore.S3.Fake), so a delete +     *)
(* re-create with an identical body DOES reproduce the ETag.  Per          *)
(* `if_match` site: the head embeds commit_uuid, the lease a fresh         *)
(* lease_until — never reproducible.  (The retired staged protocol's       *)
(* queue marker carried a random nonce, and its inbox entry was the one    *)
(* deterministic-body site whose ABA the historical Delivery spec          *)
(* tolerates by design; both key families retired with A2 §3.4.)           *)
(* That historical ABA was tolerated by a settled-id argument recorded in  *)
(* the archived Delivery spec; no live key family carries a               *)
(* deterministic body today, so this model's never-reproducible `ver` is  *)
(* an over- rather than under-approximation of every current if_match     *)
(* site.                                                                  *)
(*                                                                         *)
(* `SkillCatalogIdentityMigration.tla` has another deterministic-body      *)
(* conditional DELETE. Its audited release fence plus canonical runtime    *)
(* routing exclude recreation of the legacy source after either migration  *)
(* runner deletes it; competing runners may repair the target or delete    *)
(* that source, but never recreate it. Target repair changes legacy bytes  *)
(* to canonical bytes, and create-once is fenced by presence rather than   *)
(* ETag identity. Thus content-hash reuse adds no admitted ABA trace there; *)
(* the shared monotone `ver` remains a sound abstraction for that model.   *)
(*                                                                         *)
(* Ambiguous outcomes (timeout / 5xx: the fake's `:ambiguous_before` and   *)
(* `:ambiguous_after` faults) are not modeled here — each spec models them *)
(* as nondeterministic branches of its own PUT/DELETE steps, moving the    *)
(* caller into its resolve state with the mutation applied or not.         *)
(***************************************************************************)
EXTENDS Naturals

(* A cell that has never held an object. *)
EmptyCell == [present |-> FALSE, val |-> <<>>, ver |-> 0]

(* The cell after an applied PUT of `v`. *)
Applied(cell, v) == [present |-> TRUE, val |-> v, ver |-> cell.ver + 1]

(* The cell after an applied DELETE.  ver still bumps: a conditional       *)
(* delete/put racing a recreate must never see a stale match.             *)
Deleted(cell) == [present |-> FALSE, val |-> cell.val, ver |-> cell.ver + 1]

(* Conditional-write guards (AWS `If-None-Match: *` / `If-Match: <etag>`,  *)
(* or GCS generation preconditions — equivalent at this altitude).         *)
CanPutIfNoneMatch(cell) == ~cell.present
CanPutIfMatch(cell, etag) == cell.present /\ cell.ver = etag
CanDeleteIfMatch(cell, etag) == cell.present /\ cell.ver = etag

ETag(cell) == cell.ver

=============================================================================
