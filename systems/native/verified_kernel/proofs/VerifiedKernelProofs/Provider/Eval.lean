import VerifiedKernelProofs.Provider.Loop

/-!
Symbolic evaluation of the literal maps that the provider projection builds.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider

theorem text_ne_atom (s k : String) : (Term.atom k == Term.text s) = false := rfl
theorem atom_ne_text (s k : String) : (Term.text s == Term.atom k) = false := rfl

theorem find_text_keys_atom (fs : List (String × Term)) (k : String) :
    (fs.map fun (key, v) => (b key, v)).find? (fun entry => entry.1 == a k) = none := by
  induction fs with
  | nil => rfl
  | cons f fs ih => simp only [List.map_cons, List.find?_cons, b, atom_ne_text]; exact ih

@[simp] theorem obj_get_atom (fs : List (String × Term)) (k : String) : (obj fs).get (a k) = nil := by
  simp only [obj, Term.get, find_text_keys_atom]; rfl

@[simp] theorem obj_nil_get (k : Term) : (obj []).get k = nil := rfl

@[simp] theorem obj_get_cons_same (fs : List (String × Term)) (k : String) (v : Term) :
    (obj ((k, v) :: fs)).get (b k) = v := by
  have self : (Term.text k == Term.text k) = true := by rw [Term.text, binary_beq]; exact beq_self_eq_true _
  simp [obj, Term.get, b, self]

theorem obj_get_cons_ne (fs : List (String × Term)) {k l : String} (v : Term) (h : k ≠ l) :
    (obj ((k, v) :: fs)).get (b l) = (obj fs).get (b l) := by
  simp [obj, Term.get, b, text_beq_ne h]

@[simp] theorem field_obj (fs : List (String × Term)) (k : String) : Provider.field (obj fs) k = get (obj fs) k := by
  simp [Provider.field, Term.truthy, nil]

@[simp] theorem truthy_nil : nil.truthy = false := rfl

@[simp] theorem get_obj_cons_same (fs : List (String × Term)) (k : String) (v : Term) :
    Provider.get (obj ((k, v) :: fs)) k = v := obj_get_cons_same fs k v

theorem get_obj_cons_ne (fs : List (String × Term)) {k l : String} (v : Term) (h : k ≠ l) :
    Provider.get (obj ((k, v) :: fs)) l = Provider.get (obj fs) l := obj_get_cons_ne fs v h

@[simp] theorem get_obj_nil (k : String) : Provider.get (obj []) k = nil := rfl

theorem pget_put_other (v x : Term) {k l : String} (h : l ≠ k) :
    Provider.get (v.put (b l) x) k = Provider.get v k := get_put_text_other v x h

@[simp] theorem pget_put_same (v x : Term) (k : String) : Provider.get (v.put (b k) x) k = x :=
  get_put_text_same v x k

@[simp] theorem coalesce_empty : coalesce [] = nil := rfl
@[simp] theorem pget_nil (k : String) : Provider.get nil k = nil := rfl
@[simp] theorem nil_get (k : Term) : nil.get k = nil := rfl

@[simp] theorem truthy_binary (r : ByteArray) : (Term.binary r).truthy = true := rfl
@[simp] theorem truthy_text (s : String) : (b s).truthy = true := rfl
@[simp] theorem truthy_list (xs : List Term) : (list xs).truthy = true := rfl
@[simp] theorem truthy_map (xs : List (Term × Term)) : (Term.map xs).truthy = true := rfl

@[simp] theorem coalesce_cons_truthy {x : Term} (xs : List Term) (h : x.truthy = true) :
    coalesce (x :: xs) = x := by simp [coalesce, List.find?_cons, h]

@[simp] theorem coalesce_text_cons (s : String) (xs : List Term) : coalesce (b s :: xs) = b s := rfl
@[simp] theorem coalesce_list_cons (ys xs : List Term) : coalesce (list ys :: xs) = list ys := rfl
@[simp] theorem coalesce_map_cons (ys : List (Term × Term)) (xs : List Term) : coalesce (Term.map ys :: xs) = Term.map ys := rfl

@[simp] theorem coalesce_cons_nil (xs : List Term) : coalesce (nil :: xs) = coalesce xs := by
  simp [coalesce, List.find?_cons, truthy_nil]

@[simp] theorem text_beq_text (s t : String) : (b s == b t) = decide (s = t) := by
  by_cases h : s = t
  · subst h; simp only [decide_true]; rw [b, Term.text, binary_beq]; exact beq_self_eq_true _
  · simp only [h, decide_false]; exact text_beq_ne h

@[simp] theorem text_bne_text (s t : String) : (b s != b t) = !decide (s = t) := by
  simp [bne, text_beq_text]

@[simp] theorem member_text (s : String) (l : List String) : member (b s) l = l.any (fun t => decide (s = t)) := by
  simp [member, text_beq_text]

@[simp] theorem str_binary_ok (r : ByteArray) (j : List Term) : str (.binary r) j = .ok (.binary r, j) := rfl
@[simp] theorem str_text_ok (s : String) (j : List Term) : str (b s) j = .ok (b s, j) := rfl
@[simp] theorem items_list (xs : List Term) : items (list xs) = xs := rfl
@[simp] theorem items_nil : items nil = [] := rfl

end VerifiedKernel.ProviderLoop

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

/-- The assistant half of a synthetic runtime call. -/
def syntheticCall (id trailing args : Term) : Term :=
  obj [("role", b "assistant"), ("content", b ""), ("runtime_trailing", trailing),
    ("provider_meta", obj [("chat_message_extra", obj [("reasoning_content", b "")])]),
    ("tool_calls", list [obj [("id", id), ("name", b runtimeToolName), ("args", args)]])]

/-- The tool-result half of a synthetic runtime call. -/
def syntheticResult (id trailing content : Term) : Term :=
  obj [("role", b "tool"), ("tool_call_id", id), ("runtime_trailing", trailing), ("content", content)]

theorem toolName_runtime : toolName (b runtimeToolName) = true := by
  have bytes : "get_runtime_message".toUTF8 =
      ⟨#[103, 101, 116, 95, 114, 117, 110, 116, 105, 109, 101, 95, 109, 101, 115, 115, 97, 103, 101]⟩ := by rfl
  simp only [toolName, b, Term.text, runtimeToolName, bytes, Provider.bytes, Term.isBinary]
  rw [← Array.all_toList]
  decide

theorem runtimeCall_ok {m id : Term} {reminder : Bool} {j ys k : List Term}
    (h : runtimeCall m id reminder j = .ok (ys, k)) :
    ∃ trailing args content, ys = [syntheticCall id trailing args, syntheticResult id trailing content] := by
  unfold runtimeCall at h
  simp only [Session.bind_ok_iff, Session.pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨_, _, _, _, _, _, h⟩ := h
  exact ⟨_, _, _, h.1⟩

end VerifiedKernel.ProviderLoop

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

/-- Walks an execution hypothesis `f args j = .ok (x, k)` to its `pure` leaves, substituting the
result. Failure leaves close. -/
syntax "exec_walk" ident : tactic
macro_rules
  | `(tactic| exec_walk $h:ident) => `(tactic| repeat' first
      | (simp only [Session.pure_ok_iff, Prod.mk.injEq] at $h:ident
         obtain ⟨value, journal⟩ := $h
         (try subst value); (try subst journal))
      | (simp only [Session.fail_ok_iff] at $h:ident)
      | split at $h:ident
      | (have step := Session.bind_ok_iff.mp $h; clear $h; obtain ⟨_, _, _, $h:ident⟩ := step))

theorem context_ok {text v : Term} {j k : List Term} (h : context text j = .ok (v, k)) :
    ∃ c, v = obj [("role", b "user"), ("content", c)] := by
  unfold context at h
  exec_walk h
  exact ⟨_, rfl⟩

end VerifiedKernel.ProviderLoop

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

/-- `responsesMessage` and `chatMessage` read the role as text; `openaiRole` reads it as a term.
They agree on every role that a literal list of role names contains. -/
theorem stringChars_atom {name : String} (h : name ≠ "nil") (j : List Term) :
    stringChars (.atom name) j = .ok (b name, j) := by
  simp [stringChars, h]; rfl

theorem str_role_member {y r : Term} {L : List String} {j k : List Term} (noNil : "nil" ∉ L) (noFalse : "false" ∉ L)
    (h : str (coalesce [Provider.field y "role", b ""]) j = .ok (r, k)) (hm : member (openaiRole y) L = true) :
    r = openaiRole y := by
  unfold openaiRole at hm ⊢
  have binary : ∀ t : Term, member t L = true → ∃ s, t = b s := by
    intro t ht
    obtain ⟨s, -, hs⟩ := List.any_eq_true.mp ht
    exact ⟨s, text_beq_eq hs⟩
  generalize hr : Provider.field y "role" = role at h hm ⊢
  cases role with
  | atom name =>
    by_cases truthy : (Term.atom name).truthy = true
    · rw [coalesce_cons_truthy _ truthy] at h
      have hn : name ≠ "nil" := by rintro rfl; exact absurd truthy (by decide)
      simp only [str, stringChars_atom hn, Except.ok.injEq, Prod.mk.injEq] at h
      exact h.1.symm
    · exfalso
      have : name = "nil" ∨ name = "false" := by
        simp only [Term.truthy] at truthy; split at truthy <;> simp_all
      rcases this with rfl | rfl <;> simp_all [member_text, List.any_eq_true]
  | binary raw =>
    simp only [coalesce_cons_truthy _ (truthy_binary raw), str_binary_ok, Except.ok.injEq, Prod.mk.injEq] at h
    exact h.1.symm
  | _ =>
    obtain ⟨s, hs⟩ := binary _ hm
    cases hs

end VerifiedKernel.ProviderLoop
