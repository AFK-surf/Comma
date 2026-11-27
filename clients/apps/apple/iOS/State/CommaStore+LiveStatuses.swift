import CommaCore
import Foundation

/// Foreground reconciliation for generalized Live Status activities (`live_status_v1`).
extension CommaStore {
    func refreshLiveStatuses() async {
        guard let workspace, session != nil else { return }
        liveStatusesRequest += 1
        let request = liveStatusesRequest
        let current = boundary
        do {
            let answer = try await core.object("notifications.liveStatuses", ["group": workspace.groupID])
            guard boundary == current, self.workspace?.id == workspace.id, request == liveStatusesRequest else { return }
            let next = answer.objects("items").compactMap { item -> LiveStatusItem? in
                guard let key = item.string("key"),
                      let workspaceID = item.string("workspaceId"),
                      let groupID = item.string("groupId"),
                      let category = item.string("category"),
                      let status = item.string("status"),
                      let title = item.text("title") else { return nil }
                return LiveStatusItem(
                    key: key,
                    workspaceID: workspaceID,
                    groupID: groupID,
                    conversationID: item.string("conversationId"),
                    category: category,
                    status: status,
                    accent: item.string("accent") ?? "auto",
                    title: title,
                    subtitle: item.text("subtitle"),
                    compactLabel: item.text("compactLabel"),
                    etaEpochSeconds: item.int("etaEpochSeconds"),
                    progress: item.double("progress"),
                    stepCurrent: item.int("stepCurrent"),
                    stepTotal: item.int("stepTotal"),
                    stepLabel: item.text("stepLabel"),
                    detailLeft: item.text("detailLeft"),
                    detailRight: item.text("detailRight"),
                    staleEpochSeconds: item.int("staleEpochSeconds"),
                    expiresEpochSeconds: item.int("expiresEpochSeconds"),
                    startedAtEpochSeconds: item.int("startedAtEpochSeconds"),
                    dismissAtEpochSeconds: item.int("dismissAtEpochSeconds"),
                    updatedAtEpochSeconds: item.int("updatedAtEpochSeconds") ?? 0
                )
            }
            liveStatuses = next
            onLiveStatusesSnapshot?(next, workspace)
        } catch {
            guard boundary == current, self.workspace?.id == workspace.id, request == liveStatusesRequest else { return }
            onLiveStatusesFailure?(error.localizedDescription)
        }
    }
}
