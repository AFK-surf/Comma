import VerifiedKernelProofs.Provider.AnsweredCore
import VerifiedKernelProofs.Provider.CallKey

/-!
Matched histories: each tool result answers the newest waiting call with an equivalent id, and
no call waits at the end. The chat projection binds results this way.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-- The calls that wait for a result after `m`, newest first. A result removes the newest
waiting call with an equivalent id. -/
def openStep (st : List Term) (m : Term) : List Term :=
  if (openaiRole m == b "tool") = true then st.eraseP (fun c => CallKey.mk c == CallKey.mk (callId m))
  else (callsOf m).reverse ++ st

/-- No call waits after the history. -/
def Matched (L : List Term) : Prop := L.foldl openStep [] = []

/-- A block that leaves every waiting list unchanged. -/
def Balanced (L : List Term) : Prop := ∀ st, L.foldl openStep st = st

theorem Balanced.nil : Balanced [] := fun _ => rfl

theorem Balanced.append {X Y : List Term} (hx : Balanced X) (hy : Balanced Y) : Balanced (X ++ Y) := by
  intro st; rw [List.foldl_append, hx, hy]

theorem openStep_inert {m : Term} (h : Inert m) (st : List Term) : openStep st m = st := by
  unfold openStep
  rw [if_neg (show ¬ (openaiRole m == b "tool") = true from h.2), h.1]; rfl

theorem openStep_callless {m : Term} (h : callsOf m = []) (hr : ¬ IsResult m) (st : List Term) :
    openStep st m = st := openStep_inert ⟨h, hr⟩ st

theorem synthetic_pair_balanced (raw : ByteArray) (t args c : Term) :
    Balanced [syntheticCall (.binary raw) t args, syntheticResult (.binary raw) t c] := by
  intro st
  have hr : IsResult (syntheticResult (.binary raw) t c) := by
    unfold IsResult openaiRole; simp (config := {decide := true}) [syntheticResult]
  have hid : callId (syntheticResult (.binary raw) t c) = .binary raw := by
    simp (config := {decide := true}) [callId, syntheticResult, get_obj_cons_ne,
      coalesce_cons_truthy _ (truthy_binary raw)]
  simp only [List.foldl_cons, List.foldl_nil]
  unfold openStep
  have hc : callsOf (syntheticCall (.binary raw) t args) = [.binary raw] := by
    unfold callsOf openaiRole
    simp (config := {decide := true}) [syntheticCall, get_obj_cons_ne, callField,
      coalesce_cons_truthy _ (truthy_binary raw)]
  rw [if_neg (show ¬ (openaiRole (syntheticCall (.binary raw) t args) == b "tool") = true from
    syntheticCall_not_result _ _ _), hc, if_pos (show (openaiRole (syntheticResult (.binary raw) t c) == b "tool") = true from hr), hid]
  simp [BEq.rfl]

theorem runtimeCall_balanced {m : Term} {raw : ByteArray} {reminder : Bool} {j w k : List Term}
    (h : runtimeCall m (.binary raw) reminder j = .ok (w, k)) : Balanced w := by
  obtain ⟨t, args, c, rfl⟩ := runtimeCall_ok h
  exact synthetic_pair_balanced raw t args c

/-! ### Matched histories answer every call -/

/-- Every tool call of the list has a later tool result with an equal id. -/
def AnsweredEq : List Term → Prop
  | [] => True
  | m :: L => (∀ c ∈ callsOf m, ∃ r ∈ L, IsResult r ∧ (c == callId r) = true) ∧ AnsweredEq L

theorem AnsweredEq.append_right : ∀ {X Y : List Term}, AnsweredEq (X ++ Y) → AnsweredEq Y
  | [], _, h => h
  | _ :: X, _, h => AnsweredEq.append_right (X := X) h.2

theorem AnsweredEq.drop_takeWhile {p : Term → Bool} {L : List Term} (h : AnsweredEq L) :
    AnsweredEq (L.drop (L.takeWhile p).length) := by
  have split : L.takeWhile p ++ L.drop (L.takeWhile p).length = L := by
    conv => rhs; rw [← List.take_append_drop (L.takeWhile p).length L]
    rw [← List.prefix_iff_eq_take.mp (List.takeWhile_prefix p)]
  rw [← split] at h
  exact AnsweredEq.append_right h

theorem mem_eraseP_or {l : List Term} {p : Term → Bool} {c : Term} (h : c ∈ l) :
    c ∈ l.eraseP p ∨ p c = true := by
  cases hc : p c
  · exact .inl ((List.mem_eraseP_of_neg (by simp [hc])).mpr h)
  · exact .inr rfl

theorem matched_answeredEq : ∀ (L st : List Term), L.foldl openStep st = [] →
    (∀ c ∈ st, ∃ r ∈ L, IsResult r ∧ (c == callId r) = true) ∧ AnsweredEq L
  | [], st, h => ⟨(fun c hc => by simp only [List.foldl_nil] at h; rw [h] at hc; cases hc), trivial⟩
  | m :: L, st, h => by
    rw [List.foldl_cons] at h
    obtain ⟨hst, hL⟩ := matched_answeredEq L _ h
    unfold openStep at hst
    split at hst
    · rename_i hres
      refine ⟨fun c hc => ?_, fun c hc => ?_, hL⟩
      · rcases mem_eraseP_or (p := fun c => CallKey.mk c == CallKey.mk (callId m)) hc with hc | hk
        · obtain ⟨r, hr, res, e⟩ := hst c hc
          exact ⟨r, List.mem_cons_of_mem _ hr, res, e⟩
        · change (c == callId m && callId m == c) = true at hk
          simp only [Bool.and_eq_true] at hk
          exact ⟨m, List.mem_cons_self .., hres, hk.1⟩
      · rw [callsOf_of_tool hres] at hc; cases hc
    · refine ⟨fun c hc => ?_, fun c hc => hst c (List.mem_append_left _ (List.mem_reverse.mpr hc)), hL⟩
      obtain ⟨r, hr, res, e⟩ := hst c (List.mem_append_right _ hc)
      exact ⟨r, List.mem_cons_of_mem _ hr, res, e⟩

/-- A matched history gives every call a later result with an equal id. -/
theorem Matched.answeredEq {L : List Term} (h : Matched L) : AnsweredEq L := (matched_answeredEq L [] h).2

end VerifiedKernel.ProviderLoop
