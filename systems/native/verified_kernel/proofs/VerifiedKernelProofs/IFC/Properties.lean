import VerifiedKernelProofs.Order
import VerifiedKernel.IFC.Kernel

namespace VerifiedKernel.IFC
open Data

theorem conjunction_permission (x y : Tri) :
    x.and y = .yes ↔ x = .yes ∧ y = .yes := by
  cases x <;> cases y <;> simp [Tri.and]

theorem sealed_blocks_declassification (flow readable : Tri) (inPlace instruction : Bool)
    (receipt : Option Term) (notFlow : flow ≠ .yes) :
    selectAdmission flow readable true inPlace instruction receipt = .error .sealed := by
  cases flow <;> simp_all [selectAdmission]

theorem receipt_requires_read_permission (flow readable : Tri) (locked inPlace instruction : Bool)
    (receipt : Option Term) (id : Term)
    (allowed : selectAdmission flow readable locked inPlace instruction receipt = .ok (.receipt id)) :
    readable = .yes := by
  cases flow <;> cases readable <;> cases locked <;> cases inPlace <;> cases instruction <;>
    cases receipt <;> simp_all [selectAdmission]

theorem in_place_requires_read_permission (flow readable : Tri) (locked inPlace instruction : Bool)
    (receipt : Option Term)
    (allowed : selectAdmission flow readable locked inPlace instruction receipt = .ok .inPlace) :
    readable = .yes := by
  cases flow <;> cases readable <;> cases locked <;> cases inPlace <;> cases instruction <;>
    cases receipt <;> simp_all [selectAdmission]

theorem instruction_requires_read_permission (flow readable : Tri) (locked inPlace instruction : Bool)
    (receipt : Option Term)
    (allowed : selectAdmission flow readable locked inPlace instruction receipt = .ok .instruction) :
    readable = .yes := by
  cases flow <;> cases readable <;> cases locked <;> cases inPlace <;> cases instruction <;>
    cases receipt <;> simp_all [selectAdmission]

theorem unknown_is_not_permission (locked inPlace instruction : Bool) (receipt : Option Term)
    (admission : Admission) :
    selectAdmission .unknown .unknown locked inPlace instruction receipt ≠ .ok admission := by
  cases locked <;> simp [selectAdmission]

theorem data_request_denied (item activation : Term) (data : f item "integrity" = a "data") :
    requestCheck item activation = .error (reason "request_not_command" (f item "ref")) := by
  have same : (a "data" != a "command") = true := rfl
  simp [requestCheck, data, same]

theorem request_requires_consumed_ref (item activation : Term)
    (accepted : requestCheck item activation = .ok ()) :
    contains (setValues (f activation "consumed_refs")) (f item "ref") = true := by
  unfold requestCheck at accepted
  split at accepted <;> simp_all
  split at accepted <;> simp_all
  split at accepted <;> simp_all

theorem invalid_input_denied (effect activation items facts why : Term)
    (invalid : validate effect activation items facts = .error why) :
    decideChecked effect activation items facts = .error why := by
  simp [decideChecked, invalid]
  rfl

end VerifiedKernel.IFC
