import XCTest
@testable import SpaceManager

final class WorkspaceWindowRegistryTests: XCTestCase {
    func testSameProjectOnAnotherHostCannotStealActivityJump() throws {
        let local = Workspace(rootPath: "/tmp/project")
        let remote = Workspace(rootPath: "/tmp/project", remoteHost: "arch")
        let candidates = [(owner: "current", workspace: local), (owner: "other", workspace: remote)]
        XCTAssertEqual(WorkspaceWindowRegistry.bestRoute(containing: "/tmp/project", host: "arch", candidates: candidates, preferredOwner: "current")?.workspace.id, remote.id)
        XCTAssertEqual(WorkspaceWindowRegistry.bestRoute(containing: "/tmp/project", candidates: candidates, preferredOwner: "other")?.workspace.id, local.id)
        XCTAssertNil(WorkspaceWindowRegistry.bestRoute(containing: "/tmp/project", host: "nuc", candidates: candidates, preferredOwner: "current"))
    }

    func testDeepestContainingWorkspaceWins() throws {
        let root = Workspace(rootPath: "/tmp/project")
        let nested = Workspace(rootPath: "/tmp/project/packages/client")
        let match = WorkspaceWindowRegistry.deepestWorkspace(
            containing: "/tmp/project/packages/client/Sources",
            in: [root, nested]
        )
        XCTAssertEqual(match?.id, nested.id)
    }

    func testWorkspaceMatchRespectsPathBoundary() {
        let workspace = Workspace(rootPath: "/tmp/flat")
        XCTAssertNil(WorkspaceWindowRegistry.deepestWorkspace(
            containing: "/tmp/flat-web",
            in: [workspace]
        ))
    }

    func testWorkspaceRootItselfMatches() {
        let workspace = Workspace(rootPath: "/tmp/project")
        XCTAssertEqual(
            WorkspaceWindowRegistry.deepestWorkspace(containing: "/tmp/project", in: [workspace])?.id,
            workspace.id
        )
    }

    func testDeeperWorkspaceInAnotherWindowBeatsCurrentWindow() throws {
        let broad = Workspace(rootPath: "/tmp/projects")
        let exact = Workspace(rootPath: "/tmp/projects/client")
        let route = try XCTUnwrap(WorkspaceWindowRegistry.bestRoute(
            containing: "/tmp/projects/client/Sources",
            candidates: [(owner: "current", workspace: broad), (owner: "other", workspace: exact)],
            preferredOwner: "current"
        ))
        XCTAssertEqual(route.owner, "other")
        XCTAssertEqual(route.workspace.id, exact.id)
    }

    func testCurrentWindowOnlyWinsEqualDepthTie() throws {
        let current = Workspace(rootPath: "/tmp/project")
        let other = Workspace(rootPath: "/tmp/project")
        let route = try XCTUnwrap(WorkspaceWindowRegistry.bestRoute(
            containing: "/tmp/project/Sources",
            candidates: [(owner: "other", workspace: other), (owner: "current", workspace: current)],
            preferredOwner: "current"
        ))
        XCTAssertEqual(route.owner, "current")
    }
}
