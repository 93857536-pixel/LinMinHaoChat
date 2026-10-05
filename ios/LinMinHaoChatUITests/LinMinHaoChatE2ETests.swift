import XCTest

/// 临时聊天端到端测试:发起房间 → 进入聊天 → 发送消息 → 消息上屏
/// 覆盖用户「软件用不了」的核心功能链路(创建房间依赖线上服务器 chat.linminhao.top)
final class LinMinHaoChatE2ETests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 完整链路:主页 → 临时聊天 → 发起临时聊天 → 聊天页出现 → 发送消息 → 消息显示
    func testTempChatFullFlow() throws {
        let app = XCUIApplication()
        app.launch()

        // 1. 主页 → 临时聊天
        let tempBtn = app.buttons["临时聊天"]
        XCTAssertTrue(tempBtn.waitForExistence(timeout: 8), "主页临时聊天按钮不存在")
        tempBtn.tap()

        // 2. 发起临时聊天(创建房间,依赖服务器)
        let createBtn = app.buttons["发起临时聊天"]
        XCTAssertTrue(createBtn.waitForExistence(timeout: 8), "发起临时聊天按钮不存在")
        createBtn.tap()

        // 3. 等待进入聊天页(房间创建 + 加入,最多 20 秒)
        //    聊天页标志:输入框 placeholder「加密消息」出现
        let inputField = app.textFields["加密消息"].exists ? app.textFields["加密消息"] : app.textViews["加密消息"]
        let inputExists = NSPredicate { obj, _ in
            guard let a = obj as? XCUIApplication else { return false }
            return a.textFields["加密消息"].exists || a.textViews["加密消息"].exists
        }
        let exp = expectation(for: inputExists, evaluatedWith: app)
        let waitResult = XCTWaiter.wait(for: [exp], timeout: 25)

        if waitResult != .completed {
            // dump 当前状态辅助排障
            print("⚠️ 25秒内未进入聊天页,当前文本:")
            app.staticTexts.allElementsBoundByIndex.prefix(15).forEach { print("TEXT: \($0.label)") }
            app.buttons.allElementsBoundByIndex.prefix(15).forEach { print("BTN: \($0.label)") }
            XCTFail("未能进入聊天页(房间创建或加入失败)")
            return
        }

        // 4. 创建者进入后 0.6s 自动弹出分享 sheet(半高,遮挡输入栏)→ 先关掉
        sleep(2)  // 等 sheet 弹出
        let copyBtn = app.buttons["复制链接"].firstMatch
        if copyBtn.waitForExistence(timeout: 3) {
            copyBtn.tap()  // 复制并 dismiss sheet
            print("✓ 已关闭分享 sheet")
        }
        sleep(1)

        // 5. 输入并发送一条消息
        let sendText = "模拟器测试消息 \(Int(Date().timeIntervalSince1970) % 100000)"
        if app.textFields["加密消息"].exists {
            let tf = app.textFields["加密消息"]
            tf.tap()
            sleep(1)
            tf.typeText(sendText)
        } else {
            let tv = app.textViews["加密消息"]
            tv.tap()
            sleep(1)
            tv.typeText(sendText)
        }

        // 输入栏发送按钮:paperplane SF Symbol,AX label 是 "Send"(英文)。
        // 页面分享卡片的 ShareLink label 才是中文「发送」——必须点输入栏按钮!
        let sendBtn = app.buttons["paperplane.fill"].firstMatch
        if !sendBtn.exists {
            sendBtn.tap()  // 触发加载
        }
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 5), "输入栏发送按钮不存在")
        print("⚠️ 输入栏发送按钮(paperplane)已找到")
        sendBtn.tap()
        print("✓ 已点击输入栏发送按钮")

        // 6. 消息上屏(发送方本地直接渲染明文)——不 dump 全文,避免 UI 刷新竞态
        let msgShown = app.staticTexts[sendText].waitForExistence(timeout: 10)
        XCTAssertTrue(msgShown, "消息未上屏:\(sendText)")
        print("✓ 消息已上屏:\(sendText)")

        // 6. 截图留证
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "temp-chat-after-send"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
