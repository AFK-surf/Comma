import VerifiedKernelProofs.Session.WorkPhysicalArchive

namespace VerifiedKernel.Session.ArchivePublication
open Data WorkConservation
set_option Elab.async false

/-- Earlier immutable storage observations remain valid after other writers append objects. -/
theorem PrimitiveStep.in_extension {before after current : Objects} {request result : Term}
    (step : PrimitiveStep before after request result) (extension : ObjectsExtend after current) :
    PrimitiveStep current current request result := by
  obtain ⟨_, read, create, existing, codec⟩ := step
  refine ⟨fun _ _ h => h, ?_, ?_, ?_, codec⟩
  · intro agent session first records requested returned
    exact extension _ _ (read agent session first records requested returned)
  · intro agent session first bytes records requested encoded returned
    exact extension _ _ (create agent session first bytes records requested encoded returned)
  · intro agent session first bytes records requested returned
    exact extension _ _ (existing agent session first bytes records requested returned)

/-- This transports evidence, not network calls. No request is reissued at runtime. -/
theorem Execution.in_extension {initial final : Output} {before after current : Objects}
    (execution : Execution initial before final after) (extension : ObjectsExtend after current) :
    Execution initial current final current := by
  induction execution with
  | done => exact .done _ _
  | step primitive tail ih =>
    exact .step (primitive.in_extension (fun key records h =>
      extension key records (execution_objects_extend tail key records h))) (ih extension)

end VerifiedKernel.Session.ArchivePublication
