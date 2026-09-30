import VerifiedKernelProofs.Order
import VerifiedKernel.Provider.Dispatch
import VerifiedKernel.Provider.Request
import VerifiedKernel.Provider.Response
import VerifiedKernel.Provider.Usage
import VerifiedKernel.Provider.Complete

namespace VerifiedKernel.Provider
open Data

theorem no_retry_after_stream_data (attempts : Int) :
    retry (a "transport") (a "true") attempts = a "stop" := by
  simp [retry, show (a "true" != a "true") = false from rfl]

theorem no_retry_after_budget (status seen : Term) (attempts : Int) (h : attempts ≤ 1) :
    retry status seen attempts = a "stop" := by simp [retry, show ¬attempts > 1 by omega]

end VerifiedKernel.Provider
