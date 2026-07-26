import XCTest
@testable import SpaceManager

final class QuickComposerPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "QuickComposerPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRoundTripsLastComposerSelection() {
        let configuration = QuickSessionConfiguration(
            modelID: "claude-codex-gpt-5.6-sol[1m]",
            effort: .ultra,
            proxyEnabled: true
        )

        QuickComposerPreferences.save(configuration, to: defaults)

        XCTAssertEqual(QuickComposerPreferences.load(from: defaults), configuration)
    }

    @MainActor
    func testUnavailableStoredModelFallsBackToDefault() {
        let stored = QuickSessionConfiguration(
            modelID: "claude-codex-removed[1m]",
            effort: .ultra,
            proxyEnabled: true
        )
        let availableModels = QuickModelCatalog.fallbackModels

        XCTAssertEqual(
            QuickComposerPreferences.resolved(
                stored,
                availableModels: availableModels
            ),
            .default
        )
    }

    func testUnsupportedStoredEffortUsesAvailableHigh() {
        let stored = QuickSessionConfiguration(
            modelID: "claude-codex-gpt-test[1m]",
            effort: .ultra,
            proxyEnabled: false
        )
        let available = [
            QuickModelOption(
                id: stored.modelID,
                displayName: "Codex Test",
                supportedEfforts: [.low, .high]
            ),
        ]

        XCTAssertEqual(
            QuickComposerPreferences.resolved(stored, availableModels: available),
            QuickSessionConfiguration(
                modelID: stored.modelID,
                effort: .high,
                proxyEnabled: false
            )
        )
    }
}
