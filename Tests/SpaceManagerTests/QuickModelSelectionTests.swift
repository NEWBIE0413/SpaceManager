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
            {"id":"claude-sonnet-5","display_name":"Claude Sonnet 5"},
            {"id":"claude-codex-gpt-5.6-terra","display_name":"Codex · GPT-5.6-Terra"},
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
}
