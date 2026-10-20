import VerifiedKernelProofs.Provider.Stateless

/-!
Execution lemmas for `for` loops in `KernelM`.

The provider projection builds its outputs with `for` loops over message lists. A prefix proof
splits a loop over `xs ++ ys` at the boundary and tracks the loop state with an invariant, a
relation, or a pure abstraction of one step.
-/

namespace VerifiedKernel.ProviderLoop
open Data

set_option maxHeartbeats 4000000

/-- Every step of the loop body continues the loop: the body has no `break` or early `return`. -/
def Yields {α σ : Type} (f : α → σ → KernelM (ForInStep σ)) : Prop :=
  ∀ x b j s r, f x b j = .ok (s, r) → ∃ b', s = .yield b'

theorem forIn_nil_ok {α σ : Type} {f : α → σ → KernelM (ForInStep σ)} {b v : σ} {j r : List Term}
    (h : ForIn.forIn ([] : List α) b f j = .ok (v, r)) : v = b ∧ r = j := by
  rw [List.forIn_nil] at h
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  exact ⟨h.1, h.2⟩

theorem forIn_cons_ok {α σ : Type} {f : α → σ → KernelM (ForInStep σ)} {x : α} {xs : List α} {b v : σ}
    {j r : List Term} (yields : Yields f) (h : ForIn.forIn (x :: xs) b f j = .ok (v, r)) :
    ∃ b' j', f x b j = .ok (.yield b', j') ∧ ForIn.forIn xs b' f j' = .ok (v, r) := by
  rw [List.forIn_cons] at h
  obtain ⟨s, j', hs, rest⟩ := Session.bind_ok_iff.mp h
  obtain ⟨b', rfl⟩ := yields _ _ _ _ _ hs
  exact ⟨b', j', hs, rest⟩

theorem forIn_append_ok {α σ : Type} {f : α → σ → KernelM (ForInStep σ)} (yields : Yields f) :
    ∀ {xs ys : List α} {b v : σ} {j r : List Term},
      ForIn.forIn (xs ++ ys) b f j = .ok (v, r) →
      ∃ b₁ j₁, ForIn.forIn xs b f j = .ok (b₁, j₁) ∧ ForIn.forIn ys b₁ f j₁ = .ok (v, r)
  | [], _, b, _, j, _, h => ⟨b, j, by rw [List.forIn_nil]; rfl, by simpa using h⟩
  | x :: xs, ys, b, v, j, r, h => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok yields (by simpa using h)
    obtain ⟨b₁, j₁, first, second⟩ := forIn_append_ok yields rest
    refine ⟨b₁, j₁, ?_, second⟩
    rw [List.forIn_cons]
    exact Session.bind_ok_iff.mpr ⟨_, _, hx, first⟩

/-- A reflexive and transitive relation that every step establishes holds across the loop. -/
theorem forIn_rel {α σ : Type} {f : α → σ → KernelM (ForInStep σ)} (yields : Yields f)
    {R : σ → σ → Prop} (refl : ∀ b, R b b) (trans : ∀ a b c, R a b → R b c → R a c)
    (step : ∀ x b b' j r, f x b j = .ok (.yield b', r) → R b b') :
    ∀ {xs : List α} {b v : σ} {j r : List Term}, ForIn.forIn xs b f j = .ok (v, r) → R b v
  | [], b, v, j, r, h => by
    obtain ⟨rfl, -⟩ := forIn_nil_ok h
    exact refl _
  | x :: xs, b, v, j, r, h => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok yields h
    exact trans _ _ _ (step _ _ _ _ _ hx) (forIn_rel yields refl trans step rest)

/-- An invariant that every step preserves holds after the loop. -/
theorem forIn_inv {α σ : Type} {f : α → σ → KernelM (ForInStep σ)} (yields : Yields f)
    {I : σ → Prop} (step : ∀ x b b' j r, I b → f x b j = .ok (.yield b', r) → I b') :
    ∀ {xs : List α} {b v : σ} {j r : List Term}, I b → ForIn.forIn xs b f j = .ok (v, r) → I v
  | [], b, v, j, r, hb, h => by
    obtain ⟨rfl, -⟩ := forIn_nil_ok h
    exact hb
  | x :: xs, b, v, j, r, hb, h => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok yields h
    exact forIn_inv yields step (step _ _ _ _ _ hb hx) rest

/-- A projection of the loop state that each step updates by a pure function is a fold. -/
theorem forIn_fold {α σ τ : Type} {f : α → σ → KernelM (ForInStep σ)} (yields : Yields f)
    {π : σ → τ} {g : τ → α → τ} (step : ∀ x b b' j r, f x b j = .ok (.yield b', r) → π b' = g (π b) x) :
    ∀ {xs : List α} {b v : σ} {j r : List Term}, ForIn.forIn xs b f j = .ok (v, r) → π v = xs.foldl g (π b)
  | [], b, v, j, r, h => by
    obtain ⟨rfl, -⟩ := forIn_nil_ok h
    rfl
  | x :: xs, b, v, j, r, h => by
    obtain ⟨b', j', hx, rest⟩ := forIn_cons_ok yields h
    rw [forIn_fold yields step rest, step _ _ _ _ _ hx]
    rfl

/-- `xs` extends `ys` by prepending: the accumulator shape of the projection loops. -/
def Prepends {α : Type} (xs ys : List α) : Prop := ∃ d, xs = d ++ ys

theorem Prepends.refl {α : Type} (xs : List α) : Prepends xs xs := ⟨[], rfl⟩

theorem Prepends.trans {α : Type} {xs ys zs : List α} (h₁ : Prepends xs ys) (h₂ : Prepends ys zs) :
    Prepends xs zs := by
  obtain ⟨d₁, rfl⟩ := h₁
  obtain ⟨d₂, rfl⟩ := h₂
  exact ⟨d₁ ++ d₂, by simp⟩

theorem Prepends.append {α : Type} (d xs : List α) : Prepends (d ++ xs) xs := ⟨d, rfl⟩
theorem Prepends.cons {α : Type} (x : α) (xs : List α) : Prepends (x :: xs) xs := ⟨[x], rfl⟩
theorem Prepends.cons_append {α : Type} (x : α) (d xs : List α) : Prepends (x :: (d ++ xs)) xs :=
  ⟨x :: d, rfl⟩

end VerifiedKernel.ProviderLoop

namespace VerifiedKernel.ProviderLoop
theorem Prepends.append_cons {α : Type} (d : List α) (x : α) (xs : List α) : Prepends (d ++ x :: xs) xs :=
  ⟨d ++ [x], by simp⟩
end VerifiedKernel.ProviderLoop

namespace VerifiedKernel.ProviderLoop
open Data

theorem mapM_append_ok {α β : Type} {f : α → KernelM β} {xs ys : List α} {zs : List β} {j k : List Term}
    (h : (xs ++ ys).mapM f j = .ok (zs, k)) :
    ∃ as bs j₁, xs.mapM f j = .ok (as, j₁) ∧ ys.mapM f j₁ = .ok (bs, k) ∧ zs = as ++ bs := by
  rw [List.mapM_append] at h
  obtain ⟨as, j₁, ha, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨bs, j₂, hb, h⟩ := Session.bind_ok_iff.mp h
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  exact ⟨as, bs, j₁, ha, by rw [h.2]; exact hb, h.1⟩

theorem mapM_append_mk {α β : Type} {f : α → KernelM β} {xs ys : List α} {as bs : List β} {j j₁ k : List Term}
    (ha : xs.mapM f j = .ok (as, j₁)) (hb : ys.mapM f j₁ = .ok (bs, k)) :
    (xs ++ ys).mapM f j = .ok (as ++ bs, k) := by
  rw [List.mapM_append]
  exact Session.bind_ok_iff.mpr ⟨as, j₁, ha, Session.bind_ok_iff.mpr ⟨bs, k, hb, rfl⟩⟩

/-- An element of the input of a successful `mapM` has its image in the output. -/
theorem mapM_mem_ok {α β : Type} {f : α → KernelM β} :
    ∀ {xs : List α} {ys : List β} {j k : List Term} {x : α}, xs.mapM f j = .ok (ys, k) → x ∈ xs →
      ∃ y j' k', f x j' = .ok (y, k') ∧ y ∈ ys
  | [], _, _, _, _, _, member => by simp at member
  | x :: xs, ys, j, k, x', h, member => by
    rw [List.mapM_cons] at h
    obtain ⟨y, j₁, hy, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨ys', j₂, hys, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]
    rcases List.mem_cons.mp member with rfl | tail
    · exact ⟨y, j, j₁, hy, List.mem_cons_self ..⟩
    · obtain ⟨y', j', k', hy', mem⟩ := mapM_mem_ok hys tail
      exact ⟨y', j', k', hy', List.mem_cons_of_mem _ mem⟩

/-- Two successful runs of a stateless action return the same value. -/
theorem _root_.VerifiedKernel.Stateless.same {α : Type} {m : KernelM α} (h : Stateless m) {j₁ j₂ k₁ k₂ : List Term} {v₁ v₂ : α}
    (h₁ : m j₁ = .ok (v₁, k₁)) (h₂ : m j₂ = .ok (v₂, k₂)) : v₁ = v₂ := by
  have := h.run h₁ j₂
  rw [this] at h₂
  simp only [Except.ok.injEq, Prod.mk.injEq] at h₂
  exact h₂.1

instance byteArrayLawfulBEq : LawfulBEq ByteArray where
  eq_of_beq := by
    intro left right same
    exact ByteArray.ext (eq_of_beq same)
  rfl := by
    intro value
    change (value.data == value.data) = true
    exact beq_self_eq_true _

theorem binary_beq {x y : ByteArray} : (Term.binary x == Term.binary y) = (x == y) := rfl

theorem text_beq_eq {t : Term} {s : String} (h : (t == Term.text s) = true) : t = Term.text s := by
  cases t <;> simp only [Term.text, BEq.beq] at h ⊢ <;> try contradiction
  rw [eq_of_beq (α := ByteArray) h]

theorem text_beq_ne {k l : String} (h : l ≠ k) : (Term.text l == Term.text k) = false := by
  rw [Term.text, Term.text, binary_beq]
  exact beq_false_of_ne fun same => h (String.toByteArray_inj.mp same)

/-- `get` reads past a `put` under another binary key. -/
theorem get_put_text_other (v x : Term) {k l : String} (h : l ≠ k) :
    (v.put (b l) x).get (b k) = v.get (b k) := by
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons, b, text_beq_ne h]
    rw [Session.find?_filter_of_imp]
    intro e he
    rw [text_beq_eq he, text_beq_ne (Ne.symm h)]
    rfl
  | _ => simp [Term.put, Term.get, b, text_beq_ne h]

theorem get_put_text_same (v x : Term) (k : String) : (v.put (b k) x).get (b k) = x := by
  have self : (Term.text k == Term.text k) = true := by rw [Term.text, binary_beq]; exact beq_self_eq_true _
  cases v <;> simp [Term.put, Term.get, b, self]

theorem get_putOptional_other (v x : Term) {k l : String} (h : l ≠ k) :
    (Provider.putOptional v l x).get (b k) = v.get (b k) := by
  unfold Provider.putOptional
  split
  · rfl
  · exact get_put_text_other v x h

end VerifiedKernel.ProviderLoop

namespace VerifiedKernel.ProviderLoop
open Data

/-- An element of the output of a successful `mapM` is the image of an input element. -/
theorem mapM_out_mem {α β : Type} {f : α → KernelM β} :
    ∀ {xs : List α} {ys : List β} {j k : List Term} {y : β}, xs.mapM f j = .ok (ys, k) → y ∈ ys →
      ∃ x ∈ xs, ∃ j' k', f x j' = .ok (y, k')
  | [], ys, j, k, y, h, member => by
    rw [List.mapM_nil] at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1] at member
    simp at member
  | x :: xs, ys, j, k, y, h, member => by
    rw [List.mapM_cons] at h
    obtain ⟨y', j₁, hy, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨ys', j₂, hys, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1] at member
    rcases List.mem_cons.mp member with rfl | tail
    · exact ⟨x, List.mem_cons_self .., j, j₁, hy⟩
    · obtain ⟨x', mem, j', k', hx⟩ := mapM_out_mem hys tail
      exact ⟨x', List.mem_cons_of_mem _ mem, j', k', hx⟩

end VerifiedKernel.ProviderLoop
