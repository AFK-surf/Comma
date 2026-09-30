import VerifiedKernelProofs.Session.WorkIdentityInvariant

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false
set_option maxHeartbeats 1000000
set_option maxRecDepth 4096

def MapSetHeader (value : Term) : Prop := value.get (a "__struct__") = a "Elixir.MapSet"
def LedgerHeader (state : Term) : Prop := MapSetHeader (state.get (a "input_dedupe"))

theorem setPut_header {before key after : Term} {journal rest : List Term}
    (header : MapSetHeader before) (call : setPut before key journal = .ok (after, rest)) : MapSetHeader after := by
  unfold setPut at call
  split at call
  · rw [pure_ok call]; rfl
  · dsimp only at call
    split at call
    · rw [pure_ok call]
      unfold MapSetHeader
      rw [get_put_other _ _ (by decide)]
      exact header
    · exact (fail_ok call).elim

theorem addDedupe_header {before after : Term} {keys journal rest : List Term}
    (header : MapSetHeader before) (call : addDedupe before keys journal = .ok (after, rest)) : MapSetHeader after := by
  unfold addDedupe at call
  induction keys generalizing before journal with
  | nil => rw [pure_ok call]; exact header
  | cons key keys ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, head, tail⟩ := bind_ok call
    exact ih (setPut_header header head) tail

theorem deliveryDedupe_header {before key after : Term} {journal rest : List Term}
    (header : MapSetHeader before) (call : deliveryDedupe before key journal = .ok (after, rest)) : MapSetHeader after := by
  unfold deliveryDedupe at call
  split at call
  · rw [pure_ok call]; exact header
  · exact setPut_header header call

theorem default_set_header {value : Term} (header : MapSetHeader value) :
    MapSetHeader (value.default Lifecycle.emptySet) := by
  unfold Term.default
  split
  · exact header
  · rfl

theorem queueAppend_ledger_header {state event next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : queueAppend state event journal = .ok (next, rest)) : LedgerHeader next := by
  unfold queueAppend at call
  split at call
  · obtain ⟨_, _, failed, _⟩ := bind_ok call
    exact (fail_ok failed).elim
  · repeat
      fail_if_success (bind_field_is call "input_dedupe"; change (field state "input_dedupe" >>= _) _ = .ok (next, rest) at call)
      obtain ⟨_, _, _, call⟩ := bind_ok call
    obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
    have same := field_value ledgerRead
    subst ledger
    obtain ⟨hit, _, _, call⟩ := bind_ok call
    split at call
    · rw [pure_ok call]; exact header
    · repeat
        fail_if_success (bind_head_is call [addDedupe]; change (addDedupe _ _ >>= _) _ = .ok (next, rest) at call)
        obtain ⟨_, _, _, call⟩ := bind_ok call
      obtain ⟨dedupe, _, dedupeRead, call⟩ := bind_ok call
      have kept := addDedupe_header header dedupeRead
      obtain ⟨_, _, _, call⟩ := bind_ok call
      obtain ⟨_, _, _, call⟩ := bind_ok call
      iterate 3 obtain ⟨_, call⟩ := write_cons call
      unfold LedgerHeader
      rw [write_field_frame call rfl, get_put_same]
      exact kept

theorem transcriptLog_ledger_header {state event next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : transcriptLog state event journal = .ok (next, rest)) : LedgerHeader next := by
  unfold transcriptLog at call
  repeat
    fail_if_success (bind_field_is call "input_dedupe"; change (field state "input_dedupe" >>= _) _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
  have same := field_value ledgerRead
  subst ledger
  obtain ⟨hit, _, _, call⟩ := bind_ok call
  split at call
  · rw [pure_ok call]; exact header
  · repeat'
      fail_if_success (bind_head_is call [addDedupe]; change (addDedupe _ _ >>= _) _ = _ at call)
      first
        | (obtain ⟨_, _, _, call⟩ := bind_ok call)
        | split at call
        | dsimp only at call
    all_goals
      obtain ⟨dedupe, _, dedupeRead, call⟩ := bind_ok call
      have kept := addDedupe_header header dedupeRead
      obtain ⟨updated, _, written, call⟩ := bind_ok call
      have frame := bumpHwm_ledger_frame call
      obtain ⟨_, written⟩ := write_cons written
      unfold LedgerHeader
      rw [frame, pure_ok written, get_put_same]
      exact kept

theorem runtimeAppend_ledger_header {state event next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : runtimeAppend state event journal = .ok (next, rest)) : LedgerHeader next := by
  unfold runtimeAppend at call
  repeat'
    fail_if_success (bind_field_is call "input_dedupe"; change (field state "input_dedupe" >>= _) _ = _ at call)
    first
      | (obtain ⟨_, _, _, call⟩ := bind_ok call)
      | split at call
      | dsimp only at call
  all_goals
    obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
    have same := field_value ledgerRead
    subst ledger
    obtain ⟨dedupe, _, dedupeRead, call⟩ := bind_ok call
    have kept := addDedupe_header header dedupeRead
    try split at call
    all_goals
      obtain ⟨_, _, _, call⟩ := bind_ok call
      obtain ⟨updated, _, written, call⟩ := bind_ok call
      have finalFrame : LedgerFrame updated next := by ledger_frame_walk call
      obtain ⟨_, written⟩ := write_cons written
      unfold LedgerHeader
      rw [finalFrame, write_field_frame written rfl, get_put_same]
      exact kept

theorem transcriptRuntime_ledger_header {state event next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : transcriptRuntime state event journal = .ok (next, rest)) : LedgerHeader next := by
  unfold transcriptRuntime at call
  repeat' first
    | exact runtimeAppend_ledger_header header call
    | (rw [pure_ok call]; exact header)
    | exact (fail_ok call).elim
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | dsimp only at call

theorem transcriptDelivery_ledger_header {state event next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : transcriptDelivery state event journal = .ok (next, rest)) : LedgerHeader next := by
  unfold transcriptDelivery at call
  split at call
  · rw [pure_ok call]; exact header
  · repeat'
      fail_if_success (bind_field_is call "input_dedupe"; change (field state "input_dedupe" >>= _) _ = _ at call)
      first
        | (obtain ⟨_, _, _, call⟩ := bind_ok call)
        | split at call
        | (generalize event.get (b "billing_context") = context at call; split at call)
        | dsimp only at call
    all_goals
      obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
      have same := field_value ledgerRead
      subst ledger
      obtain ⟨first, _, firstRead, call⟩ := bind_ok call
      obtain ⟨dedupe, _, dedupeRead, call⟩ := bind_ok call
      have kept := deliveryDedupe_header (deliveryDedupe_header header firstRead) dedupeRead
      repeat'
        fail_if_success (bind_head_is call [write]; change (write _ _ >>= _) _ = _ at call)
        first
          | (obtain ⟨_, _, _, call⟩ := bind_ok call)
          | split at call
          | dsimp only at call
      all_goals
        obtain ⟨updated, _, written, call⟩ := bind_ok call
        have finalFrame : LedgerFrame updated next := by ledger_frame_walk call
        iterate 2 obtain ⟨_, written⟩ := write_cons written
        unfold LedgerHeader
        rw [finalFrame, write_field_frame written rfl, get_put_same]
        exact kept

theorem seed_step_ledger_header {event raw : Term}
    {initial final : List Term × Term × Term × Bool × Term} {journal rest : List Term}
    (header : MapSetHeader initial.2.2.1)
    (call : seedLedgerStep event initial raw journal = .ok (final, rest)) : MapSetHeader final.2.2.1 := by
  obtain ⟨messages, next, ledger, any, seq⟩ := initial
  unfold seedLedgerStep at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  split at call
  · rw [pure_ok call]; exact header
  · iterate 3 obtain ⟨_, _, _, call⟩ := bind_ok call
    obtain ⟨dedupe, _, dedupeRead, call⟩ := bind_ok call
    rw [pure_ok call]
    exact addDedupe_header header dedupeRead

theorem seed_fold_ledger_header {event : Term} {items : List Term}
    {initial final : List Term × Term × Term × Bool × Term} {journal rest : List Term}
    (header : MapSetHeader initial.2.2.1)
    (call : items.foldlM (seedLedgerStep event) initial journal = .ok (final, rest)) : MapSetHeader final.2.2.1 := by
  induction items generalizing initial journal with
  | nil => rw [pure_ok call]; exact header
  | cons raw items ih =>
    rw [List.foldlM_cons] at call
    obtain ⟨next, _, head, tail⟩ := bind_ok call
    exact ih (seed_step_ledger_header header head) tail

theorem transcriptSeed_ledger_header {state event next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : transcriptSeed state event journal = .ok (next, rest)) : LedgerHeader next := by
  unfold transcriptSeed at call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
  have same := field_value ledgerRead
  subst ledger
  obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨result, _, folded, call⟩ := bind_ok call
  change enumFold _ _ (seedLedgerStep event) _ = .ok (result, _) at folded
  obtain ⟨items, folded, _⟩ := enumFold_ok folded
  have kept := seed_fold_ledger_header (default_set_header header) folded
  obtain ⟨appended, nextId, dedupe, any, lastSeq⟩ := result
  repeat'
    fail_if_success (bind_head_is call [write]; change (write _ _ >>= _) _ = _ at call)
    first
      | (obtain ⟨_, _, _, call⟩ := bind_ok call)
      | split at call
      | dsimp only at call
  all_goals
    obtain ⟨updated, _, written, call⟩ := bind_ok call
    have finalFrame : LedgerFrame updated next := by ledger_frame_walk call
    iterate 6 obtain ⟨_, written⟩ := write_cons written
    unfold LedgerHeader
    rw [finalFrame, pure_ok written, get_put_same]
    exact kept

theorem preserve_dedupe_header {state ledger : Term} {journal rest : List Term}
    (call : Lifecycle.preserveDedupe state journal = .ok (ledger, rest)) : MapSetHeader ledger := by
  unfold Lifecycle.preserveDedupe at call
  repeat' first
    | (rw [pure_ok call]; rfl)
    | exact (fail_ok call).elim
    | (obtain ⟨_, _, _, call⟩ := bind_ok call)
    | split at call
    | (generalize Term.get _ _ = members at call; split at call)
    | dsimp only at call

theorem normalize_ledger_header {state next : Term} {journal rest : List Term}
    (call : Lifecycle.normalize state journal = .ok (next, rest)) : LedgerHeader next := by
  unfold Lifecycle.normalize at call
  repeat
    fail_if_success (bind_head_is call [Lifecycle.preserveDedupe]; change (Lifecycle.preserveDedupe _ >>= _) _ = .ok (next, rest) at call)
    obtain ⟨_, _, _, call⟩ := bind_ok call
  obtain ⟨ledger, _, ledgerRead, call⟩ := bind_ok call
  obtain ⟨_, written⟩ := write_cons call
  unfold LedgerHeader
  rw [pure_ok written, get_put_same]
  exact preserve_dedupe_header ledgerRead

theorem create_ledger_header {state args next : Term} {journal rest : List Term}
    (call : Lifecycle.create state args journal = .ok (next, rest)) : LedgerHeader next := by
  unfold Lifecycle.create at call
  split at call
  · repeat
      fail_if_success (head_is call [Lifecycle.normalize]; change Lifecycle.normalize _ _ = .ok (next, rest) at call)
      obtain ⟨_, _, _, call⟩ := bind_ok call
    exact normalize_ledger_header call
  · exact (fail_ok call).elim

theorem persistable_ledger_header {state next : Term} {journal rest : List Term}
    (header : LedgerHeader state) (call : Lifecycle.persistable state journal = .ok (next, rest)) : LedgerHeader next := by
  unfold LedgerHeader
  rw [put_ok call, get_put_other _ _ (by decide)]
  exact header

theorem equivalent_ledger_header {state next : Term}
    (header : LedgerHeader state) (same : ValueSemantics.Equivalent state next) : LedgerHeader next := by
  have observed := (same.get (a "input_dedupe")).get (a "__struct__")
  rw [header] at observed
  exact observed.atom

end VerifiedKernel.Session.WorkConservation
