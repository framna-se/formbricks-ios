import XCTest
@testable import FormbricksSDK

/// Counts workspace fetches, so a test can tell "served from cache" apart from "refetched".
private final class CountingMockService: MockFormbricksService {
    private(set) var workspaceStateCallCount = 0

    override func getWorkspaceState(completion: @escaping (ResultType<GetWorkspaceRequest.Response>) -> Void) {
        workspaceStateCallCount += 1
        super.getWorkspaceState(completion: completion)
    }
}

/// The cached workspace payload and the contact state are keyed workspace-agnostically and outlive
/// the process, so an app that restarts pointing at a different workspace used to keep serving the
/// previous one's surveys until the caches expired. `Formbricks.setup` now drops both when the
/// workspace it is set up with is not the one the cache was fetched for.
final class WorkspaceSwitchTests: XCTestCase {
    private let appUrl = "https://example.com"
    private let workspaceA = "workspace-a"
    private let workspaceB = "workspace-b"

    override func setUp() {
        super.setUp()
        // A suite that left the SDK initialized would turn every `setup` here into a no-op.
        Formbricks.cleanup()
        clearPersistedState()
    }

    override func tearDown() {
        Formbricks.cleanup()
        clearPersistedState()
        super.tearDown()
    }

    // MARK: - Tests

    /// The bug: QA build, production payload. Setting up against another workspace must drop the
    /// cache and refetch rather than serve the previous workspace's surveys.
    func testSwitchingWorkspaceDropsCachedPayloadAndContactState() {
        let firstService = CountingMockService()
        Formbricks.setup(with: config(workspaceId: workspaceA, service: firstService))
        XCTAssertEqual(SurveyManager.cachedWorkspaceId(), workspaceA)

        // Stand in for the app restart that follows an environment switch: the process dies, so
        // nothing runs `logout()` and the state stays on disk. `cleanup()` does clear it, hence
        // planting the contact state after it rather than before.
        Formbricks.cleanup()
        persistContactState()

        let secondService = CountingMockService()
        Formbricks.setup(with: config(workspaceId: workspaceB, service: secondService))

        XCTAssertEqual(secondService.workspaceStateCallCount, 1, "The stale payload must not be reused")
        XCTAssertEqual(SurveyManager.cachedWorkspaceId(), workspaceB)
        XCTAssertNil(UserDefaults.standard.string(forKey: "userIdKey"))
        XCTAssertNil(UserDefaults.standard.string(forKey: "contactIdKey"))
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "segmentsKey"))
        XCTAssertEqual(UserDefaults.standard.double(forKey: "expiresAtKey"), 0)
    }

    /// The other half: staying on one workspace must stay free. The fixture's `expiresAt` is years
    /// out, so a second launch has to be served from the cache with no request at all.
    func testSameWorkspaceKeepsCachedPayloadAndContactState() {
        Formbricks.setup(with: config(workspaceId: workspaceA, service: CountingMockService()))

        Formbricks.cleanup()
        persistContactState()

        let service = CountingMockService()
        Formbricks.setup(with: config(workspaceId: workspaceA, service: service))

        XCTAssertEqual(service.workspaceStateCallCount, 0, "A live cache should spare the round-trip")
        XCTAssertEqual(SurveyManager.cachedWorkspaceId(), workspaceA)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "userIdKey"), "user-1")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "contactIdKey"), "contact-1")
    }

    /// A payload cached under the pre-rename key belongs to a workspace just as much as one under
    /// the current key, and has to go on a switch too — otherwise the getter's legacy-key migration
    /// would resurrect it right afterwards.
    func testSwitchingWorkspaceDropsLegacyCachedPayload() throws {
        UserDefaults.standard.set(try encodedFixture(), forKey: SurveyManager.legacyEnvironmentResponseObjectKey)

        let service = CountingMockService()
        Formbricks.setup(with: config(workspaceId: workspaceB, service: service))

        XCTAssertNil(UserDefaults.standard.data(forKey: SurveyManager.legacyEnvironmentResponseObjectKey))
        XCTAssertEqual(service.workspaceStateCallCount, 1)
        XCTAssertEqual(SurveyManager.cachedWorkspaceId(), workspaceB)
    }

    /// A cache written before this bookkeeping existed names no workspace, so it can't be trusted:
    /// it is dropped once. The refetch records the workspace, so the next launch is a cache hit
    /// again — the reset must not repeat on every launch.
    func testCacheWithoutARecordedWorkspaceIsDroppedExactlyOnce() throws {
        UserDefaults.standard.set(try encodedFixture(), forKey: SurveyManager.workspaceResponseObjectKey)
        XCTAssertNil(SurveyManager.cachedWorkspaceId())
        persistContactState()

        let firstService = CountingMockService()
        Formbricks.setup(with: config(workspaceId: workspaceA, service: firstService))

        XCTAssertEqual(firstService.workspaceStateCallCount, 1)
        XCTAssertEqual(SurveyManager.cachedWorkspaceId(), workspaceA)
        XCTAssertNil(UserDefaults.standard.string(forKey: "userIdKey"))

        Formbricks.cleanup()
        persistContactState()

        let secondService = CountingMockService()
        Formbricks.setup(with: config(workspaceId: workspaceA, service: secondService))

        XCTAssertEqual(secondService.workspaceStateCallCount, 0)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "userIdKey"), "user-1")
    }

    /// The invariant the reset rests on: the recorded workspace is written and cleared by the same
    /// code paths as the payload, so the two can never disagree about which workspace is cached.
    func testRecordedWorkspaceTracksTheCachedPayload() {
        Formbricks.setup(with: config(workspaceId: workspaceA, service: CountingMockService()))
        XCTAssertNotNil(UserDefaults.standard.data(forKey: SurveyManager.workspaceResponseObjectKey))
        XCTAssertEqual(SurveyManager.cachedWorkspaceId(), workspaceA)

        SurveyManager.clearPersistedWorkspaceCache()

        XCTAssertNil(UserDefaults.standard.data(forKey: SurveyManager.workspaceResponseObjectKey))
        XCTAssertNil(SurveyManager.cachedWorkspaceId())
    }

    // MARK: - Helpers

    private func config(workspaceId: String, service: FormbricksServiceProtocol) -> FormbricksConfig {
        return FormbricksConfig.Builder(appUrl: appUrl, workspaceId: workspaceId)
            .service(service)
            .build()
    }

    /// Contact state as a previous session would have left it on disk.
    private func persistContactState() {
        let defaults = UserDefaults.standard
        defaults.set("user-1", forKey: "userIdKey")
        defaults.set("contact-1", forKey: "contactIdKey")
        defaults.set(["segment-1"], forKey: "segmentsKey")
        defaults.set(Date().addingTimeInterval(3600).timeIntervalSince1970, forKey: "expiresAtKey")
    }

    /// The fixture encoded the way the persisted-cache path writes it (plain `JSONEncoder`), i.e.
    /// the shape a cache written by an earlier SDK version has.
    private func encodedFixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Environment", withExtension: "json"))
        let response = try JSONDecoder.iso8601Full.decode(WorkspaceResponse.self, from: Data(contentsOf: url))
        return try JSONEncoder().encode(response)
    }

    private func clearPersistedState() {
        SurveyManager.clearPersistedWorkspaceCache()
        UserManager.clearPersistedState()
    }
}
