import VerifiedKernelProofs.Provider.PrefixSpec

/-!
Anthropic prompt caching changes no message after erasure.

`Request.cache` marks at most a few messages below the durable bound. A marked message gets its
content as content blocks with a cache marker on the last block. `eraseMessage` removes the
marker and reads one text block as its text, so the marked message erases to the original.
-/

namespace VerifiedKernel.ProviderLoop
open Data Provider Messages

set_option maxHeartbeats 4000000

/-! ### Erasure of cache markers -/

/-- A second `put` under the same binary key replaces the first. -/
theorem put_text_put (v x y : Term) (k : String) : (v.put (b k) x).put (b k) y = v.put (b k) y := by
  cases v <;> simp [Term.put, List.filter_filter, text_beq_text]

/-- A map has the binary key that `put` wrote. -/
theorem has_put_text (v x : Term) (k : String) : (v.put (b k) x).has (b k) = true := by
  cases v <;> simp [Term.put, Term.has, text_beq_text]

/-- A missing key reads as `nil`. -/
theorem get_of_has_false {v k : Term} (h : v.has k = false) : v.get k = nil := by
  cases v with
  | map entries =>
    simp only [Term.has, List.any_eq_false] at h
    simp only [Term.get]
    rw [List.find?_eq_none.mpr (by simpa using h)]
    rfl
  | _ => rfl

/-- Erasure removes the cache marker that `mark` adds. -/
theorem eraseBlock_mark (v : Term) : eraseBlock (Request.mark v) = eraseBlock v := by
  unfold Request.mark
  split
  · rename_i hv
    cases v with
    | map entries => simp [eraseBlock, removeKey, Term.put, List.filter_filter, text_beq_text, bne]
    | _ => simp [Term.isMap] at hv
  · rfl

/-- Marking the last block changes no block after erasure. -/
theorem map_eraseBlock_markLast (xs : List Term) :
    (Request.markLast xs).map eraseBlock = xs.map eraseBlock := by
  have head : ∀ l : List Term, (l.modifyHead Request.mark).map eraseBlock = l.map eraseBlock := by
    intro l; cases l <;> simp [eraseBlock_mark]
  unfold Request.markLast
  rw [List.map_reverse, head, ← List.map_reverse, List.reverse_reverse]

/-- Erased list content depends only on the erased blocks. -/
theorem eraseContent_list_congr :
    ∀ {ys zs : List Term}, ys.map eraseBlock = zs.map eraseBlock →
      eraseContent (list ys) = eraseContent (list zs)
  | [], [], _ => rfl
  | [y], [z], h => by
    simp only [List.map_cons, List.map_nil, List.cons.injEq, and_true] at h
    simp only [eraseContent, list, h]
  | _ :: _ :: _, _ :: _ :: _, h => by
    show list _ = list _
    rw [h]
  | [], _ :: _, h | _ :: _, [], h => by simp at h
  | [_], _ :: _ :: _, h | _ :: _ :: _, [_], h => by simp at h

/-- One marked text block erases to its text. -/
theorem eraseContent_text_block (r : ByteArray) :
    eraseContent (list [Request.mark (obj [("type", b "text"), ("text", .binary r)])]) = .binary r := by
  rw [eraseContent_list_congr (zs := [obj [("type", b "text"), ("text", .binary r)]])
    (by simp [eraseBlock_mark])]
  simp (config := {decide := true}) [eraseContent, eraseBlock, removeKey, obj, list]
  have ty : Provider.get (Term.map [(b "type", b "text"), (b "text", Term.binary r)]) "type" = b "text" :=
    get_obj_cons_same [("text", Term.binary r)] "type" (b "text")
  have tx : Provider.get (Term.map [(b "type", b "text"), (b "text", Term.binary r)]) "text" = .binary r :=
    (get_obj_cons_ne [("text", Term.binary r)] (b "text") (by decide)).trans
      (get_obj_cons_same [] "text" (.binary r))
  have depth : (Term.map []).depth = 1 := by simp [Term.depth]
  have empty : (Term.map [] == Term.map []) = true := by
    show ((0 : Nat) == 0 &&
      Term.exactFuel (max (Term.map []).depth (Term.map []).depth) (.map []) (.map [])) = true
    rw [depth]; rfl
  rw [if_pos ⟨by rw [ty]; simp, empty⟩, tx]

/-- A message that `cache` marks has the erasure of the original message. -/
theorem eraseMessage_marked (m : Term)
    (markable :
      (nonempty (Provider.get m "content") || !(items (Provider.get m "content")).isEmpty) = true) :
    eraseMessage (m.put (b "content") (list (if (Provider.get m "content").isBinary = true then
      [Request.mark (obj [("type", b "text"), ("text", Provider.get m "content")])]
      else Request.markLast (items (Provider.get m "content"))))) = eraseMessage m := by
  have hhas : m.has (b "content") = true := by
    cases h : m.has (b "content")
    · rw [show Provider.get m "content" = nil from get_of_has_false h] at markable
      simp [nonempty, nil, items, Term.isBinary] at markable
    · rfl
  unfold eraseMessage
  rw [has_put_text, if_pos rfl, if_pos hhas, pget_put_same, put_text_put]
  congr 1
  generalize Provider.get m "content" = c at markable ⊢
  cases c with
  | binary r => exact eraseContent_text_block r
  | list xs => exact eraseContent_list_congr (map_eraseBlock_markLast xs)
  | _ => simp [nonempty, items, Term.isBinary] at markable

/-! ### The marking loop -/

/-- `ys` is `ms` where the message at each index `k + i` stays or, below `d`, becomes a message
with the same erasure. -/
def CacheMarked (d : Int) : Nat → List Term → List Term → Prop
  | _, [], [] => True
  | k, m :: ms, y :: ys =>
    (y = m ∨ ((k : Int) < d ∧ eraseMessage y = eraseMessage m)) ∧ CacheMarked d (k + 1) ms ys
  | _, _, _ => False

theorem CacheMarked.length {d : Int} :
    ∀ {k : Nat} {ms ys : List Term}, CacheMarked d k ms ys → ys.length = ms.length
  | _, [], [], _ => rfl
  | _, _ :: _, _ :: _, h => by simp only [List.length_cons, h.2.length]
  | _, [], _ :: _, h | _, _ :: _, [], h => h.elim

theorem CacheMarked.erase {d : Int} : ∀ {k : Nat} {ms ys : List Term}, CacheMarked d k ms ys →
    ys.map eraseMessage = ms.map eraseMessage
  | _, [], [], _ => rfl
  | _, m :: _, y :: _, h => by
    rw [List.map_cons, List.map_cons, h.2.erase]
    rcases h.1 with rfl | ⟨_, e⟩
    · rfl
    · rw [e]
  | _, [], _ :: _, h | _, _ :: _, [], h => h.elim

theorem CacheMarked.index {d : Int} : ∀ {k : Nat} {ms ys : List Term}, CacheMarked d k ms ys →
    ∀ i, ys[i]? ≠ ms[i]? → ((k + i : Nat) : Int) < d
  | _, [], [], _, _, hne => absurd rfl hne
  | k, m :: _, y :: _, h, 0, hne => by
    rcases h.1 with rfl | ⟨lt, _⟩
    · exact absurd rfl hne
    · simpa using lt
  | k, _ :: _, _ :: _, h, i + 1, hne => by
    have := h.2.index i (by simpa using hne)
    rw [show k + (i + 1) = k + 1 + i by omega]; exact this
  | _, [], _ :: _, h, _, _ | _, _ :: _, [], h, _, _ => h.elim

/-- Each step of the marking loop prepends the visited message or, below `d`, a copy with the
same erasure. -/
def CacheStep (d : Int)
    (f : Term × Nat → Nat × Nat × List Term → Id (ForInStep (Nat × Nat × List Term))) : Prop :=
  ∀ m idx s, ∃ s', f (m, idx) s = pure (.yield s') ∧ ∃ y, s'.2.2 = y :: s.2.2 ∧
    (y = m ∨ ((idx : Int) < d ∧ eraseMessage y = eraseMessage m))

/-- A body that yields in both branches of a condition yields a state satisfying `P` when
both states do. -/
theorem ite_yield {σ : Type} {c : Bool} {x y : σ} {P : σ → Prop} (hx : c = true → P x)
    (hy : c = false → P y) :
    ∃ s, (if c = true then pure (ForInStep.yield x) else pure (ForInStep.yield y) : Id (ForInStep σ)) =
      pure (.yield s) ∧ P s := by
  cases c
  · exact ⟨y, rfl, hy rfl⟩
  · exact ⟨x, rfl, hx rfl⟩

/-- A loop in `Id` whose body always continues is a left fold. -/
theorem forIn_id_foldl {α σ : Type} {f : α → σ → Id (ForInStep σ)}
    (yields : ∀ x s, ∃ s', f x s = pure (.yield s')) :
    ∀ (l : List α) (init : σ), forIn l init f = pure (l.foldl (fun s x => (Id.run (f x s)).value) init)
  | [], _ => rfl
  | x :: xs, init => by
    obtain ⟨s', h⟩ := yields x init
    rw [List.forIn_cons, List.foldl_cons, h]
    exact forIn_id_foldl yields xs s'

/-- The marking loop over a reversed indexed suffix prepends a `CacheMarked` copy of it. -/
theorem foldr_marked {d : Int} {f} (hf : CacheStep d f) :
    ∀ (ms : List Term) (k : Nat) (s : Nat × Nat × List Term), ∃ ys,
      ((ms.zipIdx k).foldr (fun x s => (Id.run (f x s)).value) s).2.2 = ys ++ s.2.2 ∧
        CacheMarked d k ms ys
  | [], _, _ => ⟨[], rfl, trivial⟩
  | m :: ms, k, s => by
    obtain ⟨ys, hys, hm⟩ := foldr_marked hf ms (k + 1) s
    rw [List.zipIdx_cons, List.foldr_cons]
    obtain ⟨s', hstep, y, hs', hy⟩ :=
      hf m k (List.foldr (fun x s => (Id.run (f x s)).value) s (ms.zipIdx (k + 1)))
    refine ⟨y :: ys, ?_, hy, hm⟩
    rw [hstep]
    show s'.2.2 = _
    rw [hs', hys]; rfl

/-- The output of the marking loop is a `CacheMarked` copy of its messages. -/
theorem loop_marked {d : Int} {f} (hf : CacheStep d f) (ms : List Term) :
    CacheMarked d 0 ms
      (Id.run (forIn (ms.zipIdx).reverse ((0 : Nat), (0 : Nat), ([] : List Term)) f)).2.2 := by
  rw [forIn_id_foldl (fun ⟨m, idx⟩ s => let ⟨s', h, _⟩ := hf m idx s; ⟨s', h⟩), List.foldl_reverse]
  obtain ⟨ys, hys, hm⟩ := foldr_marked hf ms 0 (0, 0, [])
  rw [List.append_nil] at hys
  show CacheMarked d 0 ms (List.foldr (fun x s => (Id.run (f x s)).value)
    ((0 : Nat), (0 : Nat), ([] : List Term)) (ms.zipIdx 0)).2.2
  rw [hys]; exact hm

/-! ### `cache` -/

/-- The index bound below which `cache` may mark a message. -/
def cacheDurable (msgs : List Term) (trailing : Term) : Int :=
  Int.ofNat msgs.length - match trailing with | .integer n => max n 0 | _ => 0

/-- One step of the `cache` loop satisfies `CacheStep`. -/
local macro "cache_step" : tactic => `(tactic| (
  intro m idx s
  refine ite_yield (fun h => ?_) (fun _ => ⟨m, rfl, Or.inl rfl⟩)
  simp only [Bool.and_eq_true] at h
  exact ⟨_, rfl, Or.inr ⟨of_decide_eq_true h.1.1.2, eraseMessage_marked m h.1.2⟩⟩))

/-- With caching enabled, `cache` returns a system text and tools that do not depend on the
messages, and marks messages only below the durable bound. -/
theorem cache_marked (system tools enabled : Term) (hen : (enabled == a "false") = false) :
    ∃ system' tools', ∀ (msgs : List Term) (trailing : Term), ∃ out,
      Request.cache system tools (list msgs) enabled trailing = .tuple [system', tools', list out] ∧
      CacheMarked (cacheDurable msgs trailing) 0 msgs out := by
  by_cases hs : nonempty system = true
  · refine ⟨list [Request.mark (obj [("type", b "text"), ("text", system)])], tools,
      fun msgs trailing => ?_⟩
    simp only [Request.cache, hen, hs, items_list, Bool.false_eq_true, ↓reduceIte]
    refine ⟨_, rfl, loop_marked ?_ msgs⟩
    cache_step
  · by_cases ht : (!(items tools).isEmpty) = true
    · refine ⟨system, list (Request.markLast (items tools)), fun msgs trailing => ?_⟩
      simp only [Request.cache, hen, hs, ht, items_list, Bool.false_eq_true, ↓reduceIte]
      refine ⟨_, rfl, loop_marked ?_ msgs⟩
      cache_step
    · refine ⟨system, tools, fun msgs trailing => ?_⟩
      simp only [Request.cache, hen, hs, ht, items_list, Bool.false_eq_true, ↓reduceIte]
      refine ⟨_, rfl, loop_marked ?_ msgs⟩
      cache_step

/-- Cache markers change no message after erasure, and the system text and tools that `cache`
returns do not depend on the messages. -/
theorem cache_erase (system tools : Term) (msgs : List Term) (enabled trailing : Term) :
    ∃ system' tools' out,
      Request.cache system tools (list msgs) enabled trailing = .tuple [system', tools', list out] ∧
      out.map eraseMessage = msgs.map eraseMessage ∧
      out.length = msgs.length ∧
      (∀ (msgs₂ : List Term) (trailing₂ : Term), ∃ out₂,
        Request.cache system tools (list msgs₂) enabled trailing₂ = .tuple [system', tools', list out₂]) ∧
      (∀ (i : Nat) (n : Int), trailing = .integer n → out[i]? ≠ msgs[i]? →
        (i : Int) < (msgs.length : Int) - max n 0) := by
  by_cases hen : (enabled == a "false") = true
  · have run : ∀ (ms : List Term) (t : Term),
        Request.cache system tools (list ms) enabled t = .tuple [system, tools, list ms] := by
      intro ms t
      simp only [Request.cache, hen, ↓reduceIte]
      rfl
    exact ⟨system, tools, msgs, run msgs trailing, rfl, rfl,
      fun msgs₂ trailing₂ => ⟨msgs₂, run msgs₂ trailing₂⟩, fun _ _ _ hne => absurd rfl hne⟩
  · obtain ⟨system', tools', h⟩ := cache_marked system tools enabled (by simpa using hen)
    obtain ⟨out, hout, hm⟩ := h msgs trailing
    refine ⟨system', tools', out, hout, hm.erase, hm.length, fun msgs₂ trailing₂ => ?_,
      fun i n ht hne => ?_⟩
    · obtain ⟨out₂, h₂, -⟩ := h msgs₂ trailing₂
      exact ⟨out₂, h₂⟩
    · have lt := hm.index i hne
      subst ht
      simpa [cacheDurable] using lt

end VerifiedKernel.ProviderLoop
