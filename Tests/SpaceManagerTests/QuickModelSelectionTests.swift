import XCTest
@testable import SpaceManager

final class QuickModelSelectionTests: XCTestCase {
    @MainActor
    func testCatalogStartsWithClaudeFallbackAndCodexDisabled() {
        let catalog = QuickModelCatalog(
            endpoint: URL(string: "http://127.0.0.1:1/v1/models")!
        )

        XCTAssertFalse(catalog.routerAvailable)
        XCTAssertEqual(
            catalog.models.map(\.id),
            ["claude-opus-4-8", "claude-sonnet-5", "claude-fable-5", "claude-haiku-4-5"]
        )
        XCTAssertFalse(catalog.models.contains(where: \.isCodex))
    }

    func testGatewayResponseDecodesClaudeAndCodexModelsOnlyOnce() throws {
        let data = Data(#"""
        {
          "data": [
            {"id":"claude-sonnet-5","display_name":"Claude Sonnet 5","supported_efforts":["low","high","max"]},
            {"id":"claude-codex-gpt-5.6-terra","display_name":"Codex · GPT-5.6-Terra","supported_efforts":["low","ultra"]},
            {"id":"claude-sonnet-5","display_name":"Duplicate"},
            {"id":"other-model","display_name":"Ignored"}
          ]
        }
        """#.utf8)

        let models = try QuickModelCatalog.decodeModels(data)

        XCTAssertEqual(models.map(\.id), [
            "claude-sonnet-5",
            "claude-codex-gpt-5.6-terra",
        ])
        XCTAssertFalse(models[0].isCodex)
        XCTAssertTrue(models[1].isCodex)
        XCTAssertEqual(models[0].supportedEfforts, [.low, .high, .max])
        XCTAssertEqual(models[1].supportedEfforts, [.low, .ultra])
    }

    func testCodexSelectionAlwaysUsesProxyWhileClaudeCanStayDirect() {
        XCTAssertFalse(QuickSessionConfiguration.default.usesProxy)
        XCTAssertTrue(
            QuickSessionConfiguration(
                modelID: "claude-sonnet-5",
                effort: .medium,
                proxyEnabled: true
            ).usesProxy
        )
        XCTAssertTrue(
            QuickSessionConfiguration(
                modelID: "claude-codex-gpt-5.4-mini",
                effort: .low,
                proxyEnabled: false
            ).usesProxy
        )
    }

    func testClaudeCLIStringTableRejectsLegacyNoiseAndFindsOpus5() {
        let models = ClaudeCLIModelDiscovery.parseStringTable("""
        claude-opus-4-7
        unrelated text
        claude-fable-5
        Claude Fable 5
        claude-opus-5
        Claude Opus 5
        claude-sonnet-5
        Claude Sonnet 5
        claude-opus-5
        Claude Opus 5
        """)

        XCTAssertEqual(models.map(\.id), [
            "claude-fable-5",
            "claude-opus-5",
            "claude-sonnet-5",
        ])
        XCTAssertEqual(models[1].displayName, "Claude Opus 5")
        XCTAssertEqual(models[1].supportedEfforts, [.low, .medium, .high, .xhigh, .max])
    }

    func testCLIModelDiscoveryReadsExecutableStringsAndInvalidatesAfterUpgrade() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "claude-opus-5\nClaude Opus 5\n".write(to: file, atomically: true, encoding: .utf8)
        let first = ClaudeCLIModelDiscovery.discover(executablePath: file.path)
        XCTAssertEqual(first.map(\.id), ["claude-opus-5"])
        XCTAssertEqual(ClaudeCLIModelDiscovery.discover(executablePath: file.path), first)
        try "claude-sonnet-5\nClaude Sonnet 5\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeCLIModelDiscovery.discover(executablePath: file.path).map(\.id), ["claude-sonnet-5"])
    }

    func testEmptyAndOversizedStringTableRecordsAreSafe() {
        XCTAssertTrue(ClaudeCLIModelDiscovery.parseStringTable("").isEmpty)
        let large = String(repeating: "x", count: 100_000)
        XCTAssertEqual(ClaudeCLIModelDiscovery.parseStringTable(large + "\nclaude-opus-5\nClaude Opus 5").map(\.id), ["claude-opus-5"])
    }
}
