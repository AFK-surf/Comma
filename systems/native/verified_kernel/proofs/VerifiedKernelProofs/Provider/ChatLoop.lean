import VerifiedKernelProofs.Provider.ChatMessages
import VerifiedKernelProofs.Provider.SyntheticRuntime
import VerifiedKernelProofs.Provider.ChatAdjacent

/-!
The message loop of the chat projection.

The loop keeps its output reversed and holds the image messages of tool results until the last
result of their batch. `flat` is the output in request order. It keeps every call answered and
every call id once (`ChatInv`). After an answered history it holds no image message, so a later
message only appends to its output (`chatLoop_prefix`).
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-- The loop state of `chat`: tool names, output (reversed), held image messages (reversed), and
the calls of the latest assistant message without a result. -/
abbrev ChatSt := CallMap Term × List Term × List Term × List Term

/-- The calls without a result after one message. -/
def waitStep (w : List Term) (m : Term) : List Term :=
  if (openaiRole m == b "tool") = true then w.filter (· != callId m)
  else if (openaiRole m == b "assistant") = true then (items (Provider.field m "tool_calls")).map (callField · "id")
  else w

/-- One step of the `chat` loop after the tool names are recorded. -/
def chatStep (model m : Term) (names : CallMap Term) (out pending waiting : List Term) :
    KernelM (ForInStep ChatSt) :=
  if (openaiRole m == b "tool") = true then do
    let __x ← chatTool m names
    match __x with
    | (msg, vision) =>
      if (waiting.filter (· != callId m)).isEmpty = true then
        pure (ForInStep.yield (names, vision.reverse ++ pending ++ msg :: out, [], waiting.filter (· != callId m)))
      else pure (ForInStep.yield (names, msg :: out, vision.reverse ++ pending, waiting.filter (· != callId m)))
  else do
    let l ← chatMessage m model
    if (openaiRole m == b "assistant") = true then
      pure (ForInStep.yield (names, l.reverse ++ pending ++ out, [],
        (items (Provider.field m "tool_calls")).map (callField · "id")))
    else pure (ForInStep.yield (names, l.reverse ++ pending ++ out, [], waiting))

/-- The body of the `chat` loop. -/
def chatBody (model : Term) : Term → ChatSt → KernelM (ForInStep ChatSt) := fun m s =>
  if (openaiRole m == b "assistant") = true then do
    let names ← forIn (items (Provider.field m "tool_calls")) s.1 fun c n =>
      pure (ForInStep.yield (Std.HashMap.insert n ⟨callField c "id"⟩ (callField c "name")))
    chatStep model m names s.2.1 s.2.2.1 s.2.2.2
  else chatStep model m s.1 s.2.1 s.2.2.1 s.2.2.2

/-- The leading context run that `chat` sends as one system message. -/
def chatLead (u : List Term) : List Term :=
  u.takeWhile fun m => member (openaiRole m) ["system", "summary", "runtime"]

/-- The loop output in request order. -/
def flat (s : ChatSt) : List Term := (s.2.2.1 ++ s.2.1).reverse

theorem chatBody.stateless (model m : Term) (s : ChatSt) : Stateless (chatBody model m s) := by
  unfold chatBody chatStep; stateless

/-- What one loop step does: a result joins the output and may release the held images; another
message releases them. -/
def StepFacts (model m : Term) (s s' : ChatSt) (k : List Term) : Prop :=
  (IsResult m ∧ ∃ names msg vision j', chatTool m names j' = .ok ((msg, vision), k) ∧
      s'.2.1.reverse ++ s'.2.2.1.reverse = (msg :: s.2.1).reverse ++ (vision.reverse ++ s.2.2.1).reverse ∧
      (∀ y ∈ s'.2.2.1, y ∈ vision ∨ y ∈ s.2.2.1) ∧ (∃ d, s'.2.1 = d ++ s.2.1)) ∨
    (¬ IsResult m ∧ ∃ l j', chatMessage m model j' = .ok (l, k) ∧
      s'.2.1 = l.reverse ++ s.2.2.1 ++ s.2.1 ∧ s'.2.2.1 = [])

theorem chatStep_ok {model m : Term} {names : CallMap Term} {out pending waiting : List Term} {s' : ChatSt}
    {j k : List Term} (h : chatStep model m names out pending waiting j = .ok (.yield s', k)) :
    StepFacts model m (names, out, pending, waiting) s' k ∧ s'.2.2.2 = waitStep waiting m ∧
      (s'.2.2.1 = [] ∨ s'.2.2.2 ≠ []) := by
  unfold chatStep at h
  split at h
  · rename_i tool
    obtain ⟨⟨msg, vision⟩, j₁, ht, h⟩ := Session.bind_ok_iff.mp h
    dsimp only at h
    have ws : waitStep waiting m = waiting.filter (· != callId m) := by unfold waitStep; rw [if_pos tool]
    split at h
    · rename_i empty
      simp only [Session.pure_ok_iff, Prod.mk.injEq, ForInStep.yield.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      refine ⟨Or.inl ⟨tool, names, msg, vision, j, ht, ?_, (fun y hy => by cases hy), ⟨vision.reverse ++ pending ++ [msg], by simp⟩⟩, ws.symm, .inl rfl⟩
      simp
    · rename_i nonempty
      simp only [Session.pure_ok_iff, Prod.mk.injEq, ForInStep.yield.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      refine ⟨Or.inl ⟨tool, names, msg, vision, j, ht, rfl, fun y hy => ?_, ⟨[msg], rfl⟩⟩, ws.symm, .inr ?_⟩
      · simpa [List.mem_append, List.mem_reverse] using hy
      · intro e
        dsimp only at e
        rw [e] at nonempty
        exact nonempty rfl
  · rename_i tool
    obtain ⟨l, j₁, hl, h⟩ := Session.bind_ok_iff.mp h
    split at h
    · rename_i ha
      simp only [Session.pure_ok_iff, Prod.mk.injEq, ForInStep.yield.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      refine ⟨Or.inr ⟨tool, l, j, hl, rfl, rfl⟩, ?_, .inl rfl⟩
      unfold waitStep; rw [if_neg tool, if_pos ha]
    · rename_i ha
      simp only [Session.pure_ok_iff, Prod.mk.injEq, ForInStep.yield.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      refine ⟨Or.inr ⟨tool, l, j, hl, rfl, rfl⟩, ?_, .inl rfl⟩
      unfold waitStep; rw [if_neg tool, if_neg ha]

theorem chatBody_ok {model m : Term} {s s' : ChatSt} {j k : List Term}
    (h : chatBody model m s j = .ok (.yield s', k)) :
    StepFacts model m s s' k ∧ s'.2.2.2 = waitStep s.2.2.2 m ∧ (s'.2.2.1 = [] ∨ s'.2.2.2 ≠ []) := by
  unfold chatBody at h
  split at h
  · obtain ⟨names, j₁, -, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨facts, w, held⟩ := chatStep_ok h
    refine ⟨?_, w, held⟩
    rcases facts with ⟨r, names', rest⟩ | right
    · exact Or.inl ⟨r, names', rest⟩
    · exact Or.inr right
  · obtain ⟨facts, w, held⟩ := chatStep_ok h
    refine ⟨?_, w, held⟩
    rcases facts with ⟨r, names', rest⟩ | right
    · exact Or.inl ⟨r, names', rest⟩
    · exact Or.inr right

theorem chatBody_yields (model : Term) : Yields (chatBody model) := by
  intro x b j s r h
  unfold chatBody chatStep at h
  exec_walk h
  all_goals exact ⟨_, rfl⟩

/-! ### Moving results and calls -/

theorem Answered.prefixed : ∀ {l Y : List Term},
    (∀ y ∈ l, ∀ c ∈ callsOf y, ∃ r ∈ Y, IsResult r ∧ c = callId r) → Answered Y → Answered (l ++ Y)
  | [], _, _, hy => hy
  | x :: l, Y, h, hy => ⟨fun c hc => by
      obtain ⟨r, mem, res, eq⟩ := h x (List.mem_cons_self ..) c hc
      exact ⟨r, List.mem_append_right _ mem, res, eq⟩,
    Answered.prefixed (fun y hy' => h y (List.mem_cons_of_mem _ hy')) hy⟩

/-- Replaces a message that is not a result by messages without results and the same calls. -/
theorem Answered.expand : ∀ {X Y l : List Term} {m : Term}, ¬ IsResult m →
    (∀ y ∈ l, ∀ c ∈ callsOf y, c ∈ callsOf m) → (∀ y ∈ l, ¬ IsResult y) →
    Answered (X ++ m :: Y) → Answered (X ++ (l ++ Y))
  | [], Y, l, m, _, sub, _, h => by
    rw [List.nil_append]
    exact Answered.prefixed (fun y hy c hc => h.1 c (sub y hy c hc)) h.2
  | x :: X, Y, l, m, hm, sub, hl, h => by
    refine ⟨fun c hc => ?_, Answered.expand hm sub hl h.2⟩
    obtain ⟨r, mem, res, eq⟩ := h.1 c hc
    refine ⟨r, ?_, res, eq⟩
    simp only [List.append_eq, List.mem_append, List.mem_cons] at mem ⊢
    rcases mem with mem | rfl | mem
    · exact Or.inl mem
    · exact absurd res hm
    · exact Or.inr (Or.inr mem)

/-- Replaces a result by another result with the same id. -/
theorem Answered.swap : ∀ {X Y : List Term} {m m' : Term}, callsOf m' = [] → IsResult m' →
    callId m' = callId m → Answered (X ++ m :: Y) → Answered (X ++ m' :: Y)
  | [], Y, m, m', hc, _, _, h => ⟨by simp [hc], h.2⟩
  | x :: X, Y, m, m', hc, hr, hid, h => by
    refine ⟨fun c hcx => ?_, Answered.swap hc hr hid h.2⟩
    obtain ⟨r, mem, res, eq⟩ := h.1 c hcx
    simp only [List.append_eq, List.mem_append, List.mem_cons] at mem
    rcases mem with mem | rfl | mem
    · exact ⟨r, List.mem_append_left _ mem, res, eq⟩
    · exact ⟨m', by simp, hr, eq.trans hid.symm⟩
    · exact ⟨r, by simp [mem], res, eq⟩

/-- Inserts messages without calls. -/
theorem Answered.insert : ∀ {X Y V : List Term}, (∀ v ∈ V, callsOf v = []) →
    Answered (X ++ Y) → Answered (X ++ (V ++ Y))
  | [], Y, V, hv, h => by
    rw [List.nil_append] at h ⊢
    exact Answered.prefixed (fun v hv' c hc => by rw [hv v hv'] at hc; cases hc) h
  | x :: X, Y, V, hv, h => by
    refine ⟨fun c hc => ?_, Answered.insert hv h.2⟩
    obtain ⟨r, mem, res, eq⟩ := h.1 c hc
    refine ⟨r, ?_, res, eq⟩
    simp only [List.append_eq, List.mem_append] at mem ⊢
    rcases mem with mem | mem
    · exact Or.inl mem
    · exact Or.inr (Or.inr mem)

theorem Answered.of_callless : ∀ {P : List Term}, (∀ y ∈ P, callsOf y = []) → Answered P
  | [], _ => trivial
  | y :: P, h => ⟨by simp [h y (List.mem_cons_self ..)], Answered.of_callless (fun z hz => h z (List.mem_cons_of_mem _ hz))⟩

/-! ### The loop invariant -/

/-- An output message of the chat loop: its chat call ids are its calls, and a result names its
call id in its `tool_call_id` field. -/
def ChatElem (y : Term) : Prop :=
  chatCallIds y = callsOf y ∧
    (IsResult y → (get y "role" == b "tool") = true ∧ y.has (b "tool_call_id") = true ∧ get y "tool_call_id" = callId y)

/-- The chat loop keeps the calls answered and the calls unchanged; its held messages have
neither calls nor results. -/
def ChatInv (C : List Term) (s : ChatSt) (Q : List Term) : Prop :=
  Answered (flat s ++ Q) ∧ (flat s ++ Q).flatMap callsOf = C ∧ (∀ y ∈ flat s, ChatElem y) ∧
    ∀ y ∈ s.2.2.1, callsOf y = [] ∧ ¬ IsResult y

theorem flat_eq (s : ChatSt) : flat s = s.2.1.reverse ++ s.2.2.1.reverse := by
  unfold flat; rw [List.reverse_append]

theorem toolMsg_facts (m s : Term) :
    callsOf (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) = [] ∧
      IsResult (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) ∧
      callId (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) = callId m ∧
      ChatElem (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) := by
  have role : openaiRole (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) = b "tool" := by
    unfold openaiRole; simp; rfl
  have id : callId (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) = callId m := by
    unfold callId
    simp only [field_obj, get_obj_cons_ne _ _ (by decide : "role" ≠ "tool_call_id"), get_obj_cons_same,
      get_obj_cons_ne _ _ (by decide : "role" ≠ "tool_use_id"),
      get_obj_cons_ne _ _ (by decide : "tool_call_id" ≠ "tool_use_id"),
      get_obj_cons_ne _ _ (by decide : "content" ≠ "tool_use_id"), get_obj_nil]
    exact coalesce_pair_nil (coalesce_cases _)
  have calls : callsOf (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) = [] := by
    unfold callsOf; rw [role]; simp
  have result : IsResult (obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) := by
    unfold IsResult; rw [role]; simp
  refine ⟨calls, result, id, ?_, fun _ => ⟨by simp, by simp [obj, Term.has, text_beq_text], ?_⟩⟩
  · unfold chatCallIds; rw [calls]; simp
  · rw [id, get_obj_cons_ne _ _ (by decide), get_obj_cons_same]

theorem visionMsg_facts (c : Term) :
    callsOf (obj [("role", b "user"), ("content", c)]) = [] ∧ ¬ IsResult (obj [("role", b "user"), ("content", c)]) ∧
      ChatElem (obj [("role", b "user"), ("content", c)]) := by
  obtain ⟨calls, result, -, ids⟩ := inertChat_role (s := "user") [("content", c)] (by decide) (by decide)
  exact ⟨calls, result, ids, fun r => absurd r result⟩

theorem chatInv_step {model : Term} {C Q : List Term} {m : Term} {s s' : ChatSt} {j k : List Term}
    (inv : ChatInv C s (m :: Q))
    (h : chatBody model m s j = .ok (.yield s', k)) : ChatInv C s' Q := by
  obtain ⟨ans, calls, elems, held⟩ := inv
  rw [flat_eq] at ans calls elems
  unfold ChatInv
  rw [flat_eq]
  rcases (chatBody_ok h).1 with ⟨res, names, msg, vision, j', ht, hflat, hheld, -⟩ | ⟨res, l, j', hl, e₁, e₂⟩
  · obtain ⟨⟨c, rfl⟩, hv⟩ := chatTool_ok ht
    obtain ⟨mc, mr, mid, me⟩ := toolMsg_facts m c
    have vfacts : ∀ v ∈ vision, callsOf v = [] ∧ ¬ IsResult v ∧ ChatElem v := by
      intro v hv'
      obtain ⟨c', rfl⟩ := hv v hv'
      exact visionMsg_facts c'
    rw [hflat]
    simp only [List.reverse_cons, List.reverse_append, List.reverse_reverse, List.append_assoc,
      List.singleton_append] at ans calls elems ⊢
    refine ⟨?_, ?_, ?_, ?_⟩
    · have a₁ := Answered.swap (X := s.2.1.reverse ++ s.2.2.1.reverse) mc mr mid (by simpa using ans)
      have a₂ := Answered.move (X := s.2.1.reverse) (Q := s.2.2.1.reverse) (Answered.of_callless fun y hy => (held y (by simpa using hy)).1) mc
        (by simpa using a₁)
      have a₃ := Answered.insert (X := s.2.1.reverse ++ _ :: s.2.2.1.reverse) (V := vision)
        (fun v hv' => (vfacts v hv').1) (by simpa using a₂)
      simpa using a₃
    · have vnil : vision.flatMap callsOf = [] := List.flatMap_eq_nil_iff.mpr fun v hv' => (vfacts v hv').1
      rw [← calls]
      simp [List.flatMap_append, mc, callsOf_of_tool res, vnil]
    · intro y hy
      simp only [List.mem_append, List.mem_cons] at hy
      rcases hy with hy | rfl | hy | hy
      · exact elems y (List.mem_append_left _ hy)
      · exact me
      · exact elems y (List.mem_append_right _ hy)
      · exact (vfacts y hy).2.2
    · intro y hy
      rcases hheld y hy with hy | hy
      · exact ⟨(vfacts y hy).1, (vfacts y hy).2.1⟩
      · exact held y hy
  · obtain ⟨lc, lfacts⟩ := chatMessage_ok hl
    rw [e₁, e₂]
    simp only [List.reverse_append, List.reverse_reverse, List.reverse_nil, List.append_nil,
      List.append_assoc, List.nil_append] at ans calls elems ⊢
    refine ⟨?_, ?_, ?_, by simp⟩
    · refine Answered.expand (X := s.2.1.reverse ++ s.2.2.1.reverse) res (fun y hy c hc => ?_)
        (fun y hy => (lfacts y hy).1) (by simpa using ans) |> fun a => by simpa using a
      rw [← lc]; exact List.mem_flatMap.mpr ⟨y, hy, hc⟩
    · rw [← calls]; simp [List.flatMap_append, lc]
    · intro y hy
      simp only [List.mem_append] at hy
      rcases hy with hy | hy | hy
      · exact elems y (List.mem_append_left _ hy)
      · exact elems y (List.mem_append_right _ hy)
      · exact ⟨(lfacts y hy).2.2, fun r => absurd r (lfacts y hy).1⟩

theorem chatInv_loop {model : Term} {C : List Term} :
    ∀ {Q : List Term} {s v : ChatSt} {j k : List Term}, ForIn.forIn Q s (chatBody model) j = .ok (v, k) →
      ChatInv C s Q → ChatInv C v []
  | [], s, v, j, k, h, inv => by
    obtain ⟨rfl, -⟩ := forIn_nil_ok h
    exact inv
  | m :: Q, s, v, j, k, h, inv => by
    obtain ⟨s', j', hm, rest⟩ := forIn_cons_ok (chatBody_yields model) h
    exact chatInv_loop rest (chatInv_step inv hm)

theorem chatInv_init {Q : List Term} (h : Answered Q) :
    ChatInv (Q.flatMap callsOf) ((∅ : CallMap Term), ([] : List Term), ([] : List Term), ([] : List Term)) Q :=
  ⟨by simpa [flat] using h, by simp [flat], by simp [flat], by simp⟩

theorem chatCalls_eq_chatCallIds (y : Term) : chatCalls y = chatCallIds y := rfl

theorem chatAnswered_of : ∀ {L : List Term}, Answered L → (∀ y ∈ L, ChatElem y) → ChatAnswered L
  | [], _, _ => trivial
  | m :: L, h, e => ⟨fun c hc => by
      rw [chatCalls_eq_chatCallIds, (e m (List.mem_cons_self ..)).1] at hc
      obtain ⟨r, mem, res, eq⟩ := h.1 c hc
      obtain ⟨role, has, id⟩ := (e r (List.mem_cons_of_mem _ mem)).2 res
      exact ⟨r, mem, role, has, id.trans eq.symm⟩,
    chatAnswered_of h.2 (fun y hy => e y (List.mem_cons_of_mem _ hy))⟩

theorem flatMap_chatCalls : ∀ {L : List Term}, (∀ y ∈ L, ChatElem y) → L.flatMap chatCalls = L.flatMap callsOf
  | [], _ => rfl
  | m :: L, e => by
    rw [List.flatMap_cons, List.flatMap_cons, chatCalls_eq_chatCallIds, (e m (List.mem_cons_self ..)).1,
      flatMap_chatCalls (fun y hy => e y (List.mem_cons_of_mem _ hy))]

/-- The system message that `chat` puts first. -/
def ChatHeader (header : List Term) : Prop := header = [] ∨ ∃ c, header = [obj [("role", b "system"), ("content", c)]]

theorem ChatHeader.elems {header : List Term} (h : ChatHeader header) :
    ∀ y ∈ header, callsOf y = [] ∧ ChatElem y := by
  rcases h with rfl | ⟨c, rfl⟩
  · simp
  · intro y hy
    simp only [List.mem_singleton] at hy
    subst hy
    obtain ⟨calls, result, -, ids⟩ := inertChat_role (s := "system") [("content", c)] (by decide) (by decide)
    exact ⟨calls, ids, fun r => absurd r result⟩

/-- The loop output of a closed history, after the system message, is answered and has distinct chat call ids. -/
theorem chatInv_final {C header : List Term} {v : ChatSt} (inv : ChatInv C v []) (hh : ChatHeader header)
    (distinct : C.Pairwise fun x y => (CallKey.mk x == CallKey.mk y) = false) :
    ChatAnswered (header ++ flat v) ∧ ChatDistinct (header ++ flat v) := by
  obtain ⟨ans, calls, elems, -⟩ := inv
  rw [List.append_nil] at ans calls
  have all : ∀ y ∈ header ++ flat v, ChatElem y := by
    intro y hy
    rcases List.mem_append.mp hy with hy | hy
    · exact (hh.elems y hy).2
    · exact elems y hy
  refine ⟨chatAnswered_of (Answered.prefixed (fun y hy c hc => by rw [(hh.elems y hy).1] at hc; cases hc) ans) all, ?_⟩
  unfold ChatDistinct
  rw [flatMap_chatCalls all, List.flatMap_append, calls,
    List.flatMap_eq_nil_iff.mpr (fun y hy => (hh.elems y hy).1), List.nil_append]
  exact distinct

/-! ### Released images -/

theorem wait_closed : ∀ {L w : List Term}, Answered L →
    (∀ x ∈ w, ∃ y ∈ L, IsResult y ∧ x = callId y) → L.foldl waitStep w = []
  | [], w, _, hw => by
    cases w with
    | nil => rfl
    | cons x w => obtain ⟨y, mem, -⟩ := hw x (List.mem_cons_self ..); simp at mem
  | m :: L, w, ⟨head, tail⟩, hw => by
    simp only [List.foldl_cons]
    apply wait_closed tail
    unfold waitStep
    split
    · intro x hx
      obtain ⟨hx, keep⟩ := List.mem_filter.mp hx
      obtain ⟨y, mem, res, eq⟩ := hw x hx
      rcases List.mem_cons.mp mem with rfl | mem
      · subst eq; simp [bne, Term.beq_self] at keep
      · exact ⟨y, mem, res, eq⟩
    · split
      · rename_i _ ha
        intro x hx
        exact head x (by unfold callsOf; rw [if_pos ha]; exact hx)
      · rename_i ht _
        intro x hx
        obtain ⟨y, mem, res, eq⟩ := hw x hx
        rcases List.mem_cons.mp mem with rfl | mem
        · exact absurd res ht
        · exact ⟨y, mem, res, eq⟩

/-- After an answered history the loop holds no image message. -/
theorem chatLoop_released {model : Term} {L : List Term} {v : ChatSt} {j k : List Term}
    (h : ForIn.forIn L ((∅ : CallMap Term), ([] : List Term), ([] : List Term), ([] : List Term))
      (chatBody model) j = .ok (v, k)) (answered : Answered L) : v.2.2.1 = [] := by
  have wait : v.2.2.2 = L.foldl waitStep [] :=
    forIn_fold (π := fun s : ChatSt => s.2.2.2) (chatBody_yields model)
      (fun x b b' j k hx => (chatBody_ok hx).2.1) h
  have held : v.2.2.1 = [] ∨ v.2.2.2 ≠ [] :=
    forIn_inv (I := fun s : ChatSt => s.2.2.1 = [] ∨ s.2.2.2 ≠ []) (chatBody_yields model)
      (fun x b b' j k _ hx => (chatBody_ok hx).2.2) (b := ((∅ : CallMap Term), [], [], [])) (.inl rfl) h
  rcases held with h | h
  · exact h
  · exact absurd (wait.trans (wait_closed answered (fun _ hx => by cases hx))) h

/-- With no held image message, the loop output only grows: a later message, result or not,
appends to it. -/
theorem chatLoop_prefix {model : Term} {E : List Term} {s v : ChatSt} {j k : List Term}
    (h : ForIn.forIn E s (chatBody model) j = .ok (v, k)) (released : s.2.2.1 = []) : flat s <+: flat v := by
  obtain ⟨d, hd⟩ := forIn_rel (R := fun a b : ChatSt => Prepends b.2.1 a.2.1) (chatBody_yields model)
    (fun _ => Prepends.refl _) (fun _ _ _ h₁ h₂ => Prepends.trans h₂ h₁) (fun x b b' j r hx => by
      rcases (chatBody_ok hx).1 with ⟨_, _, _, _, _, _, _, _, ⟨d, e⟩⟩ | ⟨_, _, _, _, e₁, _⟩
      · rw [e]; exact ⟨d, rfl⟩
      · rw [e₁]; exact Prepends.append _ _) h
  rw [flat_eq, flat_eq, hd, released]
  simp only [List.reverse_append, List.reverse_nil, List.append_nil, List.append_assoc]
  exact List.prefix_append _ _

end VerifiedKernel.ProviderLoop
