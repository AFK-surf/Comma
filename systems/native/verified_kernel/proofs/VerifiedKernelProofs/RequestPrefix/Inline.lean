import VerifiedKernelProofs.RequestPrefix.Stateless
import VerifiedKernel.Session.Attachments

/-!
Attachment inlining under a deterministic host.

`Session.Attachments.inline` reads host answers in two batches: the result records that the
sources request, and the image blocks of the native refs. When every observation on the journal
returns the host's answer and keeps the journal, and every prefetched answer is the host's answer,
`inline` maps each message on its own: its output is `L.map (inlineOne host w)`.
-/

namespace VerifiedKernel.RequestPrefix
open Data Provider

set_option maxHeartbeats 4000000

/-- The answer of a deterministic host. A batch request is answered request by request. -/
def hostAnswer (host : Term → Term) (r : Term) : Term :=
  match r with
  | .tuple [.atom "request_batch", .list rs] => list (rs.map host)
  | _ => host r

/-- Every successful observation on `J` returns the host's answer and keeps `J`. -/
def HostAnswers (host : Term → Term) (J : List Term) : Prop :=
  ∀ r v J', observe r J = .ok (v, J') → J' = J ∧ v = hostAnswer host r

/-- Every prefetched answer is the host's answer to each request that its key matches. -/
def PrefetchSound (host : Term → Term) (pre : List (Term × Term)) : Prop :=
  ∀ p ∈ pre, ∀ r, (p.1 == r) = true → p.2 = host r

theorem hostAnswer_batch (host : Term → Term) (rs : List Term) :
    hostAnswer host (.tuple [a "request_batch", list rs]) = list (rs.map host) := rfl

/-- A batch read returns the host's answer to each request and keeps the journal. -/
theorem readBatch_host {host : Term → Term} {J J' rs vs : List Term} (hJ : HostAnswers host J)
    (h : Session.Attachments.readBatch rs J = .ok (vs, J')) : vs = rs.map host ∧ J' = J := by
  unfold Session.Attachments.readBatch at h
  split at h
  · rename_i e
    simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    simp only [List.isEmpty_iff] at e
    subst e; exact ⟨rfl, rfl⟩
  · have step := Session.bind_ok_iff.mp h; clear h
    obtain ⟨v, J₁, ho, h⟩ := step
    obtain ⟨rfl, rfl⟩ := hJ _ _ _ ho
    have step := Session.bind_ok_iff.mp h; clear h
    obtain ⟨xs, J₂, hl, h⟩ := step
    rw [hostAnswer_batch, Session.asList_ok_iff] at hl
    obtain ⟨hl, rfl⟩ := hl
    cases hl
    split at h
    · exact absurd h (by simp [Session.fail_ok_iff])
    · simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      exact ⟨rfl, rfl⟩

/-- A loop whose step consumes `need x` from the front of the answer list and prepends `out x`. -/
theorem forIn_consume {α : Type} {f : α → List Term × List Term → KernelM (ForInStep (List Term × List Term))}
    (P : α → Prop) (need out : α → List Term)
    (step : ∀ x, P x → ∀ tail acc J s J₁, f x (need x ++ tail, acc) J = .ok (s, J₁) →
      s = .yield (tail, out x ++ acc) ∧ J₁ = J) :
    ∀ (xs : List α), (∀ x ∈ xs, P x) → ∀ (tail acc : List Term) (J : List Term) (v : List Term × List Term) (J' : List Term),
      ForIn.forIn xs (xs.flatMap need ++ tail, acc) f J = .ok (v, J') →
      v = (tail, xs.foldl (fun acc x => out x ++ acc) acc) ∧ J' = J
  | [], _, tail, acc, J, v, J', h => by
    rw [List.forIn_nil] at h
    simp only [List.flatMap_nil, List.nil_append, Session.pure_ok_iff, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨rfl, rfl⟩
  | x :: xs, hP, tail, acc, J, v, J', h => by
    rw [List.forIn_cons, List.flatMap_cons, List.append_assoc] at h
    have h' := Session.bind_ok_iff.mp h; clear h
    obtain ⟨s, J₁, hs, h⟩ := h'
    obtain ⟨rfl, rfl⟩ := step x (hP x (List.mem_cons_self ..)) _ _ _ _ _ hs
    exact forIn_consume P need out step xs (fun y hy => hP y (List.mem_cons_of_mem _ hy)) tail _ _ _ _ h

/-- The request of a source result that `sources` reads in its batch: one that no prefetched key matches. -/
def sel (pre : List (Term × Term)) (r : Except Signal (Term × List Term)) : Option Term :=
  match r with
  | .error (.observe q) => if ((pre.find? (·.1 == q)).map Prod.snd).isSome then none else some q
  | _ => none

/-- The source value of message `m` with first result `r`, when the host answers its request. -/
def settle (host : Term → Term) (m : Term) (r : Except Signal (Term × List Term)) : Term :=
  match r with
  | .ok (v, _) => v
  | .error (.observe q) =>
    match Session.Attachments.source m [.tuple [a "ok", host q]] with
    | .ok (v, _) => v
    | .error _ => m
  | .error (.raised _) => m

/-- What `source` gives for one message when the host answers its request. -/
def sourceOf (host : Term → Term) (m : Term) : Term := settle host m (Session.Attachments.source m [])

theorem foldl_out {α : Type} (out : α → List Term) :
    ∀ (xs : List α) (acc : List Term),
      xs.foldl (fun acc x => out x ++ acc) acc = (xs.flatMap fun x => (out x).reverse).reverse ++ acc
  | [], acc => rfl
  | x :: xs, acc => by
    rw [List.foldl_cons, foldl_out out xs, List.flatMap_cons, List.reverse_append, List.reverse_reverse,
      List.append_assoc]

theorem sources_requests (host : Term → Term) (pre : List (Term × Term)) :
    ∀ msgs : List Term,
      ((msgs.map fun m => Session.Attachments.source m []).filterMap (sel pre)).map host =
        (msgs.map fun m => (m, Session.Attachments.source m [])).flatMap
          (fun x => ((sel pre x.2).toList).map host) ++ []
  | [] => rfl
  | m :: ms => by
    have ih := sources_requests host pre ms
    rw [List.append_nil] at ih ⊢
    simp only [List.map_cons, List.filterMap_cons, List.flatMap_cons]
    cases sel pre (Session.Attachments.source m []) with
    | none => simp only [Option.toList_none, List.map_nil, List.nil_append]; exact ih
    | some q => simp only [Option.toList_some, List.map_cons, List.map_nil, List.cons_append, List.nil_append]; rw [ih]

theorem zip_self_map {α β : Type} (g : α → β) : ∀ xs : List α, xs.zip (xs.map g) = xs.map fun x => (x, g x)
  | [] => rfl
  | x :: xs => by simp [zip_self_map g xs]

theorem flatMap_settle (host : Term → Term) : ∀ msgs : List Term,
    (msgs.map fun x => (x, Session.Attachments.source x [])).flatMap
      (fun x => [settle host x.1 x.2].reverse) = msgs.map (sourceOf host)
  | [] => rfl
  | m :: ms => by
    rw [List.map_cons, List.flatMap_cons, flatMap_settle host ms]; rfl

theorem throw_bind_ok {α β : Type} {e : Signal} {k : α → KernelM β} {J : List Term} {r : β × List Term} :
    ((throw e : KernelM α) >>= k) J = .ok r → False := by
  intro h
  obtain ⟨_, _, h, -⟩ := Session.bind_ok_iff.mp h
  cases h

/-- One step of the `sources` loop consumes the batch answer of its request, if any, and adds `settle`. -/
theorem sources_step {host : Term → Term} {pre : List (Term × Term)} (hpre : PrefetchSound host pre)
    {m : Term} {r : Except Signal (Term × List Term)} {tail acc J J₁ : List Term} {s : ForInStep (List Term × List Term)}
    (hs : (match r with
      | Except.ok (value, _) => pure (ForInStep.yield (List.map host (sel pre r).toList ++ tail, value :: acc))
      | Except.error (Signal.raised reason) => do
        throw (Signal.raised reason)
        pure (ForInStep.yield (List.map host (sel pre r).toList ++ tail, acc))
      | Except.error (Signal.observe request) =>
        match Option.map Prod.snd (List.find? (fun x => x.fst == request) pre) with
        | some answer => do
          let answer ← pure answer
          match Session.Attachments.source m [Term.tuple [a "ok", answer]] with
            | Except.ok (value, _) => pure (ForInStep.yield (List.map host (sel pre r).toList ++ tail, value :: acc))
            | Except.error signal => do
              throw signal
              pure (ForInStep.yield (List.map host (sel pre r).toList ++ tail, acc))
        | none => do
          let answer ← pure (List.map host (sel pre r).toList ++ tail).head!
          match Session.Attachments.source m [Term.tuple [a "ok", answer]] with
            | Except.ok (value, _) =>
              pure (ForInStep.yield (List.drop 1 (List.map host (sel pre r).toList ++ tail), value :: acc))
            | Except.error signal => do
              throw signal
              pure (ForInStep.yield (List.drop 1 (List.map host (sel pre r).toList ++ tail), acc)) :
        KernelM (ForInStep (List Term × List Term))) J = .ok (s, J₁)) :
    s = .yield (tail, [settle host m r] ++ acc) ∧ J₁ = J := by
  cases r with
  | ok p =>
    obtain ⟨v, _⟩ := p
    simp only [sel, Option.toList_none, List.map_nil, List.nil_append, Session.pure_ok_iff, Prod.mk.injEq] at hs
    obtain ⟨rfl, rfl⟩ := hs
    exact ⟨rfl, rfl⟩
  | error e =>
  cases e with
  | raised q => exact (throw_bind_ok hs).elim
  | observe q =>
    simp only at hs
    cases hf : pre.find? (fun x => x.fst == q) with
    | none =>
      have hsel : sel pre (.error (.observe q)) = some q := by simp [sel, hf]
      simp only [hf, hsel, Option.map_none, Option.toList_some, List.map_cons, List.map_nil, List.cons_append,
        List.nil_append, List.head!, List.drop_one, List.tail_cons] at hs
      have step := Session.bind_ok_iff.mp hs; clear hs
      obtain ⟨ans, J₂, hp, hs⟩ := step
      simp only [Session.pure_ok_iff, Prod.mk.injEq] at hp
      obtain ⟨rfl, rfl⟩ := hp
      unfold settle
      cases e : Session.Attachments.source m [Term.tuple [a "ok", host q]] with
      | ok p =>
        obtain ⟨v, _⟩ := p
        simp only [e, Session.pure_ok_iff, Prod.mk.injEq] at hs ⊢
        obtain ⟨rfl, rfl⟩ := hs
        exact ⟨rfl, rfl⟩
      | error sig =>
        simp only [e] at hs
        exact (throw_bind_ok hs).elim
    | some p =>
      have hk := List.find?_some hf
      have hp : p.2 = host q := hpre p (List.mem_of_find?_eq_some hf) q hk
      have hsel : sel pre (.error (.observe q)) = none := by simp [sel, hf]
      simp only [hf, hsel, Option.map_some, Option.toList_none, List.map_nil, List.nil_append] at hs
      have step := Session.bind_ok_iff.mp hs; clear hs
      obtain ⟨ans, J₂, hq, hs⟩ := step
      simp only [Session.pure_ok_iff, Prod.mk.injEq] at hq
      obtain ⟨rfl, rfl⟩ := hq
      rw [hp] at hs
      unfold settle
      cases e : Session.Attachments.source m [Term.tuple [a "ok", host q]] with
      | ok p =>
        obtain ⟨v, _⟩ := p
        simp only [e, Session.pure_ok_iff, Prod.mk.injEq] at hs ⊢
        obtain ⟨rfl, rfl⟩ := hs
        exact ⟨rfl, rfl⟩
      | error sig =>
        simp only [e] at hs
        exact (throw_bind_ok hs).elim

/-- `sources` maps each message to `sourceOf host` and keeps the journal. -/
theorem sources_host {host : Term → Term} {msgs out : List Term} {pre : List (Term × Term)} {J J' : List Term}
    (hJ : HostAnswers host J) (hpre : PrefetchSound host pre)
    (h : Session.Attachments.sources msgs pre J = .ok (out, J')) :
    out = msgs.map (sourceOf host) ∧ J' = J := by
  unfold Session.Attachments.sources at h
  have step := Session.bind_ok_iff.mp h; clear h
  obtain ⟨answers, J₁, hb, h⟩ := step
  obtain ⟨rfl, rfl⟩ := readBatch_host hJ hb
  have step := Session.bind_ok_iff.mp h; clear h
  obtain ⟨s, J₂, hl, h⟩ := step
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨rfl, rfl⟩ := h
  change ForIn.forIn (m := KernelM) _ (((msgs.map fun m => Session.Attachments.source m []).filterMap (sel pre)).map host, ([] : List Term)) _ _ = _ at hl
  rw [sources_requests, zip_self_map] at hl
  refine (fun this => ?_) (forIn_consume (fun _ => True)
    (fun x : Term × Except Signal (Term × List Term) => ((sel pre x.2).toList).map host)
    (fun x => [settle host x.1 x.2]) ?step _ (fun _ _ => trivial) _ _ _ _ _ hl)
  case step =>
    intro x _ tail acc J s J₁ hs
    obtain ⟨m, r⟩ := x
    simp only at hs
    exact sources_step hpre hs
  obtain ⟨rfl, rfl⟩ := this
  refine ⟨?_, rfl⟩
  rw [foldl_out, List.append_nil, List.reverse_reverse]
  exact flatMap_settle host msgs


/-- The blocks that `inline` reads from one source result. -/
def blocksOf (s : Term) : List Term :=
  match s with
  | .tuple [.atom "ok", .list blocks, .atom "user_attachment"] => blocks.map Session.Attachments.announced
  | .tuple [.atom "ok", .list blocks, _] => blocks
  | _ => []

/-- The image request of a native-ref block. -/
def imageReq (block : Term) : Option Term :=
  if Session.Attachments.nativeRef block then some (.tuple [a "request_image", block]) else none

/-- A block with its host answer: a native-ref block becomes the listed answer to its image request. -/
def resolveBlock (host : Term → Term) (block : Term) : List Term :=
  if Session.Attachments.nativeRef block then items (host (.tuple [a "request_image", block])) else [block]

/-- The value of `Provider.encode`, which reads no host answer. -/
def encodeOf (t : Term) : Term :=
  match Provider.encode t [] with
  | .ok (v, _) => v
  | .error _ => nil

/-- The projected message for message `m` with source result `s` and blocks `bl`. -/
def project (host : Term → Term) (m s : Term) (bl : List Term) : Term :=
  let projected := match s with
    | .tuple [.atom "ok", _, _] =>
      let p := Session.Attachments.putField m "content" (encodeOf (list (bl.flatMap (resolveBlock host))))
      let p := p.put (if m.has (a "role") then a "native_content_trusted" else b "native_content_trusted") (a "true")
      if Provider.field m "role" == b "runtime" then Session.Attachments.putField p "role" (b "user") else p
    | _ => m
  if member (Provider.field m "role") ["user", "tool", "runtime"] then
    Session.Attachments.dropField projected "result_seq"
  else projected

/-- What `inline` produces for one message with watermark `w`, when the host answers every request. -/
def inlineOne (host : Term → Term) (w m : Term) : Term :=
  let s := sourceOf host (if Session.Attachments.candidate true w m then m else nil)
  project host m s (blocksOf s)

theorem zip_sources {c so : Term → Term} {B : Term → List Term} : ∀ L : List Term,
    (L.zip ((L.map c).map so)).zip (((L.map c).map so).map B) =
      L.map fun m => ((m, so (c m)), B (so (c m)))
  | [] => rfl
  | m :: ms => by simp only [List.map_cons, List.zip_cons_cons, zip_sources ms]

theorem image_requests (host : Term → Term) {c so : Term → Term} {B : Term → List Term} : ∀ L : List Term,
    ((((L.map c).map so).map B).flatten.filterMap imageReq).map host =
      (L.map fun m => ((m, so (c m)), B (so (c m)))).flatMap
        (fun x : (Term × Term) × List Term => (x.2.filterMap imageReq).map host) ++ []
  | [] => rfl
  | m :: ms => by
    have ih := image_requests host (c := c) (so := so) (B := B) ms
    rw [List.append_nil] at ih ⊢
    simp only [List.map_cons, List.flatten_cons, List.filterMap_append, List.map_append, List.flatMap_cons, ih]

/-- The image answers that one block consumes. -/
def needInner (host : Term → Term) (block : Term) : List Term :=
  if Session.Attachments.nativeRef block then [host (.tuple [a "request_image", block])] else []

theorem image_need (host : Term → Term) : ∀ bl : List Term,
    (bl.filterMap imageReq).map host = bl.flatMap (needInner host)
  | [] => rfl
  | x :: xs => by
    rw [List.filterMap_cons, List.flatMap_cons, ← image_need host xs]
    unfold imageReq needInner
    by_cases hn : Session.Attachments.nativeRef x = true <;> simp [hn]

theorem project_ok (host : Term → Term) (m h1 h2 : Term) (bl : List Term) :
    project host m (.tuple [.atom "ok", h1, h2]) bl =
      let p := Session.Attachments.putField m "content" (encodeOf (list (bl.flatMap (resolveBlock host))))
      let p := p.put (if m.has (a "role") then a "native_content_trusted" else b "native_content_trusted") (a "true")
      let p := if Provider.field m "role" == b "runtime" then Session.Attachments.putField p "role" (b "user") else p
      if member (Provider.field m "role") ["user", "tool", "runtime"] then
        Session.Attachments.dropField p "result_seq"
      else p := rfl

theorem project_other (host : Term → Term) (m src : Term) (bl : List Term)
    (hno : ∀ h1 h2, src = .tuple [.atom "ok", h1, h2] → False) :
    project host m src bl =
      if member (Provider.field m "role") ["user", "tool", "runtime"] then
        Session.Attachments.dropField m "result_seq"
      else m := by
  unfold project
  split
  · exact (hno _ _ rfl).elim
  · rfl

theorem flatMap_inlineOne (host : Term → Term) (w : Term) : ∀ L : List Term,
    (L.map fun m =>
        ((m, sourceOf host (if Session.Attachments.candidate true w m = true then m else nil)),
          blocksOf (sourceOf host (if Session.Attachments.candidate true w m = true then m else nil)))).flatMap
      (fun x : (Term × Term) × List Term => [project host x.1.1 x.1.2 x.2].reverse) = L.map (inlineOne host w)
  | [] => rfl
  | m :: ms => by
    rw [List.map_cons, List.flatMap_cons, flatMap_inlineOne host w ms]; rfl

/-- `inline` with `enabled = true` maps each message by `inlineOne` and keeps the journal. -/
theorem inline_map {host : Term → Term} {L out : List Term} {w : Term} {pre : List (Term × Term)} {J J' : List Term}
    (hJ : HostAnswers host J) (hpre : PrefetchSound host pre)
    (h : Session.Attachments.inline L w true pre J = .ok (out, J')) :
    out = L.map (inlineOne host w) ∧ J' = J := by
  unfold Session.Attachments.inline at h
  have step := Session.bind_ok_iff.mp h; clear h
  obtain ⟨srcs, J₁, hs, h⟩ := step
  obtain ⟨rfl, rfl⟩ := sources_host hJ hpre hs
  have step := Session.bind_ok_iff.mp h; clear h
  obtain ⟨answers, J₂, hb, h⟩ := step
  obtain ⟨rfl, rfl⟩ := readBatch_host hJ hb
  have step := Session.bind_ok_iff.mp h; clear h
  obtain ⟨s, J₃, hl, h⟩ := step
  simp only [Session.pure_ok_iff, Prod.mk.injEq] at h
  obtain ⟨rfl, rfl⟩ := h
  change ForIn.forIn (m := KernelM)
    ((L.zip ((L.map fun message => if Session.Attachments.candidate true w message = true then message else nil).map
        (sourceOf host))).zip
      (((L.map fun message => if Session.Attachments.candidate true w message = true then message else nil).map
        (sourceOf host)).map blocksOf))
    (((((L.map fun message => if Session.Attachments.candidate true w message = true then message else nil).map
        (sourceOf host)).map blocksOf).flatten.filterMap imageReq).map host, ([] : List Term)) _ _ = _ at hl
  rw [image_requests, zip_sources] at hl
  refine (fun this => ?_) (forIn_consume (fun x : (Term × Term) × List Term => x.2 = blocksOf x.1.2)
    (fun x => (x.2.filterMap imageReq).map host)
    (fun x => [project host x.1.1 x.1.2 x.2]) ?step _ ?all _ _ _ _ _ hl)
  case all =>
    intro x hx
    obtain ⟨m, -, rfl⟩ := List.mem_map.mp hx
    rfl
  case step =>
    intro x hbl tail acc J s J₁ hs
    obtain ⟨⟨m, src⟩, bl⟩ := x
    simp only at hbl
    subst hbl
    simp only at hs
    split at hs
    · rename_i h1 h2
      have step := Session.bind_ok_iff.mp hs; clear hs
      obtain ⟨st, J₂', hin, hs⟩ := step
      rw [image_need] at hin
      refine (fun this => ?_) (forIn_consume (fun _ => True) (needInner host) (fun x => (resolveBlock host x).reverse)
        ?inner _ (fun _ _ => trivial) tail [] _ _ _ hin)
      case inner =>
        intro block _ tail' acc' J₀ s₀ J₀' h₀
        by_cases hn : Session.Attachments.nativeRef block = true
        · simp only [needInner, resolveBlock, hn, if_true, List.cons_append, List.head!, List.drop_one, List.tail_cons] at h₀ ⊢
          have step := Session.bind_ok_iff.mp h₀; clear h₀
          obtain ⟨vs, J₄, hv, h₀⟩ := step
          rw [Session.asList_ok_iff] at hv
          obtain ⟨hv, rfl⟩ := hv
          rw [hv]
          simp only [pure_bind, Session.pure_ok_iff, Prod.mk.injEq] at h₀
          obtain ⟨rfl, rfl⟩ := h₀
          exact ⟨rfl, rfl⟩
        · simp only [needInner, resolveBlock, hn, Bool.false_eq_true, if_false, List.nil_append, pure_bind, Session.pure_ok_iff,
            Prod.mk.injEq] at h₀ ⊢
          obtain ⟨rfl, rfl⟩ := h₀
          exact ⟨rfl, rfl⟩
      obtain ⟨rfl, rfl⟩ := this
      have step := Session.bind_ok_iff.mp hs; clear hs
      obtain ⟨e, J₃, he, hs⟩ := step
      have hk := (Provider.encode.stateless _).keep he
      subst hk
      have he0 := (Provider.encode.stateless _).run he []
      rw [foldl_out] at he0 hs
      simp only [List.reverse_reverse, List.append_nil] at he0 hs
      have henc : encodeOf (list ((blocksOf (.tuple [.atom "ok", h1, h2])).flatMap (resolveBlock host))) = e := by
        unfold encodeOf; rw [he0]
      simp only [project_ok, henc]
      by_cases r1 : (Provider.field m "role" == b "runtime") = true <;>
        by_cases r2 : member (Provider.field m "role") ["user", "tool", "runtime"] = true <;>
        simp only [r1, r2, if_true, if_false, Bool.false_eq_true, Session.pure_ok_iff, Prod.mk.injEq] at hs ⊢ <;>
        (obtain ⟨rfl, rfl⟩ := hs; exact ⟨rfl, rfl⟩)
    · rename_i hno
      have hnil : blocksOf src = [] := by
        unfold blocksOf
        split
        · exact (hno _ _ rfl).elim
        · exact (hno _ _ rfl).elim
        · rfl
      rw [hnil] at hs ⊢
      simp only [project_other host m src _ hno]
      by_cases r2 : member (Provider.field m "role") ["user", "tool", "runtime"] = true <;>
        simp only [r2, if_true, if_false, Bool.false_eq_true, List.filterMap_nil, List.map_nil, List.nil_append,
          Session.pure_ok_iff, Prod.mk.injEq] at hs ⊢ <;>
        (obtain ⟨rfl, rfl⟩ := hs; exact ⟨rfl, rfl⟩)
  obtain ⟨rfl, rfl⟩ := this
  refine ⟨?_, rfl⟩
  rw [foldl_out, List.append_nil, List.reverse_reverse]
  exact flatMap_inlineOne host w L

end VerifiedKernel.RequestPrefix
