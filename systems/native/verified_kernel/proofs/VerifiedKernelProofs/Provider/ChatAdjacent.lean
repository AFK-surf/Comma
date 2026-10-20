import VerifiedKernelProofs.Provider.CallKey
import VerifiedKernelProofs.Provider.Eval

/-!
Chat adjacency: `adjacentChat` of an extension keeps the projection of a history whose tool
calls are all answered and have distinct ids as a prefix.

The first pass of `adjacentChat` is a pure fold (`ChatAdj.step1`). For a position of the history,
the second pass reads only the recorded results at that position's call ids and whether the
position is unclaimed. Every call of the history already has a recorded result after the
history (`ChatAdj.inv_fold`), a recorded result never changes (`ChatAdj.fold_keep`), and later
messages only mark later positions unclaimed.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-- The tool-call ids of a chat-protocol assistant message. -/
def chatCalls (m : Term) : List Term :=
  if (get m "role" == b "assistant") = true then (items (get m "tool_calls")).map (get · "id") else []

/-- Every chat tool call has a later tool message with its id. -/
def ChatAnswered : List Term → Prop
  | [] => True
  | m :: L => (∀ c ∈ chatCalls m, ∃ r ∈ L, (get r "role" == b "tool") = true ∧
      r.has (b "tool_call_id") = true ∧ get r "tool_call_id" = c) ∧ ChatAnswered L

/-- No two chat tool calls have equivalent ids. -/
def ChatDistinct (xs : List Term) : Prop :=
  (xs.flatMap chatCalls).Pairwise fun x y => (CallKey.mk x == CallKey.mk y) = false

namespace ChatAdj

/-- The state of the first pass: call owners, results by position, and unclaimed positions. -/
abbrev St := CallMap Nat × Array (CallMap Term) × Std.HashSet Nat

/-- The body of the first pass, as `adjacentChat` elaborates it. -/
def body1 : Term × Nat → St → KernelM (ForInStep St) := fun x __s =>
  have owners := __s.fst
  have __s := __s.snd
  have results := __s.fst
  have unclaimed := __s.snd
  match x with
  | (m, index) =>
    if (get m "role" == b "assistant") = true then do
      let __s ← forIn (items (get m "tool_calls")) owners fun c __s =>
          have owners := __s
          have owners := Std.HashMap.insert owners { value := get c "id" } index
          pure (ForInStep.yield owners)
      have owners : CallMap Nat := __s
      pure (ForInStep.yield (owners, results, unclaimed))
    else if (get m "role" == b "tool" && m.has (b "tool_call_id")) = true then
      have id := get m "tool_call_id"
      match Std.HashMap.get? owners { value := id } with
      | some owner =>
        if (!Std.HashMap.contains results[owner]! { value := id }) = true then
          have results := results.modify owner fun entries => Std.HashMap.insert entries { value := id } m
          pure (ForInStep.yield (owners, results, unclaimed))
        else pure (ForInStep.yield (owners, results, unclaimed))
      | _ =>
        have unclaimed := unclaimed.insert index
        pure (ForInStep.yield (owners, results, unclaimed))
    else pure (ForInStep.yield (owners, results, unclaimed))

/-- The body of the call loop of the second pass. -/
def inner2 (r : CallMap Term) : Term → List Term → KernelM (ForInStep (List Term)) := fun c __s =>
  have out := __s
  have id := get c "id"
  have value := coalesce [Std.HashMap.getD r { value := id } nil,
    obj [("role", b "tool"), ("tool_call_id", id), ("content", b "{\"status\":\"no_result_recorded\"}")]]
  have out := value :: out
  pure (ForInStep.yield out)

/-- The body of the second pass at one message, given its recorded results and unclaimed flag. -/
def body2' (r : CallMap Term) (u : Bool) (m : Term) (out : List Term) : KernelM (ForInStep (List Term)) :=
  have calls := items (get m "tool_calls")
  if (get m "role" == b "assistant" && !calls.isEmpty) = true then
    have out := m :: out
    do
    let __s ← forIn calls out (inner2 r)
    have out : List Term := __s
    pure (ForInStep.yield out)
  else if (get m "role" == b "tool" && m.has (b "tool_call_id")) = true then
    have id := get m "tool_call_id"
    if u = true then do
      let __do_lift ← cat [b "<unclaimed-tool-result call_id=\"", id, b "\">\n", get m "content",
        b "\n</unclaimed-tool-result>"]
      let __do_lift ← context __do_lift
      have out : List Term := __do_lift :: out
      pure (ForInStep.yield out)
    else pure (ForInStep.yield out)
  else
    have out := m :: out
    pure (ForInStep.yield out)

/-- The body of the second pass. -/
def body2 (R : Array (CallMap Term)) (U : Std.HashSet Nat) :
    Term × Nat → List Term → KernelM (ForInStep (List Term)) :=
  fun x __s => body2' R[x.2]! (U.contains x.2) x.1 __s

/-- The reasoning normalization of one message. -/
def normalize (m : Term) : Term :=
  if (get m "role" == b "assistant" && !m.has (b "reasoning_content")) = true then
    m.put (b "reasoning_content") (b "") else m

/-- The reasoning normalization of the output. -/
def finish (out : List Term) : KernelM (List Term) := pure (out.map normalize)

/-- The initial state of the first pass. -/
def init (n : Nat) : St := ((∅ : CallMap Nat), Array.replicate n (∅ : CallMap Term), (∅ : Std.HashSet Nat))

theorem adjacentChat_eq (chat : List Term) : adjacentChat chat =
    (forIn chat.zipIdx (init chat.length) body1 >>= fun s =>
      forIn chat.zipIdx ([] : List Term) (body2 s.2.1 s.2.2) >>= fun o => finish o.reverse) := rfl


/-- Binds a call id to its owner position. -/
def ownersStep (index : Nat) (o : CallMap Nat) (c : Term) : CallMap Nat := o.insert ⟨get c "id"⟩ index

/-- One step of the first pass as a pure function. -/
def step1 (s : St) (x : Term × Nat) : St :=
  if (get x.1 "role" == b "assistant") = true then
    ((items (get x.1 "tool_calls")).foldl (ownersStep x.2) s.1, s.2.1, s.2.2)
  else if (get x.1 "role" == b "tool" && x.1.has (b "tool_call_id")) = true then
    match s.1.get? ⟨get x.1 "tool_call_id"⟩ with
    | some owner =>
      if (!(s.2.1[owner]!).contains ⟨get x.1 "tool_call_id"⟩) = true then
        (s.1, s.2.1.modify owner (fun e => e.insert ⟨get x.1 "tool_call_id"⟩ x.1), s.2.2)
      else s
    | none => (s.1, s.2.1, s.2.2.insert x.2)
  else s

theorem body1_eq : body1 = fun x s => pure (.yield (step1 s x)) := by
  funext x s
  obtain ⟨m, i⟩ := x
  obtain ⟨o, R, U⟩ := s
  simp only [body1, step1]
  split
  · simp only [List.forIn_pure_yield_eq_foldl, pure_bind]
    rfl
  · split
    · cases hg : Std.HashMap.get? o { value := get m "tool_call_id" } with
      | none => rfl
      | some owner => dsimp only; split <;> rfl
    · rfl

theorem forIn_body1 (L : List (Term × Nat)) (s : St) : forIn L s body1 = pure (L.foldl step1 s) := by
  rw [body1_eq, List.forIn_pure_yield_eq_foldl]

theorem inner2_eq (r : CallMap Term) (calls out : List Term) :
    forIn calls out (inner2 r) = pure (calls.foldl (fun o c => coalesce [r.getD ⟨get c "id"⟩ nil,
      obj [("role", b "tool"), ("tool_call_id", get c "id"), ("content", b "{\"status\":\"no_result_recorded\"}")]] :: o) out) := by
  rw [show inner2 r = fun c o => pure (.yield (coalesce [r.getD ⟨get c "id"⟩ nil,
      obj [("role", b "tool"), ("tool_call_id", get c "id"), ("content", b "{\"status\":\"no_result_recorded\"}")]] :: o)) from rfl]
  rw [List.forIn_pure_yield_eq_foldl]


/-! ### Array and map access -/

theorem bang_eq (R : Array (CallMap Term)) (k : Nat) : R[k]! = (R[k]?).getD default := by
  rw [getElem!_def]; cases R[k]? <;> rfl

theorem bang_modify (R : Array (CallMap Term)) (o k : Nat) (f : CallMap Term → CallMap Term) :
    (R.modify o f)[k]! = if o = k ∧ k < R.size then f R[k]! else R[k]! := by
  rw [bang_eq, bang_eq, Array.getElem?_modify]
  by_cases hk : k < R.size
  · rw [Array.getElem?_eq_getElem hk]
    by_cases ho : o = k <;> simp [ho, hk]
  · rw [Array.getElem?_eq_none (by omega)]
    by_cases ho : o = k <;> simp [ho, hk]

theorem step1_size (s : St) (x : Term × Nat) : (step1 s x).2.1.size = s.2.1.size := by
  unfold step1
  split
  · rfl
  · split
    · split
      · split
        · exact Array.size_modify
        · rfl
      · rfl
    · rfl

theorem step1_owners (s : St) (x : Term × Nat) : (step1 s x).1 =
    if (get x.1 "role" == b "assistant") = true then (items (get x.1 "tool_calls")).foldl (ownersStep x.2) s.1
    else s.1 := by
  unfold step1
  split
  · rfl
  · split
    · split
      · split <;> rfl
      · rfl
    · rfl

theorem step1_unclaimed (s : St) (x : Term × Nat) {k : Nat} (hk : x.2 ≠ k) :
    (step1 s x).2.2.contains k = s.2.2.contains k := by
  unfold step1
  split
  · rfl
  · split
    · split
      · split <;> rfl
      · show (s.2.2.insert x.2).contains k = _
        rw [Std.HashSet.contains_insert, beq_false_of_ne hk, Bool.false_or]
    · rfl

/-- The condition under which one step inserts a result at position `k`. -/
def inserts (s : St) (x : Term × Nat) (k : Nat) : Prop :=
  (get x.1 "role" == b "assistant") = false ∧ (get x.1 "role" == b "tool" && x.1.has (b "tool_call_id")) = true ∧
    s.1.get? ⟨get x.1 "tool_call_id"⟩ = some k ∧ (s.2.1[k]!).contains ⟨get x.1 "tool_call_id"⟩ = false ∧
    k < s.2.1.size

instance (s : St) (x : Term × Nat) (k : Nat) : Decidable (inserts s x k) := by
  unfold inserts; infer_instance

theorem step1_bang (s : St) (x : Term × Nat) (k : Nat) :
    (step1 s x).2.1[k]! =
      if inserts s x k then (s.2.1[k]!).insert ⟨get x.1 "tool_call_id"⟩ x.1 else s.2.1[k]! := by
  unfold step1
  split
  · rename_i ha
    rw [if_neg (by simp [inserts, ha])]
  · rename_i ha
    split
    · rename_i ht
      cases hg : s.1.get? ⟨get x.1 "tool_call_id"⟩ with
      | none =>
        dsimp only
        rw [if_neg]
        rintro ⟨-, -, hg', -⟩
        rw [hg] at hg'
        cases hg'
      | some owner =>
        dsimp only
        split
        · rename_i hc
          rw [bang_modify]
          by_cases ho : owner = k
          · subst ho
            simp only [Bool.not_eq_true'] at hc
            by_cases hk : owner < s.2.1.size
            · rw [if_pos ⟨rfl, hk⟩, if_pos ⟨by simpa using ha, ht, hg, hc, hk⟩]
            · rw [if_neg (by simp [hk]), if_neg]
              rintro ⟨-, -, -, -, hk'⟩
              exact hk hk'
          · rw [if_neg (by simp [ho]), if_neg]
            rintro ⟨-, -, hg', -⟩
            rw [hg] at hg'
            exact ho (Option.some.inj hg')
        · rename_i hc
          rw [if_neg]
          rintro ⟨-, -, hg', hc', -⟩
          rw [hg] at hg'
          cases hg'
          simp [hc'] at hc
    · rename_i ht
      rw [if_neg (by simp [inserts, ht])]


/-! ### Results already recorded stay fixed -/

theorem step1_keep (s : St) (x : Term × Nat) (k : Nat) (key : CallKey) (h : (s.2.1[k]!).contains key = true) :
    ((step1 s x).2.1[k]!)[key]? = (s.2.1[k]!)[key]? := by
  rw [step1_bang]
  split
  · rename_i hi
    rw [Std.HashMap.getElem?_insert]
    split
    · rename_i he
      have := hi.2.2.2.1
      rw [Std.HashMap.contains_congr he, h] at this
      cases this
    · rfl
  · rfl

theorem contains_of_get {m : CallMap Term} {key : CallKey} :
    m.contains key = m[key]?.isSome := Std.HashMap.contains_eq_isSome_getElem?

theorem fold_keep : ∀ (T : List (Term × Nat)) (s : St) (k : Nat) (key : CallKey),
    (s.2.1[k]!).contains key = true → (((T.foldl step1 s).2.1[k]!)[key]?) = (s.2.1[k]!)[key]?
  | [], _, _, _, _ => rfl
  | x :: T, s, k, key, h => by
    have e := step1_keep s x k key h
    rw [List.foldl_cons, fold_keep T _ k key (by rw [contains_of_get, e, ← contains_of_get]; exact h), e]

theorem fold_size : ∀ (T : List (Term × Nat)) (s : St), (T.foldl step1 s).2.1.size = s.2.1.size
  | [], _ => rfl
  | x :: T, s => by rw [List.foldl_cons, fold_size T, step1_size]

theorem fold_unclaimed : ∀ (T : List (Term × Nat)) (s : St) (k : Nat), (∀ y ∈ T, y.2 ≠ k) →
    (T.foldl step1 s).2.2.contains k = s.2.2.contains k
  | [], _, _, _ => rfl
  | x :: T, s, k, h => by
    rw [List.foldl_cons, fold_unclaimed T _ k (fun y hy => h y (List.mem_cons_of_mem _ hy)),
      step1_unclaimed s x (h x (List.mem_cons_self ..))]

/-! ### A longer results array agrees below the shorter one's length -/

/-- Two first-pass states agree, and the second has results at least up to length `n`. -/
def Agr (n : Nat) (s t : St) : Prop :=
  s.1 = t.1 ∧ s.2.2 = t.2.2 ∧ s.2.1.size = n ∧ n ≤ t.2.1.size ∧ ∀ k < n, s.2.1[k]! = t.2.1[k]!

theorem inserts_agr {n : Nat} {s t : St} (h : Agr n s t) (x : Term × Nat) {k : Nat} (hk : k < n) :
    inserts s x k ↔ inserts t x k := by
  obtain ⟨ho, -, hs, ht, hR⟩ := h
  unfold inserts
  rw [ho, hR k hk]
  constructor
  · rintro ⟨a, b, c, d, -⟩; exact ⟨a, b, c, d, by omega⟩
  · rintro ⟨a, b, c, d, -⟩; exact ⟨a, b, c, d, by omega⟩

theorem Agr.step {n : Nat} {s t : St} (h : Agr n s t) (x : Term × Nat) : Agr n (step1 s x) (step1 t x) := by
  refine ⟨?_, ?_, ?_, ?_, ?_⟩
  · rw [step1_owners, step1_owners, h.1]
  · unfold step1
    obtain ⟨o, R, U⟩ := s
    obtain ⟨o', R', U'⟩ := t
    obtain ⟨ho, hU, -⟩ := h
    dsimp only at ho hU
    subst ho; subst hU
    dsimp only
    split
    · rfl
    · split
      · cases o.get? ⟨get x.1 "tool_call_id"⟩ with
        | none => rfl
        | some owner =>
          dsimp only
          split <;> split <;> rfl
      · rfl
  · rw [step1_size, h.2.2.1]
  · rw [step1_size]; exact h.2.2.2.1
  · intro k hk
    rw [step1_bang, step1_bang, h.2.2.2.2 k hk]
    by_cases hi : inserts s x k
    · rw [if_pos hi, if_pos ((inserts_agr h x hk).mp hi)]
    · rw [if_neg hi, if_neg (fun hi' => hi ((inserts_agr h x hk).mpr hi'))]

theorem Agr.fold {n : Nat} : ∀ (T : List (Term × Nat)) {s t : St}, Agr n s t → Agr n (T.foldl step1 s) (T.foldl step1 t)
  | [], _, _, h => h
  | x :: T, _, _, h => Agr.fold T (h.step x)


/-! ### Owners -/

theorem owners_keep (i : Nat) {key : CallKey} {o : CallMap Nat} (h : o.get? key = some i) :
    ∀ l : List Term, (l.foldl (ownersStep i) o).get? key = some i
  | [] => h
  | c :: l => by
    rw [List.foldl_cons]
    refine owners_keep i ?_ l
    rw [Std.HashMap.get?_eq_getElem?, ownersStep, Std.HashMap.getElem?_insert]
    split
    · rfl
    · rw [← Std.HashMap.get?_eq_getElem?]; exact h

theorem owners_mem (i : Nat) : ∀ (l : List Term) (o : CallMap Nat) {c : Term}, c ∈ l →
    (l.foldl (ownersStep i) o).get? ⟨get c "id"⟩ = some i
  | [], _, _, h => by cases h
  | c' :: l, o, c, h => by
    rw [List.foldl_cons]
    rcases List.mem_cons.mp h with rfl | h
    · refine owners_keep i ?_ l
      rw [Std.HashMap.get?_eq_getElem?, ownersStep, Std.HashMap.getElem?_insert, if_pos BEq.rfl]
    · exact owners_mem i l _ h

theorem owners_other (i : Nat) {key : CallKey} : ∀ (l : List Term) (o : CallMap Nat),
    (∀ c ∈ l, (CallKey.mk (get c "id") == key) = false) → (l.foldl (ownersStep i) o).get? key = o.get? key
  | [], _, _ => rfl
  | c :: l, o, h => by
    rw [List.foldl_cons, owners_other i l _ (fun d hd => h d (List.mem_cons_of_mem _ hd))]
    rw [Std.HashMap.get?_eq_getElem?, Std.HashMap.get?_eq_getElem?, ownersStep, Std.HashMap.getElem?_insert,
      if_neg (by rw [h c (List.mem_cons_self ..)]; decide)]

theorem mem_chatCalls {m c : Term} (h : c ∈ chatCalls m) :
    (get m "role" == b "assistant") = true ∧ ∃ c' ∈ items (get m "tool_calls"), get c' "id" = c := by
  unfold chatCalls at h
  split at h
  · exact ⟨‹_›, List.mem_map.mp h⟩
  · cases h

theorem chatCalls_of_mem {m c : Term} (ha : (get m "role" == b "assistant") = true)
    (h : c ∈ items (get m "tool_calls")) : get c "id" ∈ chatCalls m := by
  unfold chatCalls
  rw [if_pos ha]
  exact List.mem_map_of_mem h

/-! ### Every call of a closed prefix has a recorded result -/

/-- `r` is a tool message that answers call id `c`. -/
def Answers (r c : Term) : Prop :=
  (get r "role" == b "tool") = true ∧ r.has (b "tool_call_id") = true ∧ get r "tool_call_id" = c

/-- After processing `P`, each call of `P` has a recorded result, or is still owned and is
answered by a message of the rest `Q`. -/
def Inv (P Q : List (Term × Nat)) (s : St) : Prop :=
  ∀ x ∈ P, ∀ c ∈ chatCalls x.1, (s.2.1[x.2]!).contains ⟨c⟩ = true ∨
    (s.1.get? ⟨c⟩ = some x.2 ∧ ∃ z ∈ Q, Answers z.1 c)

/-- The calls of two messages have pairwise distinct ids. -/
def Dist (x y : Term × Nat) : Prop :=
  ∀ c ∈ chatCalls x.1, ∀ c' ∈ chatCalls y.1, (CallKey.mk c == CallKey.mk c') = false

theorem tool_not_assistant {r : Term} (h : (get r "role" == b "tool") = true) :
    (get r "role" == b "assistant") = false := by
  rw [text_beq_eq h]; decide

theorem step1_contains (s : St) (x : Term × Nat) (k : Nat) (key : CallKey)
    (h : (s.2.1[k]!).contains key = true) : ((step1 s x).2.1[k]!).contains key = true := by
  rw [contains_of_get, step1_keep s x k key h, ← contains_of_get]; exact h

theorem step1_answer (s : St) {x : Term × Nat} {c : Term} {k : Nat} (ha : Answers x.1 c)
    (ho : s.1.get? ⟨c⟩ = some k) (hk : k < s.2.1.size) : ((step1 s x).2.1[k]!).contains ⟨c⟩ = true := by
  obtain ⟨hr, hh, rfl⟩ := ha
  rw [step1_bang]
  split
  · rw [Std.HashMap.contains_insert, BEq.rfl, Bool.true_or]
  · rename_i hi
    cases hc : Std.HashMap.contains (s.2.1[k]!) ⟨get x.1 "tool_call_id"⟩
    · exact absurd ⟨tool_not_assistant hr, by rw [hr, hh]; rfl, ho, hc, hk⟩ hi
    · rfl

theorem inv_step {P Q : List (Term × Nat)} {s : St} {y : Term × Nat} (inv : Inv P (y :: Q) s)
    (ans : ∀ c ∈ chatCalls y.1, ∃ z ∈ Q, Answers z.1 c) (dist : ∀ x ∈ P, Dist x y)
    (size : ∀ x ∈ P, x.2 < s.2.1.size) : Inv (P ++ [y]) Q (step1 s y) := by
  intro x hx c hc
  rcases List.mem_append.mp hx with hxP | hx
  · rcases inv x hxP c hc with hcont | ⟨hown, z, hz, hans⟩
    · exact .inl (step1_contains s y _ _ hcont)
    · rcases List.mem_cons.mp hz with rfl | hz
      · exact .inl (step1_answer s hans hown (size x hxP))
      · refine .inr ⟨?_, z, hz, hans⟩
        rw [step1_owners]
        split
        · rename_i ha
          rw [owners_other _ _ _ ?_]
          · exact hown
          intro c' hc'
          rw [BEq.comm]
          exact dist x hxP c hc _ (chatCalls_of_mem ha hc')
        · exact hown
  · rw [List.mem_singleton] at hx
    subst hx
    obtain ⟨ha, c', hc', rfl⟩ := mem_chatCalls hc
    refine .inr ⟨?_, ans _ hc⟩
    rw [step1_owners, if_pos ha]
    exact owners_mem _ _ _ hc'

theorem inv_fold : ∀ (Q P : List (Term × Nat)) (s : St), Inv P Q s → ChatAnswered (Q.map Prod.fst) →
    (P ++ Q).Pairwise Dist → (∀ x ∈ P ++ Q, x.2 < s.2.1.size) → Inv (P ++ Q) [] (Q.foldl step1 s)
  | [], P, s, inv, _, _, _ => by simpa using inv
  | y :: Q, P, s, inv, ⟨ans, answered⟩, dist, size => by
    rw [List.foldl_cons]
    have cross : ∀ x ∈ P, Dist x y := fun x hx =>
      (List.pairwise_append.mp dist).2.2 x hx y (List.mem_cons_self ..)
    have e : P ++ y :: Q = (P ++ [y]) ++ Q := by simp
    rw [e] at dist size ⊢
    refine inv_fold Q (P ++ [y]) _ (inv_step inv ?_ cross ?_) answered dist ?_
    · intro c hc
      obtain ⟨r, hr, hans⟩ := ans c hc
      obtain ⟨z, hz, rfl⟩ := List.mem_map.mp hr
      exact ⟨z, hz, hans⟩
    · intro x hx
      exact size x (List.mem_append_left _ (List.mem_append_left _ hx))
    · intro x hx
      rw [step1_size]
      exact size x hx


/-! ### The second pass -/

theorem forIn_congr_mem {α σ : Type} {f g : α → σ → KernelM (ForInStep σ)} :
    ∀ {l : List α}, (∀ x ∈ l, f x = g x) → ∀ b : σ, forIn l b f = forIn l b g
  | [], _, _ => rfl
  | x :: l, h, b => by
    rw [List.forIn_cons, List.forIn_cons, h x (List.mem_cons_self ..)]
    congr 1
    funext r
    cases r with
    | done => rfl
    | yield b' => exact forIn_congr_mem (fun y hy => h y (List.mem_cons_of_mem _ hy)) b'

theorem body2'_congr {r₁ r₂ : CallMap Term} (u : Bool) (m : Term)
    (h : (get m "role" == b "assistant") = true →
      ∀ c ∈ items (get m "tool_calls"), r₁.getD ⟨get c "id"⟩ nil = r₂.getD ⟨get c "id"⟩ nil) :
    body2' r₁ u m = body2' r₂ u m := by
  funext out
  unfold body2'
  dsimp only
  split
  · rename_i hc
    have ha : (get m "role" == b "assistant") = true := by
      simp only [Bool.and_eq_true] at hc; exact hc.1
    rw [forIn_congr_mem (g := inner2 r₂)]
    intro c hc
    funext o
    show (pure (ForInStep.yield (coalesce [r₁.getD ⟨get c "id"⟩ nil, _] :: o)) : KernelM _) =
      pure (ForInStep.yield (coalesce [r₂.getD ⟨get c "id"⟩ nil, _] :: o))
    rw [h ha c hc]
  · rfl

theorem foldl_prepends {β : Type} (F : β → Term) : ∀ (l : List β) (o : List Term),
    Prepends (l.foldl (fun o c => F c :: o) o) o
  | [], o => Prepends.refl o
  | c :: l, o => by
    rw [List.foldl_cons]
    exact (foldl_prepends F l (F c :: o)).trans (Prepends.cons _ _)

theorem body2_ok {R : Array (CallMap Term)} {U : Std.HashSet Nat} {x : Term × Nat} {o : List Term}
    {j r : List Term} {s : ForInStep (List Term)} (h : body2 R U x o j = .ok (s, r)) :
    ∃ o', s = .yield o' ∧ Prepends o' o := by
  simp only [body2, body2', inner2_eq] at h
  split at h
  · simp only [pure_bind, Session.pure_ok_iff, Prod.mk.injEq] at h
    exact ⟨_, h.1, (foldl_prepends _ _ _).trans (Prepends.cons _ _)⟩
  · split at h
    · split at h
      · obtain ⟨_, _, _, h⟩ := Session.bind_ok_iff.mp h
        obtain ⟨_, _, _, h⟩ := Session.bind_ok_iff.mp h
        simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
        exact ⟨_, h.1, Prepends.cons _ _⟩
      · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
        exact ⟨_, h.1, Prepends.refl _⟩
    · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
      exact ⟨_, h.1, Prepends.cons _ _⟩

theorem body2_yields (R : Array (CallMap Term)) (U : Std.HashSet Nat) : Yields (body2 R U) := by
  intro x o j s r h
  obtain ⟨o', rfl, -⟩ := body2_ok h
  exact ⟨o', rfl⟩

/-! ### Reasoning normalization -/

theorem finish_ok {l v : List Term} {j r : List Term} (h : finish l j = .ok (v, r)) : v = l.map normalize := by
  unfold finish at h
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  exact h.1

theorem init_agr (n n' : Nat) (h : n ≤ n') : Agr n (init n) (init n') := by
  refine ⟨rfl, rfl, Array.size_replicate, by simp [init]; omega, fun k hk => ?_⟩
  simp only [init]
  rw [bang_eq, bang_eq, Array.getElem?_replicate, Array.getElem?_replicate, if_pos hk, if_pos (by omega)]

end ChatAdj

open ChatAdj in
theorem adjacentChat_append {xs ys out outH : List Term} {j j' k k' : List Term}
    (answered : ChatAnswered xs) (distinct : ChatDistinct xs)
    (h : adjacentChat (xs ++ ys) j = .ok (out, k))
    (hH : adjacentChat xs j' = .ok (outH, k')) :
    outH <+: out := by
  have hH' := (adjacentChat.stateless xs).run hH j
  rw [adjacentChat_eq, forIn_body1, pure_bind] at h hH'
  obtain ⟨o, j₁, ho, hf⟩ := Session.bind_ok_iff.mp h
  obtain ⟨oH, j₂, hoH, hfH⟩ := Session.bind_ok_iff.mp hH'
  rw [finish_ok hf, finish_ok hfH]
  have split : (xs ++ ys).zipIdx = xs.zipIdx ++ ys.zipIdx xs.length := by
    rw [List.zipIdx_append, Nat.zero_add]
  rw [split, List.foldl_append] at ho
  generalize hSx : List.foldl step1 (init (xs ++ ys).length) xs.zipIdx = Sx at ho
  generalize hSf : List.foldl step1 Sx (ys.zipIdx xs.length) = Sf at ho
  generalize hSh : List.foldl step1 (init xs.length) xs.zipIdx = Sh at hoH
  obtain ⟨o₁, j₃, ho₁, ho₂⟩ := forIn_append_ok (body2_yields _ _) ho
  have pre : Prepends o o₁ :=
    forIn_rel (R := fun b v => Prepends v b) (body2_yields _ _) Prepends.refl
      (fun _ _ _ h₁ h₂ => h₂.trans h₁)
      (fun _ _ _ _ _ hs => by obtain ⟨o', e, hp⟩ := body2_ok hs; cases e; exact hp) ho₂
  have agr : Agr xs.length Sh Sx := by
    rw [← hSh, ← hSx]
    exact Agr.fold _ (init_agr _ _ (by simp))
  have contain : ∀ x ∈ xs.zipIdx, ∀ c ∈ chatCalls x.1, (Sx.2.1[x.2]!).contains ⟨c⟩ = true := by
    have dist : ([] ++ xs.zipIdx).Pairwise Dist := by
      have d := distinct
      unfold ChatDistinct at d
      rw [← List.zipIdx_map_fst 0 xs, List.flatMap_map, List.pairwise_flatMap] at d
      exact d.2
    have inv := inv_fold xs.zipIdx [] (init (xs ++ ys).length) (fun _ hx => by cases hx)
      (by rw [List.zipIdx_map_fst]; exact answered) dist (by
        intro x hx
        obtain ⟨m, i⟩ := x
        have := (List.mem_zipIdx (by simpa using hx)).2.1
        simp [init]
        omega)
    rw [hSx] at inv
    intro x hx c hc
    rcases inv x (by simpa using hx) c hc with hc | ⟨-, z, hz, -⟩
    · exact hc
    · cases hz
  have congr : forIn xs.zipIdx [] (body2 Sf.2.1 Sf.2.2) = forIn xs.zipIdx [] (body2 Sh.2.1 Sh.2.2) := by
    refine forIn_congr_mem (fun x hx => ?_) []
    obtain ⟨m, i⟩ := x
    have hi : i < xs.length := by have := (List.mem_zipIdx hx).2.1; omega
    show body2' Sf.2.1[i]! (Sf.2.2.contains i) m = body2' Sh.2.1[i]! (Sh.2.2.contains i) m
    have hU : Sf.2.2.contains i = Sh.2.2.contains i := by
      rw [← hSf, fold_unclaimed _ _ _ ?_, agr.2.1]
      intro y hy
      obtain ⟨m', i'⟩ := y
      have := (List.mem_zipIdx hy).1
      dsimp only
      omega
    rw [hU]
    apply body2'_congr
    intro ha c hc
    rw [Std.HashMap.getD_eq_getD_getElem?, Std.HashMap.getD_eq_getD_getElem?, ← hSf,
      fold_keep _ _ _ _ (contain (m, i) hx _ (chatCalls_of_mem ha hc)), agr.2.2.2.2 i hi]
  rw [congr, hoH] at ho₁
  simp only [Except.ok.injEq, Prod.mk.injEq] at ho₁
  obtain ⟨rfl, -⟩ := ho₁
  obtain ⟨d, rfl⟩ := pre
  rw [List.reverse_append]
  exact (List.prefix_append _ _).map _

end VerifiedKernel.ProviderLoop
