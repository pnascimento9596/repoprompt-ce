import AppKit
@testable import RepoPromptApp
import SwiftUI
import XCTest

@MainActor
final class AgentExecutionLocationPickerLayoutTests: XCTestCase {
    private enum State: CaseIterable {
        case loading
        case populated
        case empty
        case error
    }

    func testPickerRegionKeepsStableOuterSizeAcrossLoadingPopulatedEmptyAndError() {
        let expectedSize = CGSize(width: 284, height: 288)

        for state in State.allCases {
            let measuredSize = measuredSize(for: state)
            XCTAssertEqual(measuredSize.width, expectedSize.width, accuracy: 0.5, "\(state) width changed")
            XCTAssertEqual(measuredSize.height, expectedSize.height, accuracy: 0.5, "\(state) height changed")
        }
    }

    private func measuredSize(for state: State) -> CGSize {
        let hostingView = NSHostingView(
            rootView: AgentExecutionLocationPickerRegion(
                width: 284,
                height: 288
            ) {
                stateContent(for: state)
            }
        )
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }

    @ViewBuilder
    private func stateContent(for state: State) -> some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        case .populated:
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(0 ..< 8, id: \.self) { index in
                        Text("Existing worktree \(index)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
            }
        case .empty:
            Text("No other worktrees available")
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        case .error:
            Text("Unable to load existing worktrees because the repository is temporarily unavailable.")
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }
}
