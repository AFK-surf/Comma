import VerifiedKernelProofs.Provider.MatchedCore
import VerifiedKernelProofs.Provider.ChatUnique

/-!
`uniqueChatCallIds` decides each message from the messages before it. Its output keeps the role
of each input message, gives every call a distinct wire id, and answers every call of a matched
input.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-! ### The fold as a recursion -/

/-- `wireMessages` as a recursion: one message, then the rest. -/
def wireRun (ids : WireIds) : List Term → KernelM (WireIds × List Term)
  | [] => pure (ids, [])
  | m :: rest => do
    let (ids, m) ← wireMessage ids m
    let (ids, rest) ← wireRun ids rest
    return (ids, m :: rest)

theorem wireRun.stateless : ∀ (ids : WireIds) (xs : List Term), Stateless (wireRun ids xs)
  | _, [] => by rw [wireRun]; exact Stateless.pure _
  | ids, m :: xs => by
    rw [wireRun]
    exact Stateless.bind (wireMessage.stateless _ _) fun _ =>
      Stateless.bind (wireRun.stateless _ xs) fun _ => Stateless.pure _

theorem foldlM_wireStep : ∀ (xs : List Term) (ids : WireIds) (acc : List Term),
    xs.foldlM wireStep (ids, acc) = (do let r ← wireRun ids xs; pure (r.1, r.2.reverse ++ acc))
  | [], ids, acc => by simp [wireRun]
  | m :: xs, ids, acc => by
    simp only [List.foldlM_cons, wireStep, wireRun, bind_assoc]
    congr 1
    funext r
    simp [foldlM_wireStep, bind_assoc]

theorem wireMessages_eq (ids : WireIds) (xs : List Term) : wireMessages ids xs = wireRun ids xs := by
  unfold wireMessages
  rw [foldlM_wireStep]
  simp

/-! ### Prefix -/

theorem wireRun_append : ∀ (ids : WireIds) (A B : List Term), wireRun ids (A ++ B) =
    (do let r ← wireRun ids A; let r' ← wireRun r.1 B; pure (r'.1, r.2 ++ r'.2))
  | ids, [], B => by simp [wireRun]
  | ids, m :: A, B => by
    simp only [List.cons_append, wireRun, wireRun_append _ A B]
    simp [bind_assoc]

/-! ### Single steps -/

theorem cat_binary {xs : List Term} {v : Term} {j k : List Term} (h : cat xs j = .ok (v, k)) :
    ∃ raw, v = .binary raw := by
  unfold cat at h
  obtain ⟨_, _, _, h⟩ := Session.bind_ok_iff.mp h
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  exact ⟨_, h.1⟩

theorem freeWireId_ok {issued : Std.HashSet CallKey} {id : Term} :
    ∀ {n fuel : Nat} {w : Term} {n' : Nat} {j k : List Term},
      freeWireId issued id n fuel j = .ok ((w, n'), k) → issued.contains ⟨w⟩ = false ∧ ∃ raw, w = .binary raw
  | _, 0, _, _, _, _, h => by simp [freeWireId, Session.fail_ok_iff] at h
  | n, fuel + 1, w, n', j, k, h => by
    unfold freeWireId at h
    obtain ⟨c, j₁, hc, h⟩ := Session.bind_ok_iff.mp h
    split at h
    · exact freeWireId_ok h
    · rename_i hfree
      simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
      obtain ⟨⟨rfl, -⟩, -⟩ := h
      exact ⟨by simpa using hfree, cat_binary hc⟩

/-- A wire id is a text id or the nil id. -/
def WireShape (w : Term) : Prop := w.truthy = true ∨ w = nil

theorem wireShape_callField (c : Term) : WireShape (callField c "id") := coalesce_truthy_or_nil _

theorem wireCall_ok {ids ids' : WireIds} {c w : Term} {j k : List Term}
    (h : wireCall ids c j = .ok ((ids', w), k)) :
    ids.issued.contains ⟨w⟩ = false ∧ WireShape w ∧ (w = nil → callField c "id" = nil) ∧
      ids'.issued = ids.issued.insert ⟨w⟩ ∧
      ids'.waiting = ids.waiting.insert ⟨callField c "id"⟩ (w :: ids.waiting.getD ⟨callField c "id"⟩ []) := by
  unfold wireCall at h
  dsimp only at h
  split at h
  · obtain ⟨⟨w', n'⟩, j₁, hp, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨rfl, rfl⟩, -⟩ := h
    obtain ⟨fresh, raw, e⟩ := freeWireId_ok hp
    exact ⟨fresh, Or.inl (by rw [e]; rfl), (fun hn => by rw [e] at hn; cases hn), rfl, rfl⟩
  · rename_i hc
    simp only [Session.pure_ok_iff, Prod.mk.injEq, pure_bind] at h
    obtain ⟨⟨rfl, rfl⟩, -⟩ := h
    exact ⟨by simpa using hc, wireShape_callField c, id, rfl, rfl⟩

theorem callField_putField {c w : Term} (shape : WireShape w) : callField (putField c "id" w) "id" = w := by
  unfold callField
  rw [pget_putField_same, putField, term_get_removeKey_atom_same]
  rcases shape with h | rfl
  · rw [coalesce_cons_truthy _ h]
  · rfl

theorem coalesce_pair_falsy {x y : Term} (h : coalesce [x, y] = nil) : y.truthy = false := by
  unfold coalesce at h
  cases hx : x.truthy <;> cases hy : y.truthy <;> simp_all [List.find?_cons]

theorem callId_putField {m w : Term} (shape : WireShape w) (hnil : w = nil → callId m = nil) :
    callId (putField m "tool_call_id" w) = w := by
  unfold callId
  rw [field_putField_same, field_putField_other _ _ (by decide)]
  rcases shape with h | rfl
  · rw [coalesce_cons_truthy _ h]
  · have := coalesce_pair_falsy (hnil rfl)
    unfold coalesce
    simp [List.find?_cons, this, truthy_nil]

theorem nil_key {t : Term} (h : (CallKey.mk nil == CallKey.mk t) = true) : t = nil := by
  change (nil == t && t == nil) = true at h
  simp only [Bool.and_eq_true] at h
  exact Session.atom_beq_true h.2

/-! ### Waiting calls -/

/-- The waiting wire ids of each provider id are those of the pairs `W` of provider id and wire
id, newest first. -/
def WaitRel (waiting : CallMap (List Term)) (W : List (Term × Term)) : Prop :=
  ∀ k : CallKey, waiting.getD k [] = (W.filter (fun p => CallKey.mk p.1 == k)).map Prod.snd

theorem key_congr {x o : Term} {k : CallKey} (h : (CallKey.mk o == k) = true) :
    (CallKey.mk x == k) = (CallKey.mk x == CallKey.mk o) := by
  apply Bool.eq_iff_iff.mpr
  exact ⟨fun hx => BEq.trans hx (BEq.symm h), fun hx => BEq.trans hx h⟩

theorem WaitRel.push {waiting : CallMap (List Term)} {W : List (Term × Term)} (rel : WaitRel waiting W)
    (o w : Term) : WaitRel (waiting.insert ⟨o⟩ (w :: waiting.getD ⟨o⟩ [])) ((o, w) :: W) := by
  intro k
  rw [Std.HashMap.getD_insert]
  split
  · rename_i hk
    rw [rel, List.filter_cons, if_pos hk]
    simp only [List.map_cons]
    congr 2
    exact List.filter_congr fun p _ => (key_congr hk).symm
  · rename_i hk
    rw [rel, List.filter_cons, if_neg hk]

theorem WaitRel.pop {waiting : CallMap (List Term)} {W : List (Term × Term)} (rel : WaitRel waiting W)
    {o w : Term} {rest : List Term} (h : waiting.getD ⟨o⟩ [] = w :: rest) :
    ∃ x ∈ W, (CallKey.mk x.1 == ⟨o⟩) = true ∧ x.2 = w ∧
      WaitRel (waiting.insert ⟨o⟩ rest) (W.eraseP (fun p => CallKey.mk p.1 == ⟨o⟩)) ∧
      ∀ p ∈ W, p ∈ W.eraseP (fun p => CallKey.mk p.1 == ⟨o⟩) ∨ p = x := by
  rw [rel] at h
  obtain ⟨y, ys, hf, hw, hrest⟩ : ∃ y ys, W.filter (fun p => CallKey.mk p.1 == ⟨o⟩) = y :: ys ∧ y.2 = w ∧
      ys.map Prod.snd = rest := by
    cases e : W.filter (fun p => CallKey.mk p.1 == ⟨o⟩) with
    | nil => rw [e] at h; cases h
    | cons y ys => rw [e] at h; simp only [List.map_cons, List.cons.injEq] at h; exact ⟨y, ys, rfl, h.1, h.2⟩
  obtain ⟨l₁, l₂, rfl, none, hy, rfl⟩ := List.filter_eq_cons_iff.mp hf
  have erase : (l₁ ++ y :: l₂).eraseP (fun p => CallKey.mk p.1 == ⟨o⟩) = l₁ ++ l₂ := by
    rw [List.eraseP_append_right _ (fun p hp => by simpa using none p hp)]
    simp [List.eraseP_cons, hy]
  refine ⟨y, by simp, hy, hw, ?_, ?_⟩
  · intro k
    rw [erase, Std.HashMap.getD_insert]
    split
    · rename_i hk
      have e₁ : l₁.filter (fun p => CallKey.mk p.1 == k) = [] :=
        List.filter_eq_nil_iff.mpr (fun p hp => by rw [key_congr hk]; simpa using none p hp)
      have e₂ : l₂.filter (fun p => CallKey.mk p.1 == k) = l₂.filter (fun p => CallKey.mk p.1 == ⟨o⟩) :=
        List.filter_congr (fun p _ => key_congr hk)
      rw [List.filter_append, e₁, e₂, List.nil_append]
      exact hrest.symm
    · rename_i hk
      rw [rel, List.filter_append, List.filter_append, List.filter_cons]
      have : (CallKey.mk y.1 == k) = false := by
        cases e : (CallKey.mk y.1 == k)
        · rfl
        · exact absurd (BEq.trans (BEq.symm hy) e) hk
      rw [if_neg (by simp [this])]
  · intro p hp
    rw [erase]
    simp only [List.mem_append, List.mem_cons] at hp ⊢
    rcases hp with hp | rfl | hp
    · exact Or.inl (Or.inl hp)
    · exact Or.inr rfl
    · exact Or.inl (Or.inr hp)

theorem WaitRel.none {waiting : CallMap (List Term)} {W : List (Term × Term)} (rel : WaitRel waiting W)
    {o : Term} (h : waiting.getD ⟨o⟩ [] = []) : W.eraseP (fun p => CallKey.mk p.1 == ⟨o⟩) = W := by
  rw [rel] at h
  have := List.map_eq_nil_iff.mp h
  exact List.eraseP_of_forall_not fun p hp => by
    have := List.filter_eq_nil_iff.mp this p hp
    simpa using this

/-! ### The invariant of a run -/

/-- The run state after the wire calls `P`, with waiting pairs `W`. -/
structure WInv (ids : WireIds) (W : List (Term × Term)) (P : List Term) : Prop where
  wait : WaitRel ids.waiting W
  issued : ∀ w ∈ P, ids.issued.contains ⟨w⟩ = true
  shape : ∀ p ∈ W, WireShape p.2 ∧ (p.2 = nil → p.1 = nil)
  dist : P.Pairwise fun x y => (CallKey.mk x == CallKey.mk y) = false

theorem WInv.empty : WInv {} [] [] where
  wait k := by simp [WaitRel]
  issued _ h := by cases h
  shape _ h := by cases h
  dist := List.Pairwise.nil

theorem WInv.fresh {ids : WireIds} {W : List (Term × Term)} {P : List Term} (inv : WInv ids W P) {w : Term}
    (h : ids.issued.contains ⟨w⟩ = false) : ∀ x ∈ P, (CallKey.mk x == CallKey.mk w) = false := by
  intro x hx
  cases e : (CallKey.mk x == CallKey.mk w)
  · rfl
  · have := inv.issued x hx
    rw [Std.HashSet.contains_congr e, h] at this
    cases this

/-- The call fold of `wireMessage` as a recursion. -/
def wireCallsRun (ids : WireIds) (renamed : CallMap Term) :
    List Term → KernelM (WireIds × CallMap Term × List Term)
  | [] => pure (ids, renamed, [])
  | c :: cs => do
    let (ids, wireId) ← wireCall ids c
    let (ids, renamed, calls) ← wireCallsRun ids (renamed.insert ⟨callField c "id"⟩ wireId) cs
    return (ids, renamed, putField c "id" wireId :: calls)

theorem foldlM_wireCallStep : ∀ (cs : List Term) (ids : WireIds) (renamed : CallMap Term) (acc : List Term),
    cs.foldlM wireCallStep (ids, renamed, acc) =
      (do let r ← wireCallsRun ids renamed cs; pure (r.1, r.2.1, r.2.2.reverse ++ acc))
  | [], ids, renamed, acc => by simp [wireCallsRun]
  | c :: cs, ids, renamed, acc => by
    simp only [List.foldlM_cons, wireCallStep, wireCallsRun, bind_assoc]
    congr 1
    funext r
    simp [foldlM_wireCallStep, bind_assoc]

theorem wireCallsRun_ok : ∀ (cs : List Term) {ids ids' : WireIds} {renamed renamed' : CallMap Term}
    {calls : List Term} {W : List (Term × Term)} {P : List Term} {j k : List Term},
    WInv ids W P → wireCallsRun ids renamed cs j = .ok ((ids', renamed', calls), k) →
    ∃ ws, calls = (cs.zip ws).map (fun p => putField p.1 "id" p.2) ∧ ws.length = cs.length ∧
      (∀ w ∈ ws, WireShape w) ∧
      WInv ids' (((cs.map (callField · "id")).zip ws).reverse ++ W) (P ++ ws)
  | [], ids, ids', renamed, renamed', calls, W, P, j, k, inv, h => by
    unfold wireCallsRun at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨rfl, rfl, rfl⟩, -⟩ := h
    exact ⟨[], rfl, rfl, (fun _ h => by cases h), by simpa using inv⟩
  | c :: cs, ids, ids', renamed, renamed', calls, W, P, j, k, inv, h => by
    unfold wireCallsRun at h
    obtain ⟨⟨ids₁, w⟩, j₁, hc, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨⟨ids₂, renamed₂, calls₂⟩, j₂, hcs, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨rfl, rfl, rfl⟩, -⟩ := h
    obtain ⟨fresh, shape, hnil, hiss, hwait⟩ := wireCall_ok hc
    have inv₁ : WInv ids₁ ((callField c "id", w) :: W) (P ++ [w]) := by
      refine ⟨?_, ?_, ?_, ?_⟩
      · rw [hwait]; exact inv.wait.push _ _
      · intro x hx
        rw [hiss, Std.HashSet.contains_insert]
        rcases List.mem_append.mp hx with hx | hx
        · rw [inv.issued x hx, Bool.or_true]
        · rw [List.mem_singleton.mp hx, BEq.rfl, Bool.true_or]
      · intro p hp
        rcases List.mem_cons.mp hp with rfl | hp
        · exact ⟨shape, hnil⟩
        · exact inv.shape p hp
      · exact List.pairwise_append.mpr ⟨inv.dist, List.pairwise_singleton _ _,
          fun x hx y hy => by rw [List.mem_singleton.mp hy]; exact inv.fresh fresh x hx⟩
    obtain ⟨ws, rfl, len, shapes, inv₂⟩ := wireCallsRun_ok cs inv₁ hcs
    refine ⟨w :: ws, rfl, by simp [len], ?_, ?_⟩
    · intro x hx
      rcases List.mem_cons.mp hx with rfl | hx
      · exact shape
      · exact shapes x hx
    · simpa [List.append_assoc] using inv₂

/-! ### One message -/

theorem withWireCalls_spec (m : Term) (calls : List Term) (renamed : CallMap Term) :
    SameRole m (withWireCalls m calls renamed) ∧
    (calls ≠ [] → Provider.field (withWireCalls m calls renamed) "tool_calls" = list calls) ∧
    (calls = [] → withWireCalls m calls renamed = m) := by
  unfold withWireCalls
  split
  · rename_i he
    have e : calls = [] := by simpa using he
    exact ⟨SameRole.refl _, fun h => absurd e h, fun _ => rfl⟩
  · rename_i hne
    have ne : calls ≠ [] := by simpa using hne
    dsimp only
    split
    · exact ⟨SameRole.putField _ _ (by decide), fun _ => field_putField_same _ _ _, fun h => absurd h ne⟩
    · refine ⟨(SameRole.putField _ _ (by decide)).trans (SameRole.putField _ _ (by decide)), fun _ => ?_,
        fun h => absurd h ne⟩
      rw [field_putField_other _ _ (by decide), field_putField_same]

theorem zip_callField : ∀ (cs ws : List Term), ws.length = cs.length → (∀ w ∈ ws, WireShape w) →
    ((cs.zip ws).map (fun p => putField p.1 "id" p.2)).map (callField · "id") = ws
  | [], [], _, _ => rfl
  | c :: cs, w :: ws, len, shapes => by
    simp only [List.zip_cons_cons, List.map_cons]
    rw [callField_putField (shapes w (List.mem_cons_self ..)),
      zip_callField cs ws (by simpa using len) (fun x hx => shapes x (List.mem_cons_of_mem _ hx))]
  | [], _ :: _, len, _ => by simp at len
  | _ :: _, [], len, _ => by simp at len

theorem mem_zip_right_of {os ws : List Term} (len : ws.length = os.length) :
    ∀ {c : Term}, c ∈ ws → ∃ p ∈ os.zip ws, p.2 = c := by
  induction os generalizing ws with
  | nil => intro c hc; cases ws with | nil => cases hc | cons _ _ => simp at len
  | cons o os ih =>
    intro c hc
    cases ws with
    | nil => cases hc
    | cons w ws =>
      rcases List.mem_cons.mp hc with rfl | hc
      · exact ⟨(o, c), by simp, rfl⟩
      · obtain ⟨p, hp, e⟩ := ih (by simpa using len) hc
        exact ⟨p, by simp [hp], e⟩

theorem WInv.same {ids ids' : WireIds} {W : List (Term × Term)} {P : List Term} (inv : WInv ids W P)
    (hw : ids'.waiting = ids.waiting) (hi : ids'.issued = ids.issued) : WInv ids' W P :=
  ⟨by rw [hw]; exact inv.wait, by rw [hi]; exact inv.issued, inv.shape, inv.dist⟩

/-- A result keeps its role and leaves the waiting pairs `W` unchanged. -/
theorem result_step {ids ids' : WireIds} {W : List (Term × Term)} {P : List Term} {m m' : Term}
    (inv : WInv ids W P) (tool : (openaiRole m == b "tool") = true) (same : SameRole m m')
    (hw : ids'.waiting = ids.waiting) (hi : ids'.issued = ids.issued)
    (empty : ids.waiting.getD ⟨callId m⟩ [] = []) :
    SameRole m m' ∧ ∃ W', WInv ids' W' (P ++ callsOf m') ∧ W'.map Prod.fst = openStep (W.map Prod.fst) m ∧
      (∀ p ∈ W, p ∈ W' ∨ (IsResult m' ∧ p.2 = callId m')) ∧ (∀ c ∈ callsOf m', ∃ p ∈ W', p.2 = c) := by
  have nc : callsOf m' = [] := callsOf_of_tool (by rw [same.1]; exact tool)
  refine ⟨same, W, by rw [nc, List.append_nil]; exact inv.same hw hi, ?_, fun p hp => .inl hp,
    fun c hc => by rw [nc] at hc; cases hc⟩
  unfold openStep
  rw [if_pos tool, List.eraseP_map]
  simp only [Function.comp_def]
  rw [inv.wait.none empty]

theorem wireMessage_ok {ids ids' : WireIds} {W : List (Term × Term)} {P : List Term} {m m' : Term}
    {j k : List Term} (inv : WInv ids W P) (h : wireMessage ids m j = .ok ((ids', m'), k)) :
    SameRole m m' ∧ ∃ W', WInv ids' W' (P ++ callsOf m') ∧ W'.map Prod.fst = openStep (W.map Prod.fst) m ∧
      (∀ p ∈ W, p ∈ W' ∨ (IsResult m' ∧ p.2 = callId m')) ∧ (∀ c ∈ callsOf m', ∃ p ∈ W', p.2 = c) := by
  unfold wireMessage at h
  split at h
  · rename_i ha
    obtain ⟨⟨ids₁, renamed, calls⟩, j₁, hc, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨e₁, e₂⟩, -⟩ := h
    subst ids' m'
    rw [foldlM_wireCallStep] at hc
    obtain ⟨⟨ids₂, renamed₂, calls₂⟩, j₂, hrun, e⟩ := Session.bind_ok_iff.mp hc
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at e
    obtain ⟨⟨rfl, rfl, rfl⟩, -⟩ := e
    simp only [List.append_nil, List.reverse_reverse]
    obtain ⟨ws, rfl, len, shapes, inv₁⟩ := wireCallsRun_ok _ inv hrun
    generalize hcs : items (Provider.field m "tool_calls") = cs at *
    have hm : callsOf m = cs.map (callField · "id") := by unfold callsOf; rw [if_pos ha, hcs]
    have spec := withWireCalls_spec m ((cs.zip ws).map fun p => putField p.1 "id" p.2) renamed
    have hm' : callsOf (withWireCalls m ((cs.zip ws).map fun p => putField p.1 "id" p.2) renamed) = ws := by
      by_cases e : cs = []
      · subst e
        have : ws = [] := List.eq_nil_of_length_eq_zero (by simpa using len)
        subst this
        rw [spec.2.2 rfl, hm]; rfl
      · have ne : ((cs.zip ws).map fun p => putField p.1 "id" p.2) ≠ [] := by
          cases cs with
          | nil => exact absurd rfl e
          | cons c cs => cases ws with
            | nil => simp at len
            | cons w ws => simp
        unfold callsOf
        rw [spec.1.1, if_pos ha, spec.2.1 ne, items_list, zip_callField cs ws len shapes]
    have notTool : ¬ (openaiRole m == b "tool") = true := by
      rw [text_beq_eq ha]; decide
    refine ⟨spec.1, _, by rw [hm']; exact inv₁, ?_, fun p hp => .inl (List.mem_append_right _ hp), ?_⟩
    · unfold openStep
      rw [if_neg notTool, hm, List.map_append, List.map_reverse, List.map_fst_zip (by simp [len])]
    · intro c hc
      rw [hm'] at hc
      obtain ⟨p, hp, e⟩ := mem_zip_right_of (os := cs.map (callField · "id")) (by simp [len]) hc
      exact ⟨p, List.mem_append_left _ (List.mem_reverse.mpr hp), e⟩
  split at h
  · rename_i ha hnt
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨e₁, e₂⟩, -⟩ := h
    subst ids' m'
    have nc : callsOf m = [] := callsOf_of_not_assistant ha
    have notTool : ¬ (openaiRole m == b "tool") = true := by simpa [bne] using hnt
    refine ⟨SameRole.refl _, W, by rw [nc, List.append_nil]; exact inv, ?_, fun p hp => .inl hp,
      fun c hc => by rw [nc] at hc; cases hc⟩
    unfold openStep
    rw [if_neg notTool, nc]; rfl
  rename_i ha hnt
  have tool : (openaiRole m == b "tool") = true := by simpa [bne] using hnt
  dsimp only at h
  cases hget : ids.waiting.getD ⟨callId m⟩ [] with
  | cons w rest =>
    rw [hget] at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨e₁, e₂⟩, -⟩ := h
    subst ids' m'
    obtain ⟨x, hx, key, hxw, rel, mem⟩ := inv.wait.pop hget
    have same : SameRole m (putField m "tool_call_id" w) := SameRole.putField _ _ (by decide)
    have nc : callsOf (putField m "tool_call_id" w) = [] := callsOf_of_tool (by rw [same.1]; exact tool)
    refine ⟨same, _, ⟨rel, by rw [nc, List.append_nil]; exact inv.issued,
      fun p hp => inv.shape p (List.mem_of_mem_eraseP hp), by rw [nc, List.append_nil]; exact inv.dist⟩, ?_, ?_,
      fun c hc => by rw [nc] at hc; cases hc⟩
    · unfold openStep
      rw [if_pos tool, List.eraseP_map]; rfl
    · intro p hp
      rcases mem p hp with hp | rfl
      · exact .inl hp
      · refine .inr ⟨by unfold IsResult; rw [same.1]; exact tool, ?_⟩
        obtain ⟨shape, hnil⟩ := inv.shape p hx
        rw [← hxw, callId_putField (hxw ▸ shape) (fun e => ?_)]
        have := hnil (hxw ▸ e)
        rw [this] at key
        exact nil_key key
  | nil =>
    rw [hget] at h
    dsimp only at h
    cases hl : ids.latest.get? ⟨callId m⟩ with
    | some w =>
      rw [hl] at h
      simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
      obtain ⟨⟨e₁, e₂⟩, -⟩ := h
      subst ids' m'
      exact result_step inv tool (SameRole.putField _ _ (by decide)) rfl rfl hget
    | none =>
      rw [hl] at h
      dsimp only at h
      split at h
      · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
        obtain ⟨⟨e₁, e₂⟩, -⟩ := h
        subst ids' m'
        exact result_step inv tool (SameRole.refl _) rfl rfl hget
      · obtain ⟨p, j₁, hp, h⟩ := Session.bind_ok_iff.mp h
        simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
        obtain ⟨⟨e₁, e₂⟩, -⟩ := h
        subst ids' m'
        exact result_step inv tool (SameRole.putField _ _ (by decide)) rfl rfl hget

/-! ### Whole runs -/

theorem wireMessage_role {ids ids' : WireIds} {m m' : Term} {j k : List Term}
    (h : wireMessage ids m j = .ok ((ids', m'), k)) : SameRole m m' := by
  unfold wireMessage at h
  split at h
  · obtain ⟨_, _, _, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨-, rfl⟩, -⟩ := h
    exact (withWireCalls_spec _ _ _).1
  split at h
  · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨-, rfl⟩, -⟩ := h
    exact SameRole.refl _
  dsimp only at h
  cases hget : ids.waiting.getD ⟨callId m⟩ [] with
  | cons w rest =>
    rw [hget] at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨-, rfl⟩, -⟩ := h
    exact SameRole.putField _ _ (by decide)
  | nil =>
    rw [hget] at h
    dsimp only at h
    cases hl : ids.latest.get? ⟨callId m⟩ with
    | some w =>
      rw [hl] at h
      simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
      obtain ⟨⟨-, rfl⟩, -⟩ := h
      exact SameRole.putField _ _ (by decide)
    | none =>
      rw [hl] at h
      dsimp only at h
      split at h
      · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
        obtain ⟨⟨-, rfl⟩, -⟩ := h
        exact SameRole.refl _
      · obtain ⟨_, _, _, h⟩ := Session.bind_ok_iff.mp h
        simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
        obtain ⟨⟨-, rfl⟩, -⟩ := h
        exact SameRole.putField _ _ (by decide)

theorem wireRun_role : ∀ {ids ids' : WireIds} {xs out : List Term} {j k : List Term},
    wireRun ids xs j = .ok ((ids', out), k) → List.Forall₂ SameRole xs out
  | ids, ids', [], out, j, k, h => by
    unfold wireRun at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨-, rfl⟩, -⟩ := h
    exact .nil
  | ids, ids', m :: xs, out, j, k, h => by
    unfold wireRun at h
    obtain ⟨⟨ids₁, m'⟩, j₁, hm, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨⟨ids₂, rest⟩, j₂, hr, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨-, rfl⟩, -⟩ := h
    exact .cons (wireMessage_role hm) (wireRun_role hr)

theorem wireRun_ok : ∀ {ids ids' : WireIds} {W : List (Term × Term)} {P xs out : List Term}
    {j k : List Term}, WInv ids W P → wireRun ids xs j = .ok ((ids', out), k) →
    (P ++ out.flatMap callsOf).Pairwise (fun x y => (CallKey.mk x == CallKey.mk y) = false) ∧
    (xs.foldl openStep (W.map Prod.fst) = [] →
      Answered out ∧ ∀ p ∈ W, ∃ r ∈ out, IsResult r ∧ p.2 = callId r)
  | ids, ids', W, P, [], out, j, k, inv, h => by
    unfold wireRun at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨-, rfl⟩, -⟩ := h
    refine ⟨by simpa using inv.dist, fun fin => ⟨trivial, fun p hp => ?_⟩⟩
    have : W = [] := by simpa using fin
    subst this; cases hp
  | ids, ids', W, P, m :: xs, out, j, k, inv, h => by
    unfold wireRun at h
    obtain ⟨⟨ids₁, m'⟩, j₁, hm, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨⟨ids₂, rest⟩, j₂, hr, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨-, rfl⟩, -⟩ := h
    obtain ⟨-, W', inv₁, fst, kept, calls⟩ := wireMessage_ok inv hm
    obtain ⟨dist, ans⟩ := wireRun_ok inv₁ hr
    refine ⟨by simpa [List.append_assoc] using dist, fun fin => ?_⟩
    rw [List.foldl_cons, ← fst] at fin
    obtain ⟨answered, waited⟩ := ans fin
    refine ⟨⟨fun c hc => ?_, answered⟩, fun p hp => ?_⟩
    · obtain ⟨p, hp, rfl⟩ := calls c hc
      exact waited p hp
    · rcases kept p hp with hp | ⟨res, e⟩
      · obtain ⟨r, hr, res, e⟩ := waited p hp
        exact ⟨r, List.mem_cons_of_mem _ hr, res, e⟩
      · exact ⟨m', List.mem_cons_self .., res, e⟩

/-- **Wire ids.** `uniqueChatCallIds` of a history followed by more messages starts with its
output for the history. Each output message keeps the role of its input message, the calls have
distinct wire ids, and every call of a matched history has a later result with its wire id. -/
theorem uniqueChatCallIds_append {xs ys out outH : List Term} {j j' k k' : List Term}
    (h : uniqueChatCallIds (xs ++ ys) j = .ok (out, k))
    (hH : uniqueChatCallIds xs j' = .ok (outH, k')) :
    (∃ outE, out = outH ++ outE ∧ List.Forall₂ SameRole ys outE) ∧
    List.Forall₂ SameRole xs outH ∧
    (outH.flatMap callsOf).Pairwise (fun x y => (CallKey.mk x == CallKey.mk y) = false) ∧
    (Matched xs → Answered outH) := by
  unfold uniqueChatCallIds at h hH
  obtain ⟨r, j₁, hr, h⟩ := Session.bind_ok_iff.mp h
  obtain ⟨rH, j₂, hrH, hH⟩ := Session.bind_ok_iff.mp hH
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h hH
  obtain ⟨rfl, -⟩ := h
  obtain ⟨rfl, -⟩ := hH
  rw [wireMessages_eq] at hr hrH
  rw [wireRun_append] at hr
  obtain ⟨rA, j₃, hA, hr⟩ := Session.bind_ok_iff.mp hr
  obtain ⟨rB, j₄, hB, hr⟩ := Session.bind_ok_iff.mp hr
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at hr
  obtain ⟨rfl, -⟩ := hr
  have := (wireRun.stateless _ _).same hrH hA
  subst this
  obtain ⟨dist, ans⟩ := wireRun_ok WInv.empty hrH
  refine ⟨⟨rB.2, rfl, wireRun_role hB⟩, wireRun_role hrH, by simpa using dist,
    fun matched => (ans matched).1⟩

end VerifiedKernel.ProviderLoop
