import VerifiedKernelProofs.Provider.Eval
import VerifiedKernelProofs.Provider.TermRefl

/-!
Closed histories: every tool call has a later result with its id.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

/-- The tool-call ids of an assistant message. -/
def callsOf (m : Term) : List Term :=
  if (openaiRole m == b "assistant") = true then (items (Provider.field m "tool_calls")).map (callField · "id") else []

/-- A tool result. -/
def IsResult (m : Term) : Prop := (openaiRole m == b "tool") = true

/-- Every tool call of the list has a later tool result with its id. -/
def Answered : List Term → Prop
  | [] => True
  | m :: L => (∀ c ∈ callsOf m, ∃ r ∈ L, IsResult r ∧ c = callId r) ∧ Answered L

/-- A message that is neither a call nor a result. -/
def Inert (m : Term) : Prop := callsOf m = [] ∧ ¬ IsResult m

theorem Answered.append_right : ∀ {X Y : List Term}, Answered (X ++ Y) → Answered Y
  | [], _, h => h
  | _ :: X, _, h => Answered.append_right h.2

theorem Answered.cons_iff {m : Term} {L : List Term} :
    Answered (m :: L) ↔ (∀ c ∈ callsOf m, ∃ r ∈ L, IsResult r ∧ c = callId r) ∧ Answered L := Iff.rfl

theorem Answered.append : ∀ {Q Y : List Term}, Answered Q → Answered Y → Answered (Q ++ Y)
  | [], _, _, hy => hy
  | q :: Q, Y, ⟨head, tail⟩, hy => ⟨fun c hc => by
      obtain ⟨r, mem, res, eq⟩ := head c hc
      exact ⟨r, List.mem_append_left _ mem, res, eq⟩, Answered.append tail hy⟩

/-- Moves a message without calls in front of a self-answered block. -/
theorem Answered.move : ∀ {X Q Y : List Term} {m : Term}, Answered Q → (callsOf m = []) →
    Answered (X ++ Q ++ m :: Y) → Answered (X ++ m :: Q ++ Y)
  | [], Q, Y, m, hq, hm, h => by
    simp only [List.nil_append] at h ⊢
    exact ⟨by simp [hm], Answered.append hq (Answered.append_right h).2⟩
  | x :: X, Q, Y, m, hq, hm, h => by
    refine ⟨fun c hc => ?_, Answered.move hq hm h.2⟩
    obtain ⟨r, mem, res, eq⟩ := h.1 c hc
    refine ⟨r, ?_, res, eq⟩
    simp only [List.append_eq, List.mem_append, List.mem_cons] at mem ⊢
    rcases mem with (mem | mem) | mem | mem <;> simp [mem]

/-- Replaces an inert message by a self-answered block. -/
theorem Answered.replace : ∀ {X Y P : List Term} {m : Term}, Answered P → Inert m →
    Answered (X ++ m :: Y) → Answered (X ++ P ++ Y)
  | [], Y, P, m, hp, _, h => Answered.append hp h.2
  | x :: X, Y, P, m, hp, hm, h => by
    refine ⟨fun c hc => ?_, Answered.replace hp hm h.2⟩
    obtain ⟨r, mem, res, eq⟩ := h.1 c hc
    refine ⟨r, ?_, res, eq⟩
    simp only [List.append_eq, List.mem_append, List.mem_cons] at mem ⊢
    rcases mem with mem | rfl | mem
    · simp [mem]
    · exact absurd res hm.2
    · simp [mem]

theorem binary_beq_self (r : ByteArray) : (Term.binary r == Term.binary r) = true := by
  rw [binary_beq]; exact beq_self_eq_true _

theorem synthetic_pair_answered (raw : ByteArray) (t args c : Term) :
    Answered [syntheticCall (.binary raw) t args, syntheticResult (.binary raw) t c] := by
  refine ⟨fun x hx => ⟨syntheticResult (.binary raw) t c, List.mem_cons_self .., ?_, ?_⟩, ?_, trivial⟩
  · unfold IsResult openaiRole; simp (config := {decide := true}) [syntheticResult]
  · unfold callsOf openaiRole at hx
    simp (config := {decide := true}) [syntheticCall, get_obj_cons_ne, callField] at hx
    subst hx
    simp (config := {decide := true}) [callId, syntheticResult, get_obj_cons_ne]
  · intro x hx
    unfold callsOf openaiRole at hx
    simp (config := {decide := true}) [syntheticResult, get_obj_cons_ne] at hx

theorem syntheticCall_not_result (id t args : Term) : ¬ IsResult (syntheticCall id t args) := by
  unfold IsResult openaiRole; simp (config := {decide := true}) [syntheticCall]

theorem runtimeCall_answered {m : Term} {raw : ByteArray} {reminder : Bool} {j w k : List Term}
    (h : runtimeCall m (.binary raw) reminder j = .ok (w, k)) : Answered w := by
  obtain ⟨t, args, c, rfl⟩ := runtimeCall_ok h
  exact synthetic_pair_answered raw t args c

theorem Answered.reverse_pair {w : List Term} (h : Answered w) : Answered w.reverse.reverse := by
  simpa using h

theorem Answered.replace' {X Y P : List Term} {m : Term} (hp : Answered P) (hm : Inert m)
    (h : Answered (X ++ m :: Y)) : Answered (X ++ (P ++ Y)) := by
  rw [← List.append_assoc]; exact Answered.replace hp hm h

theorem Answered.move' {X Q Y : List Term} {m : Term} (hq : Answered Q) (hm : callsOf m = [])
    (h : Answered (X ++ (Q ++ m :: Y))) : Answered (X ++ m :: (Q ++ Y)) := by
  have := Answered.move (X := X) hq hm (by rw [List.append_assoc]; exact h)
  simpa using this

theorem callsOf_of_not_assistant {m : Term} (h : ¬ (openaiRole m == b "assistant") = true) : callsOf m = [] := by
  unfold callsOf; rw [if_neg h]

theorem callsOf_of_tool {m : Term} (h : (openaiRole m == b "tool") = true) : callsOf m = [] := by
  apply callsOf_of_not_assistant
  rw [text_beq_eq h]; simp (config := {decide := true}) [text_beq_text]

theorem Answered.replaceAfter {X Q Y P : List Term} {m : Term} (h : Answered (X ++ (Q ++ m :: Y)))
    (hm : Inert m) (hp : Answered P) : Answered (X ++ (Q ++ (P ++ Y))) := by
  have := Answered.replace' (X := X ++ Q) hp hm (by simpa using h)
  simpa using this

end VerifiedKernel.ProviderLoop
