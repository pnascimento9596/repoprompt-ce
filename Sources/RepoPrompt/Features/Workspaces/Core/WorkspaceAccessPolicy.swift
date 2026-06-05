import Foundation

/// Host-level admission policy for workspace roots.
///
/// Item 3 stages this seam inside the monolithic app target. The embedded app keeps
/// its existing unrestricted behavior; the future standalone host supplies a
/// fail-closed implementation after the physical core split.
@MainActor
protocol WorkspaceAccessPolicy: AnyObject {
    func allowsWorkspaceRoot(_ url: URL) -> Bool
}

@MainActor
final class UnrestrictedWorkspaceAccessPolicy: WorkspaceAccessPolicy {
    func allowsWorkspaceRoot(_ url: URL) -> Bool {
        _ = url
        return true
    }
}
