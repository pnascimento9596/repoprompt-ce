import Combine
import SwiftUI

private enum UpdateAvailableToolbarSnapshot: Equatable {
    case hidden
    case available(displayVersion: String?, canCheckForUpdates: Bool)
}

@MainActor
private final class UpdateAvailableToolbarStateObserver: ObservableObject {
    @Published private(set) var snapshot: UpdateAvailableToolbarSnapshot

    private var cancellables = Set<AnyCancellable>()

    init(sparkleManager: SparkleUpdaterManager) {
        snapshot = Self.makeSnapshot(
            updateAvailable: sparkleManager.updateAvailable,
            updateVersion: sparkleManager.updateVersion,
            canCheckForUpdates: sparkleManager.canCheckForUpdates
        )

        Publishers.CombineLatest3(
            sparkleManager.$updateAvailable.removeDuplicates(),
            sparkleManager.$updateVersion.removeDuplicates(),
            sparkleManager.$canCheckForUpdates.removeDuplicates()
        )
        .map(Self.makeSnapshot(updateAvailable:updateVersion:canCheckForUpdates:))
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .sink { [weak self] snapshot in
            guard let self, self.snapshot != snapshot else { return }
            self.snapshot = snapshot
        }
        .store(in: &cancellables)
    }

    private nonisolated static func makeSnapshot(
        updateAvailable: Bool,
        updateVersion: String?,
        canCheckForUpdates: Bool
    ) -> UpdateAvailableToolbarSnapshot {
        guard updateAvailable else { return .hidden }
        return .available(
            displayVersion: normalizedDisplayVersion(updateVersion),
            canCheckForUpdates: canCheckForUpdates
        )
    }

    private nonisolated static func normalizedDisplayVersion(_ version: String?) -> String? {
        guard let version = version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else { return nil }
        return version.lowercased().hasPrefix("v") ? version : "v\(version)"
    }
}

/// Compact toolbar affordance for a known available app update.
@MainActor
struct UpdateAvailableToolbarPill: View {
    private let sparkleManager: SparkleUpdaterManager
    @StateObject private var observer: UpdateAvailableToolbarStateObserver

    init(sparkleManager: SparkleUpdaterManager) {
        self.sparkleManager = sparkleManager
        _observer = StateObject(wrappedValue: UpdateAvailableToolbarStateObserver(sparkleManager: sparkleManager))
    }

    var body: some View {
        switch observer.snapshot {
        case .hidden:
            EmptyView()
        case let .available(displayVersion, canCheckForUpdates):
            Button {
                sparkleManager.installUpdate()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .imageScale(.small)
                    Text(labelText(displayVersion: displayVersion))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 76)
                .foregroundStyle(.white)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .disabled(!canCheckForUpdates)
            .hoverTooltip(helpText(displayVersion: displayVersion, canCheckForUpdates: canCheckForUpdates), .bottom)
            .accessibilityLabel(accessibilityLabel(displayVersion: displayVersion))
            .accessibilityHint(accessibilityHint(canCheckForUpdates: canCheckForUpdates))
        }
    }

    private func labelText(displayVersion: String?) -> String {
        guard let displayVersion else { return "Update" }
        return "Update \(displayVersion)"
    }

    private func helpText(displayVersion: String?, canCheckForUpdates: Bool) -> String {
        if !canCheckForUpdates {
            guard let displayVersion else {
                return "Update available, but Sparkle is not ready to check for updates yet"
            }
            return "Update available: \(displayVersion), but Sparkle is not ready to check for updates yet"
        }

        guard let displayVersion else {
            return "Update available — click for release notes"
        }
        return "Update available: \(displayVersion) — click for release notes"
    }

    private func accessibilityLabel(displayVersion: String?) -> String {
        guard let displayVersion else { return "Update available" }
        return "Update available, version \(displayVersion)"
    }

    private func accessibilityHint(canCheckForUpdates: Bool) -> String {
        if canCheckForUpdates {
            return "Opens Sparkle's release notes and install dialog."
        }
        return "Sparkle is not ready to check for updates yet."
    }
}
