import VerifiedKernelProofs.Provider.AnsweredCore

/-!
What one message becomes in the chat projection.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

theorem chatTool_ok {m : Term} {names : CallMap Term} {msg : Term} {vision : List Term} {j k : List Term}
    (h : chatTool m names j = .ok ((msg, vision), k)) :
    (∃ s, msg = obj [("role", b "tool"), ("tool_call_id", callId m), ("content", s)]) ∧
      ∀ v ∈ vision, ∃ c, v = obj [("role", b "user"), ("content", c)] := by
  unfold chatTool at h
  obtain ⟨content, j₁, -, h⟩ := Session.bind_ok_iff.mp h
  split at h
  · revert h
    generalize Provider.decode content = d
    intro h
    rcases d with _ | d
    · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
      obtain ⟨⟨rfl, rfl⟩, -⟩ := h
      exact ⟨⟨_, rfl⟩, fun v hv => absurd hv List.not_mem_nil⟩
    · cases d
      all_goals try (simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
                     obtain ⟨⟨rfl, rfl⟩, -⟩ := h
                     exact ⟨⟨_, rfl⟩, fun v hv => absurd hv List.not_mem_nil⟩)
      simp only at h
      exec_walk h
      all_goals
        obtain ⟨rfl, rfl⟩ := ‹msg = _ ∧ vision = _›
        refine ⟨⟨_, rfl⟩, fun v hv => ?_⟩
        simp only [List.mem_singleton, List.not_mem_nil] at hv <;> exact ⟨_, hv⟩
  · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨⟨rfl, rfl⟩, -⟩ := h
    exact ⟨⟨_, rfl⟩, fun v hv => absurd hv List.not_mem_nil⟩

/-- The chat-protocol call ids of a message, read with `get`. -/
def chatCallIds (y : Term) : List Term :=
  if (get y "role" == b "assistant") = true then (items (get y "tool_calls")).map (get · "id") else []

theorem mergeMaps_empty (x : Term) : mergeMaps x empty = x := rfl

theorem pget_foldl_put : ∀ (es : List (Term × Term)) (x : Term) {k : String},
    (∀ e ∈ es, ∃ n, e.1 = b n ∧ n ≠ k) →
    Provider.get (es.foldl (fun acc p => acc.put p.1 p.2) x) k = Provider.get x k
  | [], _, _, _ => rfl
  | e :: es, x, k, h => by
    simp only [List.foldl_cons]
    rw [pget_foldl_put es _ (fun e' he => h e' (List.mem_cons_of_mem _ he))]
    obtain ⟨n, hn, ne⟩ := h e (List.mem_cons_self ..)
    rw [hn]
    exact pget_put_other _ _ ne

theorem pget_mergeMaps_select (x v : Term) (keys : List String) (d : Bool) {k : String} (hk : k ∉ keys) :
    Provider.get (mergeMaps x (select v keys d)) k = Provider.get x k := by
  unfold mergeMaps select
  apply pget_foldl_put
  intro e he
  obtain ⟨n, hn, he⟩ := List.mem_filterMap.mp he
  simp only at he
  split at he
  · simp only [Option.some.injEq] at he
    subst he
    exact ⟨n, rfl, fun e => hk (e ▸ hn)⟩
  · cases he

theorem atom_get_put_text (v x : Term) (l k : String) : (v.put (b l) x).get (a k) = v.get (a k) := by
  cases v with
  | map entries =>
    simp only [Term.put, Term.get, List.find?_cons, atom_ne_text]
    rw [Session.find?_filter_of_imp]
    intro e he
    have := Session.atom_beq_true he
    rw [this]; rfl
  | _ => simp [Term.put, Term.get, atom_ne_text]

theorem atom_get_foldl_put : ∀ (es : List (Term × Term)) (x : Term) (k : String),
    (∀ e ∈ es, ∃ n, e.1 = b n) →
    (es.foldl (fun acc p => acc.put p.1 p.2) x).get (a k) = x.get (a k)
  | [], _, _, _ => rfl
  | e :: es, x, k, h => by
    simp only [List.foldl_cons]
    rw [atom_get_foldl_put es _ k (fun e' he => h e' (List.mem_cons_of_mem _ he))]
    obtain ⟨n, hn⟩ := h e (List.mem_cons_self ..)
    rw [hn]
    exact atom_get_put_text _ _ _ _

theorem atom_get_mergeMaps_select (x v : Term) (keys : List String) (d : Bool) (k : String) :
    (mergeMaps x (select v keys d)).get (a k) = x.get (a k) := by
  unfold mergeMaps select
  apply atom_get_foldl_put
  intro e he
  obtain ⟨n, hn, he⟩ := List.mem_filterMap.mp he
  simp only at he
  split at he
  · simp only [Option.some.injEq] at he
    subst he
    exact ⟨n, rfl⟩
  · cases he

theorem field_of_atom_nil {y : Term} {k : String} (h : y.get (a k) = nil) : Provider.field y k = get y k := by
  simp [Provider.field, h, Term.truthy, nil]

theorem text_excl {t : Term} {s₁ s₂ : String} (h₁ : (t == b s₁) = true) (h₂ : (t == b s₂) = true)
    (ne : s₁ ≠ s₂) : False := by
  rw [text_beq_eq h₁, text_beq_text] at h₂
  exact ne (of_decide_eq_true h₂)

theorem member_excl {t : Term} {L : List String} {s : String} (hm : member t L = true) (he : (t == b s) = true)
    (hs : s ∉ L) : False := by
  obtain ⟨u, hu, eq⟩ := List.any_eq_true.mp hm
  exact text_excl eq he (fun e => hs (e ▸ hu))

theorem coalesce_cases (xs : List Term) : (coalesce xs).truthy = true ∨ coalesce xs = nil := by
  unfold coalesce
  cases h : xs.find? Term.truthy with
  | none => right; rfl
  | some v => left; simpa using List.find?_some h

theorem coalesce_pair_nil {v : Term} (h : v.truthy = true ∨ v = nil) : coalesce [v, nil] = v := by
  rcases h with h | rfl
  · exact coalesce_cons_truthy _ h
  · rfl

theorem callField_obj_id (v : Term) (rest : List (String × Term)) (h : v.truthy = true ∨ v = nil) :
    callField (obj (("id", v) :: rest)) "id" = v := by
  unfold callField
  rw [obj_get_atom, get_obj_cons_same]
  exact coalesce_pair_nil h

theorem chat_calls_ids : ∀ {xs ys : List Term} {j k : List Term},
    (List.mapM (m := KernelM) (fun c => do
        let __do_lift ← encode (coalesce [callField c "args", empty])
        pure (obj [("id", callField c "id"), ("type", b "function"),
          ("function", obj [("name", callField c "name"), ("arguments", __do_lift)])])) xs) j = .ok (ys, k) →
      ys.map (callField · "id") = xs.map (callField · "id") ∧ ys.map (get · "id") = xs.map (callField · "id")
  | [], ys, j, k, h => by
    rw [List.mapM_nil] at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]; simp
  | x :: xs, ys, j, k, h => by
    rw [List.mapM_cons] at h
    obtain ⟨y, j₁, hy, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨ys', j₂, hys, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]
    obtain ⟨ih₁, ih₂⟩ := chat_calls_ids hys
    exec_walk hy
    simp only [List.map_cons, ih₁, ih₂, get_obj_cons_same, List.cons.injEq, and_true]
    exact callField_obj_id _ _ (coalesce_cases _)

/-- A chat message that neither calls a tool nor carries a result. -/
def InertChat (y : Term) : Prop :=
  callsOf y = [] ∧ ¬ IsResult y ∧ (get y "role" == b "tool") = false ∧ chatCallIds y = callsOf y

theorem inertChat_role {s : String} (rest : List (String × Term)) (h₁ : s ≠ "assistant") (h₂ : s ≠ "tool") :
    InertChat (obj (("role", b s) :: rest)) := by
  have role : openaiRole (obj (("role", b s) :: rest)) = b s := by
    unfold openaiRole; simp; rfl
  refine ⟨?_, ?_, ?_, ?_⟩
  · unfold callsOf; rw [role, text_beq_text]; simp [h₁]
  · unfold IsResult; rw [role, text_beq_text]; simp [h₂]
  · simp [text_beq_text, h₂]
  · unfold chatCallIds callsOf; rw [role]; simp [text_beq_text, h₁]

theorem singleton_inert {y m : Term} (hy : InertChat y) (hm : callsOf m = []) :
    [y].flatMap callsOf = callsOf m ∧
      ∀ z ∈ [y], ¬ IsResult z ∧ (get z "role" == b "tool") = false ∧ chatCallIds z = callsOf z := by
  refine ⟨by simp [hy.1, hm], fun z hz => ?_⟩
  simp only [List.mem_singleton] at hz
  subst hz
  exact hy.2

/-- The assistant message that `chatMessage` builds. -/
def chatAssistant (calls : List Term) (content extra : Term) : Term :=
  mergeMaps (if calls.isEmpty then obj [("role", b "assistant"), ("content", content)]
    else (obj [("role", b "assistant"), ("content", content)]).put (b "tool_calls") (list calls)) extra

theorem chatAssistant_get {calls : List Term} {content extra : Term}
    (hextra : extra = empty ∨ ∃ v, extra = select v reasoningFields true) {k : String}
    (hk : k ∉ reasoningFields) :
    Provider.get (chatAssistant calls content extra) k =
      Provider.get (if calls.isEmpty then obj [("role", b "assistant"), ("content", content)]
        else (obj [("role", b "assistant"), ("content", content)]).put (b "tool_calls") (list calls)) k := by
  unfold chatAssistant
  rcases hextra with rfl | ⟨v, rfl⟩
  · rfl
  · exact pget_mergeMaps_select _ _ _ _ hk

theorem chatAssistant_atom {calls : List Term} {content extra : Term}
    (hextra : extra = empty ∨ ∃ v, extra = select v reasoningFields true) (k : String) :
    (chatAssistant calls content extra).get (a k) = nil := by
  unfold chatAssistant
  rcases hextra with rfl | ⟨v, rfl⟩
  · rw [mergeMaps_empty]; split
    · exact obj_get_atom _ _
    · rw [atom_get_put_text]; exact obj_get_atom _ _
  · rw [atom_get_mergeMaps_select]; split
    · exact obj_get_atom _ _
    · rw [atom_get_put_text]; exact obj_get_atom _ _

theorem chatAssistant_facts {calls xs : List Term} {content extra : Term}
    (hextra : extra = empty ∨ ∃ v, extra = select v reasoningFields true)
    (ids₁ : calls.map (callField · "id") = xs.map (callField · "id"))
    (ids₂ : calls.map (get · "id") = xs.map (callField · "id")) :
    callsOf (chatAssistant calls content extra) = xs.map (callField · "id") ∧
      ¬ IsResult (chatAssistant calls content extra) ∧
      (get (chatAssistant calls content extra) "role" == b "tool") = false ∧
      chatCallIds (chatAssistant calls content extra) = callsOf (chatAssistant calls content extra) := by
  have role : Provider.get (chatAssistant calls content extra) "role" = b "assistant" := by
    rw [chatAssistant_get hextra (k := "role") (by decide)]
    split
    · simp
    · rw [pget_put_other _ _ (by decide)]; simp
  have toolCalls : items (Provider.get (chatAssistant calls content extra) "tool_calls") = calls := by
    rw [chatAssistant_get hextra (k := "tool_calls") (by decide)]
    split
    · rename_i e
      rw [get_obj_cons_ne _ _ (by decide), get_obj_cons_ne _ _ (by decide), get_obj_nil, List.isEmpty_iff.mp e]
      rfl
    · rw [pget_put_same]; rfl
  have field_eq : ∀ k, Provider.field (chatAssistant calls content extra) k = Provider.get (chatAssistant calls content extra) k :=
    fun k => field_of_atom_nil (chatAssistant_atom hextra k)
  have openai : openaiRole (chatAssistant calls content extra) = b "assistant" := by
    unfold openaiRole; rw [field_eq, role]; rfl
  have calls_eq : callsOf (chatAssistant calls content extra) = xs.map (callField · "id") := by
    unfold callsOf; rw [openai, field_eq, toolCalls, ← ids₁]; simp [text_beq_text]
  refine ⟨calls_eq, ?_, ?_, ?_⟩
  · unfold IsResult; rw [openai]; simp [text_beq_text]
  · rw [role]; simp [text_beq_text]
  · unfold chatCallIds; rw [role, toolCalls, calls_eq, ids₂]; simp [text_beq_text]

theorem chatAssistant_single {calls xs : List Term} {content extra base m : Term}
    (hextra : extra = empty ∨ ∃ v, extra = select v reasoningFields true)
    (ids₁ : calls.map (callField · "id") = xs.map (callField · "id"))
    (ids₂ : calls.map (get · "id") = xs.map (callField · "id"))
    (hm : callsOf m = xs.map (callField · "id"))
    (hbase : base = if calls.isEmpty then obj [("role", b "assistant"), ("content", content)]
      else (obj [("role", b "assistant"), ("content", content)]).put (b "tool_calls") (list calls)) :
    [mergeMaps base extra].flatMap callsOf = callsOf m ∧
      ∀ y ∈ [mergeMaps base extra], ¬ IsResult y ∧ (get y "role" == b "tool") = false ∧ chatCallIds y = callsOf y := by
  subst hbase
  obtain ⟨calls_eq, rest⟩ := chatAssistant_facts (content := content) hextra ids₁ ids₂
  refine ⟨?_, fun y hy => ?_⟩
  · rw [List.flatMap_singleton, hm]; exact calls_eq
  · simp only [List.mem_singleton] at hy
    subst hy
    exact rest

theorem chatMessage_ok {m model : Term} {out : List Term} {j k : List Term}
    (h : chatMessage m model j = .ok (out, k)) :
    out.flatMap callsOf = callsOf m ∧
      ∀ y ∈ out, ¬ IsResult y ∧ (get y "role" == b "tool") = false ∧ chatCallIds y = callsOf y := by
  unfold chatMessage at h
  generalize roleEq : openaiRole m = raw at h
  have notAssistant : (raw == b "assistant") = false → callsOf m = [] := by
    intro ne; unfold callsOf; rw [roleEq, ne]; rfl
  exec_walk h
  all_goals first
    | (refine ⟨(notAssistant ?_).symm, fun y hy => absurd hy List.not_mem_nil⟩
       first
         | simpa [bne] using ‹(raw != b "assistant") = true›
         | (cases e : (raw == b "assistant")
            · rfl
            · exact (member_excl ‹member (raw) _ = true› e (by decide)).elim)
         | (cases e : (raw == b "assistant")
            · rfl
            · exact (text_excl ‹(raw == b "user") = true› e (by decide)).elim))
    | skip
  all_goals first
    | exact absurd ‹[_] = []› (List.cons_ne_nil _ _)
    | (obtain ⟨c, rfl⟩ := context_ok ‹context _ _ = _›
       refine singleton_inert (inertChat_role _ (by decide) (by decide)) (notAssistant ?_)
       cases e : (raw == b "assistant")
       · rfl
       · exact (member_excl ‹member (raw) _ = true› e (by decide)).elim)
    | (have user := text_beq_eq ‹(raw == b "user") = true›
       rw [user] at notAssistant ⊢
       exact singleton_inert (inertChat_role _ (by decide) (by decide)) (notAssistant (by decide)))
    | skip
  all_goals
    have assistant := text_beq_eq (by simpa [bne] using ‹¬(raw != b "assistant") = true›)
    rename_i hcalls hempty content hcontent
    rw [assistant]
    obtain ⟨ids₁, ids₂⟩ := chat_calls_ids hcalls
    have hm : callsOf m = (items (Provider.field m "tool_calls")).map (callField · "id") := by
      unfold callsOf; rw [roleEq, assistant]; simp [text_beq_text]
    refine chatAssistant_single (content := content) ?_ ids₁ ids₂ hm ?_
    · first | exact Or.inl rfl | exact Or.inr ⟨_, rfl⟩
    · simp [hempty]

end VerifiedKernel.ProviderLoop
