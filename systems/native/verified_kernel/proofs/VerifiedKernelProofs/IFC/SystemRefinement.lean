import VerifiedKernelProofs.Order
import VerifiedKernelProofs.IFC.System
import VerifiedKernel.IFC.Kernel

/-!
The executable clause selector satisfies its branch conditions. FullRefinement
uses this lemma for the complete wire contract. SemanticRefinement proves the
concrete helper semantics and independent system authorization.
-/
namespace VerifiedKernel.IFC.SystemRefinement
open Data

def Selected (flow readable : Tri) (locked inPlace instruction : Bool)
    (receipt : Option Term) : Admission → Prop
  | .flow => flow = .yes
  | .inPlace => locked = false ∧ readable = .yes ∧ inPlace = true
  | .instruction => locked = false ∧ readable = .yes ∧ instruction = true
  | .receipt id => locked = false ∧ readable = .yes ∧ receipt = some id

theorem selectAdmission_sound
    (h : selectAdmission flow readable locked inPlace instruction receipt = .ok admitted) :
    Selected flow readable locked inPlace instruction receipt admitted := by
  cases flow <;> cases readable <;> cases locked <;> cases inPlace <;>
    cases instruction <;> cases receipt <;> cases admitted <;> simp_all [selectAdmission, Selected]

end VerifiedKernel.IFC.SystemRefinement
