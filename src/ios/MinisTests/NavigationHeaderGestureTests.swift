import XCTest
import UIKit
@testable import Minis

final class NavigationHeaderGestureTests: XCTestCase {
    @MainActor
    func testInteractivePopBridgeAllowsPopOnlyWhenNavigationStackHasPreviousPage() {
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        let bridge = MinisInteractivePopBridge.Controller()

        navigationController.pushViewController(bridge, animated: false)
        bridge.loadViewIfNeeded()
        bridge.enableInteractivePopWhenPossible()

        guard let gesture = navigationController.interactivePopGestureRecognizer else {
            return XCTFail("UINavigationController did not install its pop gesture")
        }
        XCTAssertTrue(gesture.isEnabled)
        XCTAssertTrue(gesture.delegate === bridge)
        XCTAssertTrue(bridge.gestureRecognizerShouldBegin(gesture))

        navigationController.setViewControllers([root], animated: false)
        XCTAssertFalse(bridge.gestureRecognizerShouldBegin(gesture))
    }
}
