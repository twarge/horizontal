import XCTest
@testable import HorizontalNative

/// After an edit SwiftUI can render once more with the state from before it.
/// The scene cache keeps the scene it replaced, so that pass and the one after
/// it are both served without a rebuild.
final class HorizontalCanvasSelectableSceneCacheTests: XCTestCase {
    func testAPassWithTheOldKeyIsServedThePreviousScene() {
        let cache = HorizontalCanvasSelectableSceneCache<Int>()
        var builds = 0
        func scene(_ key: Int) {
            _ = cache.scene(key: key) {
                builds += 1
                return []
            }
        }

        scene(1)
        cache.invalidate()
        scene(2)
        scene(1)
        scene(2)
        XCTAssertEqual(builds, 2, "the old key and the new one are each built once")

        scene(3)
        scene(1)
        XCTAssertEqual(builds, 4, "only the most recent previous scene is kept")
    }

    func testSnapTargetsComeBackWithTheirScene() {
        let cache = HorizontalCanvasSelectableSceneCache<Int>()
        var snapBuilds = 0
        func snapTargets(_ key: Int) -> [HorizontalPoint] {
            _ = cache.scene(key: key) { [] }
            return cache.snapTargets(key: key) {
                snapBuilds += 1
                return [HorizontalPoint(x: Double(key), y: 0)]
            }
        }

        XCTAssertEqual(snapTargets(1), [HorizontalPoint(x: 1, y: 0)])
        XCTAssertEqual(snapTargets(2), [HorizontalPoint(x: 2, y: 0)])
        XCTAssertEqual(snapTargets(1), [HorizontalPoint(x: 1, y: 0)])
        XCTAssertEqual(snapBuilds, 2)
    }
}
