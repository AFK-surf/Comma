import VerifiedKernelProofs.Session.WorkIdentityFacts

namespace VerifiedKernel.Session.WorkConservation
open Data
set_option Elab.async false

def LedgerSupported (state : Term) (sealed : List Term) : Prop :=
  ∀ source, IdentityPresent (state.get (a "input_dedupe")) (.binary source) → IdentitySupported state sealed source

theorem admitted_nonretiring {event : Term} (allowed : Command.inputEventAllowed event = true) :
    NonRetiring event := by
  have excluded := InputAdmission.admitted_event_no_retirement (events := [event]) (event := event)
    (by simpa using allowed) (by simp)
  exact ⟨excluded.1, excluded.2.1, excluded.2.2.1⟩

theorem admitted_inner_ledger_supported {state event next : Term} {sealed journal rest : List Term}
    (ready : QueueReady state) (format : state.get (a "storage_format") = i 3)
    (allowed : Command.inputEventAllowed event = true) (supported : LedgerSupported state sealed)
    (call : inner state event journal = .ok (next, rest)) : LedgerSupported next sealed := by
  intro source present
  rcases identity_present_or_absent (state.get (a "input_dedupe")) (.binary source) with old | absent
  · obtain ⟨original, fact, origin, represented⟩ := supported source old
    exact ⟨original, fact, origin, identity_fact_preserves
      (nonretiring_inner_preserves ready format (admitted_nonretiring allowed) call sealed)
      (fun _ stored => record_survives (nonretiring_inner_extends format (admitted_nonretiring allowed) call) stored)
      represented⟩
  · obtain ⟨fact, origin, represented⟩ := admitted_new_identity_fact ready allowed call absent present
    exact ⟨event, fact, origin, represented sealed⟩

theorem activity_ledger_supported {state next : Term} {sealed : List Term}
    (frame : ActivityFrame state next) (supported : LedgerSupported state sealed) : LedgerSupported next sealed := by
  intro source present
  rw [frame "input_dedupe" (by decide) (by decide)] at present
  obtain ⟨event, fact, origin, represented⟩ := supported source present
  refine ⟨event, fact, origin, identity_fact_preserves ?_ ?_ represented⟩
  · intro item work
    exact ValueSemantics.execution_preserves
      (fun _ before => (concrete_representation_frame (activity_frame_work frame)).mp before)
      (fun _ before => record_survives (activity_frame_extends frame) before) work
  · exact fun _ before => record_survives (activity_frame_extends frame) before

theorem admitted_resident_ledger_supported {state event next : Term} {sealed : List Term}
    (step : ResidentStep state event next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3) (canonical : BinaryKeys event)
    (allowed : Command.inputEventAllowed event = true) (supported : LedgerSupported state sealed) :
    LedgerSupported next sealed := by
  obtain ⟨middle, normalized, journal, rest, prepared, activity⟩ := step
  apply activity_ledger_supported activity
  cases normalized with
  | none => rw [prepareTrusted_none prepared]; exact supported
  | some normalized =>
    obtain ⟨_, read, _, call⟩ := prepareTrusted_stringify prepared
    have same := shallowStringify_binary_keys canonical read
    subst normalized
    exact admitted_inner_ledger_supported ready format allowed supported call

theorem admitted_batch_ledger_supported {state next : Term} {events sealed : List Term}
    (execution : ResidentBatch state events next) (ready : QueueReady state)
    (format : state.get (a "storage_format") = i 3)
    (canonical : ∀ event ∈ events, BinaryKeys event)
    (allowed : ∀ event ∈ events, Command.inputEventAllowed event = true)
    (supported : LedgerSupported state sealed) : LedgerSupported next sealed := by
  induction execution with
  | nil => exact supported
  | cons head tail ih =>
    have step := resident_execution_step head
    have headKeys := canonical _ List.mem_cons_self
    have headAllowed := allowed _ List.mem_cons_self
    obtain ⟨middleReady, middleFormat, _⟩ := nonretiring_resident_preserves
      step ready format headKeys (admitted_nonretiring headAllowed)
    exact ih middleReady middleFormat
      (fun event member => canonical event (List.mem_cons_of_mem _ member))
      (fun event member => allowed event (List.mem_cons_of_mem _ member))
      (admitted_resident_ledger_supported step ready format headKeys headAllowed supported)

theorem equivalent_identity_present {before after : Term} {source : ByteArray}
    (same : ValueSemantics.Equivalent before after) :
    IdentityPresent before (.binary source) ↔ IdentityPresent after (.binary source) := by
  have observed := ((same.get (a "map")).access (.present (.binary source))).truthy
  change (Term.bool ((before.get (a "map")).has (.binary source))).truthy =
    (Term.bool ((after.get (a "map")).has (.binary source))).truthy at observed
  unfold IdentityPresent
  cases left : (before.get (a "map")).has (.binary source) <;>
    cases right : (after.get (a "map")).has (.binary source) <;>
    simp_all [Term.bool, Term.truthy]

theorem equivalent_ledger_supported {state next : Term} {sealed : List Term}
    (same : ValueSemantics.Equivalent state next) (supported : LedgerSupported state sealed) :
    LedgerSupported next sealed := by
  intro source present
  have previous := (equivalent_identity_present (same.get (a "input_dedupe"))).mpr present
  obtain ⟨event, fact, origin, represented⟩ := supported source previous
  exact ⟨event, fact, origin, identity_fact_equivalent same represented⟩

theorem persistable_ledger_supported {state next : Term} {journal rest sealed : List Term}
    (supported : LedgerSupported state sealed)
    (call : Lifecycle.persistable state journal = .ok (next, rest)) : LedgerSupported next sealed := by
  have fields := persistable_work_fields call
  have ledger : LedgerFrame state next := by
    rw [put_ok call]
    exact get_put_other _ _ (by decide)
  intro source present
  rw [ledger] at present
  obtain ⟨event, fact, origin, represented⟩ := supported source present
  exact ⟨event, fact, origin, identity_fact_work_fields fields represented⟩

end VerifiedKernel.Session.WorkConservation
