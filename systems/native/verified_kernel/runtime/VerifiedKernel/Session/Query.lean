import VerifiedKernel.Session.Query.State
import VerifiedKernel.Session.Query.Reply
import VerifiedKernel.Session.Query.Round
import VerifiedKernel.Session.Query.Compaction
import VerifiedKernel.Session.Query.Repair
import VerifiedKernel.Session.Query.Runtime
import VerifiedKernel.Session.Query.Storage
import VerifiedKernel.Session.Query.Provenance
import VerifiedKernel.Session.Fork
import VerifiedKernel.Session.Command
import VerifiedKernel.Session.Presentation
import VerifiedKernel.Session.ScheduledPresentation
import VerifiedKernel.Session.Settlement
import VerifiedKernel.Session.Restart
import VerifiedKernel.Session.Request
import VerifiedKernel.Session.StorageCommit
import VerifiedKernel.Session.ArchiveMatch
import VerifiedKernel.Session.LoopHost
import VerifiedKernel.Session.CompactionHost
import VerifiedKernel.Session.WriteValidation
import VerifiedKernel.Session.FenceStamp
import VerifiedKernel.Session.RepairHost

namespace VerifiedKernel.Session
open Data

/-- Every query the host can ask. -/
def queryTable : OpTable :=
  StateQuery.table ++ ReplyQuery.table ++ RoundQuery.table ++ CompactionQuery.table ++
    RepairQuery.table ++ RuntimeQuery.table ++ StorageQuery.table ++
    ProvenanceQuery.table ++ Fork.queryTable ++ Command.table ++ Presentation.table ++ ScheduledPresentation.table ++ Settlement.table ++ Restart.table ++ Request.table ++ ArchiveMatch.table ++ LoopHost.table ++ CompactionHost.table ++ WriteValidation.table ++ FenceStamp.table ++ RepairHost.table

/-- Every lifecycle operation the host can run over a resident state. -/
def lifecycleTable : OpTable := Lifecycle.table ++ Fork.lifecycleTable

end VerifiedKernel.Session
