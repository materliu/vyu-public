import Foundation

/// Selection is scoped to the local rows currently visible after filtering.
struct OfflineSelection {
    private(set) var isActive = false
    private(set) var ids: Set<UUID> = []

    mutating func begin() {
        isActive = true
        ids.removeAll()
    }

    mutating func end() {
        isActive = false
        ids.removeAll()
    }

    mutating func reconcile(visibleLocalIDs: Set<UUID>) {
        ids.formIntersection(visibleLocalIDs)
    }

    mutating func toggle(_ id: UUID, visibleLocalIDs: Set<UUID>) {
        guard isActive else { return }
        reconcile(visibleLocalIDs: visibleLocalIDs)
        guard visibleLocalIDs.contains(id) else { return }
        if !ids.insert(id).inserted { ids.remove(id) }
    }

    func includesAll(visibleLocalIDs: Set<UUID>) -> Bool {
        !visibleLocalIDs.isEmpty && visibleLocalIDs.isSubset(of: ids)
    }

    mutating func toggleAll(visibleLocalIDs: Set<UUID>) {
        guard isActive else { return }
        if includesAll(visibleLocalIDs: visibleLocalIDs) { ids.removeAll() }
        else { ids = visibleLocalIDs }
    }
}
