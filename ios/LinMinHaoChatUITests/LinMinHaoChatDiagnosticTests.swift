import XCTest

/// 诊断测试:点击一键登录后,dump 页面全部文本,
/// 定位 SDK 返回的具体错误码/错误文案
final class LinMinHaoChatDiagnosticTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDumpOneTapLoginResult() throws {
        let app = XCUIApplication()
        app.launch()

        // 进登录页
        let loginBtn = app.buttons["登录 / 注册"]
        XCTAssertTrue(loginBtn.waitForExistence(timeout: 8), "登录按钮不存在")
        loginBtn.tap()

        // 切手机号 tab
        let phoneTab = app.buttons["手机号"]
        XCTAssertTrue(phoneTab.waitForExistence(timeout: 5), "手机号 tab 不存在")
        phoneTab.tap()

        // 一键登录按钮
        let oneTap = app.buttons["本机号码一键登录"]
        XCTAssertTrue(oneTap.waitForExistence(timeout: 5), "一键登录按钮不存在")
        oneTap.tap()

        // 等 3 秒后 dump 页面所有文本
        sleep(3)
        print("========== 点击后 3 秒页面状态 ==========")
        print("App state: \(app.state.rawValue)")

        let allTexts = app.staticTexts.allElementsBoundByIndex.map { "TEXT: \($0.label)" }
        allTexts.forEach { print($0) }

        let allButtons = app.buttons.allElementsBoundByIndex.map { "BTN: \($0.label)" }
        allButtons.forEach { print($0) }

        let alerts = app.alerts.allElementsBoundByIndex
        alerts.forEach { print("ALERT: \($0.label)") }

        // 等 15 秒(超时保护触发)再 dump 一次
        sleep(14)
        print("========== 点击后 17 秒页面状态 ==========")
        let texts2 = app.staticTexts.allElementsBoundByIndex.map { "TEXT: \($0.label)" }
        texts2.forEach { print($0) }
        let alerts2 = app.alerts.allElementsBoundByIndex
        alerts2.forEach { print("ALERT: \($0.label)") }

        // 关键断言:App 不崩溃
        XCTAssertTrue(app.state == .runningForeground, "App 崩溃或退出! state=\(app.state.rawValue)")
    }
}
