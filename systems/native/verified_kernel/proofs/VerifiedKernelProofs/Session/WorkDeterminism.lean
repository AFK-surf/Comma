import VerifiedKernelProofs.Session.WorkInput

namespace VerifiedKernel.Session.WorkConservation
open Data

theorem foldlM_same_results {α : Type} {items : List Term} {first second : α → Term → KernelM α}
    (same : ∀ state item left right j r before after,
      first state item j = .ok (left, r) → second state item before = .ok (right, after) → left = right)
    {initial left right : α} {j r before after : List Term}
    (one : items.foldlM first initial j = .ok (left, r))
    (two : items.foldlM second initial before = .ok (right, after)) : left = right := by
  induction items generalizing initial j before with
  | nil => exact (pure_ok one).trans (pure_ok two).symm
  | cons item items ih =>
    rw [List.foldlM_cons] at one two
    obtain ⟨next, _, firstStep, one⟩ := bind_ok one
    obtain ⟨next', _, secondStep, two⟩ := bind_ok two
    have equal := same _ _ _ _ _ _ _ _ firstStep secondStep
    subst next'
    exact ih one two

theorem mapM_same_results {items : List Term} {first second : Term → KernelM Term}
    (same : ∀ item left right j r before after,
      first item j = .ok (left, r) → second item before = .ok (right, after) → left = right)
    {left right j r before after : List Term}
    (one : items.mapM first j = .ok (left, r))
    (two : items.mapM second before = .ok (right, after)) : left = right := by
  induction items generalizing left right j r before after with
  | nil => exact (pure_ok one).trans (pure_ok two).symm
  | cons item items ih =>
    rw [List.mapM_cons] at one two
    obtain ⟨head, _, firstStep, one⟩ := bind_ok one
    obtain ⟨head', _, secondStep, two⟩ := bind_ok two
    have equal := same _ _ _ _ _ _ _ firstStep secondStep
    subst head'
    obtain ⟨tail, _, firstRest, one⟩ := bind_ok one
    obtain ⟨tail', _, secondRest, two⟩ := bind_ok two
    rw [pure_ok one, pure_ok two, ih firstRest secondRest]

theorem stringChars_same_results {value left right : Term} {j r before after : List Term}
    (one : stringChars value j = .ok (left, r))
    (two : stringChars value before = .ok (right, after)) : left = right := by
  cases value with
  | atom name =>
    by_cases empty : name = "nil"
    · subst name; exact (pure_ok one).trans (pure_ok two).symm
    · have converted : stringChars (.atom name) = pure (b name) := by simp [stringChars, empty]
      rw [converted] at one two
      exact (pure_ok one).trans (pure_ok two).symm
  | list values =>
    simp only [stringChars] at one two
    cases chars : charData (.list values) <;> simp only [chars] at one two
    · exact (fail_ok one).elim
    · exact (pure_ok one).trans (pure_ok two).symm
  | _ => first
    | exact (pure_ok one).trans (pure_ok two).symm
    | exact (fail_ok one).elim

/-- Successful normalization has one result, independent of journal size and fuel. -/
theorem stringifyFuel_same_results {fuel otherFuel : Nat} {value left right : Term} {j r before after : List Term}
    (one : stringifyFuel fuel value j = .ok (left, r))
    (two : stringifyFuel otherFuel value before = .ok (right, after)) : left = right := by
  induction fuel generalizing otherFuel value left right j r before after with
  | zero => exact (fail_ok one).elim
  | succ fuel ih =>
    cases otherFuel with
    | zero => exact (fail_ok two).elim
    | succ otherFuel =>
      cases value <;> unfold stringifyFuel at one two
      all_goals first
        | exact (pure_ok one).trans (pure_ok two).symm
        | (obtain ⟨_, _, _, one⟩ := bind_ok one; exact (fail_ok one).elim)
        | skip
      case list items =>
        obtain ⟨first, _, firstRead, one⟩ := bind_ok one
        obtain ⟨second, _, secondRead, two⟩ := bind_ok two
        have same := mapM_same_results (first := stringifyFuel fuel) (second := stringifyFuel otherFuel)
          (fun _ _ _ _ _ _ _ a b => ih a b) firstRead secondRead
        rw [pure_ok one, pure_ok two, same]
      case map fields =>
        obtain ⟨items, firstFold, secondFold⟩ := enumFold_same_input one two
        apply foldlM_same_results _ firstFold secondFold
        intro state item first second j r before after one two
        split at one
        · rename_i key value
          obtain ⟨name, _, nameRead, one⟩ := bind_ok one
          obtain ⟨name', _, nameRead', two⟩ := bind_ok two
          have same := stringChars_same_results nameRead nameRead'
          subst name'
          obtain ⟨value', _, valueRead, one⟩ := bind_ok one
          obtain ⟨value'', _, valueRead', two⟩ := bind_ok two
          have same := ih valueRead valueRead'
          subst value''
          exact (put_ok one).trans (put_ok two).symm
        · exact (fail_ok one).elim

theorem stringify_same_results {value left right : Term} {j r before after : List Term}
    (one : stringify value j = .ok (left, r))
    (two : stringify value before = .ok (right, after)) : left = right := by
  unfold stringify at one two
  obtain ⟨_, _, _, one⟩ := bind_ok one
  obtain ⟨_, _, _, two⟩ := bind_ok two
  exact stringifyFuel_same_results one two

def Deterministic {α : Type} (f : KernelM α) : Prop :=
  ∀ left right j r before after, f j = .ok (left, r) → f before = .ok (right, after) → left = right

theorem deterministic_pure {α : Type} (value : α) : Deterministic (pure value) :=
  fun _ _ _ _ _ _ one two => (pure_ok one).trans (pure_ok two).symm

theorem deterministic_fail {α : Type} (kind : String) (args : List Term := []) :
    Deterministic (fail kind args : KernelM α) := fun _ _ _ _ _ _ one _ => (fail_ok one).elim

theorem deterministic_bind {α β : Type} {first : KernelM α} {next : α → KernelM β}
    (initial : Deterministic first) (tail : ∀ value, Deterministic (next value)) : Deterministic (first >>= next) := by
  intro left right j r before after one two
  obtain ⟨value, _, firstRead, one⟩ := bind_ok one
  obtain ⟨value', _, secondRead, two⟩ := bind_ok two
  have same := initial _ _ _ _ _ _ firstRead secondRead
  subst value'
  exact tail value _ _ _ _ _ _ one two

theorem deterministic_access (value key : Term) : Deterministic (access value key) :=
  fun _ _ _ _ _ _ one two => (access_ok one).1.trans (access_ok two).1.symm

theorem deterministic_stringify (value : Term) : Deterministic (stringify value) :=
  fun _ _ _ _ _ _ one two => stringify_same_results one two

theorem deterministic_aliases (value : Term) (keys : List Term) : Deterministic (aliases value keys) := by
  induction keys with
  | nil => exact deterministic_pure _
  | cons key keys ih =>
    cases keys with
    | nil => exact deterministic_access _ _
    | cons next rest =>
      unfold aliases
      apply deterministic_bind (deterministic_access _ _)
      intro found
      split
      · exact deterministic_pure _
      · exact ih

theorem deterministic_queueKeys (event payload kind : Term) : Deterministic (queueKeys event payload kind) := by
  unfold queueKeys
  apply deterministic_bind (deterministic_access _ _); intro dedupe
  apply deterministic_bind (deterministic_access _ _); intro source
  apply deterministic_bind (deterministic_access _ _); intro payloadSource
  dsimp only
  split
  · apply deterministic_bind (deterministic_access _ _); intro runtime
    apply deterministic_bind (deterministic_pure _); intro keys
    exact deterministic_pure _
  · apply deterministic_bind (deterministic_pure _); intro keys
    exact deterministic_pure _

theorem deterministic_runtimeKeys (event : Term) : Deterministic (runtimeKeys event) := by
  unfold runtimeKeys
  apply deterministic_bind (deterministic_access _ _); intro dedupe
  apply deterministic_bind (deterministic_access _ _); intro source
  apply deterministic_bind (deterministic_access _ _); intro runtime
  exact deterministic_pure _

theorem deterministic_seedKeys (entry : Term) : Deterministic (seedKeys entry) := by
  unfold seedKeys
  apply deterministic_bind (deterministic_access _ _); intro dedupe
  apply deterministic_bind (deterministic_access _ _); intro source
  apply deterministic_bind (deterministic_access _ _); intro runtime
  apply deterministic_bind (deterministic_aliases _ _); intro tool
  exact deterministic_pure _

theorem deterministic_enumFold {α : Type} (value : Term) (initial : α) (step : α → Term → KernelM α)
    (same : ∀ acc item, Deterministic (step acc item)) : Deterministic (enumFold value initial step) := by
  intro left right j r before after one two
  obtain ⟨items, firstFold, secondFold⟩ := enumFold_same_input one two
  exact foldlM_same_results (fun state item _ _ _ _ _ _ a b => same state item _ _ _ _ _ _ a b) firstFold secondFold

theorem deterministic_inputIdentityGroups (event : Term) : Deterministic (Command.inputIdentityGroups event) := by
  unfold Command.inputIdentityGroups
  dsimp only
  split
  · apply deterministic_bind (deterministic_stringify _); intro payload
    apply deterministic_bind (deterministic_queueKeys _ _ _); intro keys
    exact deterministic_pure _
  · split
    · split
      · exact deterministic_pure _
      · apply deterministic_bind (deterministic_runtimeKeys _); intro keys
        exact deterministic_pure _
    · split
      · split <;> exact deterministic_pure _
      · split
        · exact deterministic_pure _
        · split
          · apply deterministic_enumFold; intro acc item
            apply deterministic_bind (deterministic_stringify _); intro entry
            apply deterministic_bind (deterministic_seedKeys _); intro keys
            exact deterministic_pure _
          · exact deterministic_pure _

end VerifiedKernel.Session.WorkConservation
