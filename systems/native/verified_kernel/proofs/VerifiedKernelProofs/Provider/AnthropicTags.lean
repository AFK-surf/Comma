import VerifiedKernelProofs.Provider.AnsweredCore
import VerifiedKernelProofs.Provider.AnthropicAdjacent
import VerifiedKernelProofs.Provider.MatchedCore

/-!
The Anthropic tags of a closed history answer every tool use.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

theorem toolUse_of_type {blk c : Term} {s : String} (ht : get blk "type" = b s) (hs : s ≠ "tool_use")
    (h : (if (get blk "type" == b "tool_use" && blk.has (b "id")) = true then some (get blk "id") else none) = some c) :
    False := by
  rw [ht, text_beq_text] at h
  simp [hs] at h

theorem toolUse_of_map {blk c : Term} {calls : List Term}
    (hb : blk ∈ calls.map fun c =>
      obj [("type", b "tool_use"), ("id", callField c "id"), ("name", callField c "name"),
        ("input", coalesce [callField c "args", empty])])
    (hf : (if (get blk "type" == b "tool_use" && blk.has (b "id")) = true then some (get blk "id") else none) = some c) :
    ∃ a, a ∈ calls ∧ callField a "id" = c := by
  obtain ⟨cc, hcc, rfl⟩ := List.mem_map.mp hb
  refine ⟨cc, hcc, ?_⟩
  have has : (obj [("type", b "tool_use"), ("id", callField cc "id"), ("name", callField cc "name"),
      ("input", coalesce [callField cc "args", empty])]).has (b "id") = true := by
    simp [obj, Term.has, text_beq_text]
  simp (config := {decide := true}) only [get_obj_cons_same, get_obj_cons_ne, ne_eq, not_false_eq_true,
    text_beq_text, decide_true, has, Bool.and_self, ↓reduceIte, Option.some.injEq] at hf
  exact hf

theorem toolUse_of_text {blk c w : Term} (hb : blk ∈ [obj [("type", b "text"), ("text", w)]])
    (hf : (if (get blk "type" == b "tool_use" && blk.has (b "id")) = true then some (get blk "id") else none) = some c) :
    False := by
  simp only [List.mem_singleton] at hb
  subst hb
  exact toolUse_of_type (s := "text") (by simp) (by decide) hf

theorem toolUse_of_thinking {blk c : Term} {xs : List Term} (hb : blk ∈ thinking xs)
    (hf : (if (get blk "type" == b "tool_use" && blk.has (b "id")) = true then some (get blk "id") else none) = some c) :
    False := by
  unfold thinking at hb
  obtain ⟨-, ht⟩ := List.mem_filter.mp hb
  simp only [Bool.and_eq_true] at ht
  obtain ⟨s, hs, eq⟩ := List.any_eq_true.mp ht.2
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hs
  rcases hs with rfl | rfl
  · exact toolUse_of_type (text_beq_eq eq) (by decide) hf
  · exact toolUse_of_type (text_beq_eq eq) (by decide) hf

theorem anthropicMessage_assistant {m model : Term} {tags : List (Bool × Term)} {j k : List Term}
    (h : anthropicMessage m model j = .ok (tags, k)) :
    ∀ x ∈ tags, (get x.2 "role" == b "assistant") = true → ∀ c ∈ toolUseIds x.2, c ∈ callsOf m := by
  unfold anthropicMessage at h
  exec_walk h
  all_goals intro x hx role c hc
  all_goals first
    | exact absurd hx List.not_mem_nil
    | (exfalso
       simp only [List.mem_singleton] at hx
       subst hx
       obtain ⟨cc, rfl⟩ := context_ok ‹context _ _ = _›
       revert role
       simp (config := {decide := true}) [get_obj_cons_ne])
    | (exfalso
       simp only [List.mem_singleton] at hx
       subst hx
       revert role
       simp (config := {decide := true}) [get_obj_cons_ne]
       done)
    | (exfalso
       simp only [List.mem_singleton] at hx
       subst hx
       revert role
       simp only [get_obj_cons_same]
       rw [text_beq_eq ‹(openaiRole m == b "user") = true›]
       simp (config := {decide := true}))
    | (simp only [List.mem_singleton] at hx
       subst hx
       have assistant : (openaiRole m == b "assistant") = true := by
         have := ‹¬(openaiRole m != b "assistant") = true›
         simpa [bne] using this
       unfold toolUseIds at hc
       obtain ⟨blk, hblk, hf⟩ := List.mem_filterMap.mp hc
       simp only [get_obj_cons_ne _ _ (by decide : "role" ≠ "content"), get_obj_cons_same, items_list,
         List.mem_append, List.nil_append, List.append_nil] at hblk
       unfold callsOf
       rw [text_beq_eq assistant]
       simp only [text_beq_text, decide_true, ↓reduceIte, List.mem_map]
       first
         | exact toolUse_of_map hblk hf
         | (rcases hblk with hb | hb <;> first
             | exact toolUse_of_map hb hf | exact (toolUse_of_text hb hf).elim | exact (toolUse_of_thinking hb hf).elim)
         | (rcases hblk with (hb | hb) | hb <;> first
             | exact toolUse_of_map hb hf | exact (toolUse_of_text hb hf).elim | exact (toolUse_of_thinking hb hf).elim))

theorem anthropicMessage_tool {m model : Term} {tags : List (Bool × Term)} {j k : List Term}
    (role : openaiRole m = b "tool") (h : anthropicMessage m model j = .ok (tags, k)) :
    ∃ x ∈ tags, resultId x.2 = callId m := by
  unfold anthropicMessage at h
  rw [role] at h
  simp (config := {decide := true}) only [member_text, text_beq_text, text_bne_text, List.any_cons, List.any_nil,
    decide_false, decide_true, Bool.false_or, Bool.or_false, Bool.false_eq_true, ↓reduceIte, Bool.not_true] at h
  exec_walk h
  refine ⟨_, List.mem_singleton_self _, ?_⟩
  simp (config := {decide := true}) [resultId, get_obj_cons_ne]

theorem AnthAnswered.append : ∀ {A R : List (Bool × Term)},
    (∀ x ∈ A, (get x.2 "role" == b "assistant") = true → ∀ c ∈ toolUseIds x.2, ∃ y ∈ R, (c == resultId y.2) = true) →
    AnthAnswered R → AnthAnswered (A ++ R)
  | [], _, _, hr => hr
  | x :: A, R, ha, hr => ⟨fun role c hc => by
      obtain ⟨y, hy, eq⟩ := ha x (List.mem_cons_self ..) role c hc
      exact ⟨y, List.mem_append_right _ hy, eq⟩,
    AnthAnswered.append (fun y hy => ha y (List.mem_cons_of_mem _ hy)) hr⟩

theorem role_tool_of_result {r : Term} (res : IsResult r) : openaiRole r = b "tool" := by
  unfold IsResult at res
  exact text_beq_eq res

theorem anthropic_tags_answered {model : Term} :
    ∀ {L : List Term} {tss : List (List (Bool × Term))} {j k : List Term},
      AnsweredEq L → L.mapM (anthropicMessage · model) j = .ok (tss, k) → AnthAnswered tss.flatten
  | [], tss, j, k, _, h => by
    rw [List.mapM_nil] at h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1]; trivial
  | m :: L, tss, j, k, ⟨head, tail⟩, h => by
    rw [List.mapM_cons] at h
    obtain ⟨tm, j₁, hm, h⟩ := Session.bind_ok_iff.mp h
    obtain ⟨ts, j₂, hts, h⟩ := Session.bind_ok_iff.mp h
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    rw [h.1, List.flatten_cons]
    refine AnthAnswered.append (fun x hx role c hc => ?_)
      (anthropic_tags_answered tail hts)
    obtain ⟨r, hr, res, hcr⟩ := head c (anthropicMessage_assistant hm x hx role c hc)
    obtain ⟨tr, j', k', htr, mem⟩ := mapM_mem_ok hts hr
    obtain ⟨y, hy, eq⟩ := anthropicMessage_tool
      (role_tool_of_result res) htr
    exact ⟨y, List.mem_flatten.mpr ⟨tr, mem, hy⟩, by rw [eq]; exact hcr⟩

end VerifiedKernel.ProviderLoop
