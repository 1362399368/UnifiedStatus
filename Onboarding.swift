import AppKit
import ServiceManagement

let onboardingDefaultsKey = "UnifiedStatusHasCompletedOnboarding"

private let launchAgentLabel = "com.local.unified-status"

// MARK: - LaunchAgent Fallback
enum LaunchAgent {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func enable() throws {
        guard let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func disable() throws {
        if isEnabled {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - LaunchAtLoginManager
final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    /// Older releases used a LaunchAgent. Once the public login-item API is
    /// active, remove the legacy file so the next login cannot start two copies.
    func reconcileRegistrations() {
        guard #available(macOS 13.0, *) else { return }
        let status = SMAppService.mainApp.status
        guard status == .enabled || status == .requiresApproval else { return }
        if LaunchAgent.isEnabled {
            do {
                try LaunchAgent.disable()
            } catch {
                NSLog("Could not remove legacy LaunchAgent: \(error)")
            }
        }
    }

    var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval {
                return true
            }
        }
        return LaunchAgent.isEnabled
    }

    func setEnabled(_ enable: Bool) throws {
        if enable {
            if #available(macOS 13.0, *) {
                do {
                    let status = SMAppService.mainApp.status
                    if status != .enabled && status != .requiresApproval {
                        try SMAppService.mainApp.register()
                    }
                    // Remove an older LaunchAgent only after the public login
                    // item API has succeeded, otherwise two copies may launch.
                    if LaunchAgent.isEnabled {
                        try LaunchAgent.disable()
                    }
                    return
                } catch {
                    NSLog("SMAppService failed: \(error), falling back to LaunchAgent")
                }
            }
            try LaunchAgent.enable()
        } else {
            var firstError: Error?
            if #available(macOS 13.0, *) {
                let status = SMAppService.mainApp.status
                if status == .enabled || status == .requiresApproval {
                    do {
                        try SMAppService.mainApp.unregister()
                    } catch {
                        firstError = error
                    }
                }
            }
            if LaunchAgent.isEnabled {
                do {
                    try LaunchAgent.disable()
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
        }
    }
}

// MARK: - SystemIconInspector
final class SystemIconInspector {
    static var usesMenuBarSettings: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    static var settingsDisplayName: String {
        usesMenuBarSettings ? "菜单栏设置" : "控制中心设置"
    }

    static var wifiInstruction: String {
        usesMenuBarSettings
            ? "菜单栏设置 › 关闭 Wi‑Fi"
            : "控制中心 › Wi‑Fi › 设为不在菜单栏显示"
    }

    static var batteryInstruction: String {
        usesMenuBarSettings
            ? "菜单栏设置 › 关闭电池"
            : "控制中心 › 电池 › 设为不在菜单栏显示"
    }

    static var inputInstruction: String {
        "键盘 › 文字输入 › 编辑 › 关闭输入法菜单"
    }

    static func syncPreferences() {
        CFPreferencesSynchronize("com.apple.controlcenter" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize("com.apple.controlcenter" as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize("com.apple.TextInputMenu" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    /// 检测状态栏上是否有对应的窗口（Window Layer 25 为状态栏项目）
    static func isStatusItemOnScreen(ownerKeywords: [String], windowName: String?) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for item in list {
            let layer = item[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 25 else { continue }
            let owner = (item[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            let name = item[kCGWindowName as String] as? String ?? ""

            let matchOwner = ownerKeywords.contains { owner.contains($0.lowercased()) }
            if matchOwner {
                if let windowName {
                    if name.lowercased() == windowName.lowercased() {
                        return true
                    }
                } else {
                    return true
                }
            }
        }
        return false
    }

    static var isWiFiHidden: Bool {
        // 1. 优先通过屏幕实际渲染状态判断（最精准）
        if isStatusItemOnScreen(ownerKeywords: ["controlcenter", "控制中心"], windowName: "WiFi") {
            return false
        }

        // 2. 备用通过系统设置偏好判断
        syncPreferences()
        return preferenceBool(key: "NSStatusItem Visible WiFi", appID: "com.apple.controlcenter") == false
    }

    static var isBatteryHidden: Bool {
        // 1. 优先通过屏幕实际渲染状态判断（最精准）
        if isStatusItemOnScreen(ownerKeywords: ["controlcenter", "控制中心"], windowName: "Battery") {
            return false
        }

        // 2. 备用通过系统设置偏好判断
        syncPreferences()
        return preferenceBool(key: "NSStatusItem Visible Battery", appID: "com.apple.controlcenter") == false
    }

    static var isInputMenuHidden: Bool {
        // 1. 优先通过屏幕实际渲染状态判断（最精准）
        if isStatusItemOnScreen(ownerKeywords: ["textinput", "输入法"], windowName: nil) {
            return false
        }

        // 2. 备用通过系统设置偏好判断
        syncPreferences()
        return preferenceBool(key: "visible", appID: "com.apple.TextInputMenu") == false
    }

    static func openControlCenterSettings() {
        let paneIDs = usesMenuBarSettings
            ? ["com.apple.MenuBar-Settings.extension", "com.apple.ControlCenter-Settings.extension"]
            : ["com.apple.ControlCenter-Settings.extension"]
        if openSettingsPane(paneIDs) {
            return
        }
        openSystemSettings()
    }

    static func openKeyboardSettings() {
        if openSettingsPane(["com.apple.Keyboard-Settings.extension"]) {
            return
        }
        openSystemSettings()
    }

    private static func preferenceBool(key: String, appID: String) -> Bool? {
        guard let value = CFPreferencesCopyValue(
            key as CFString,
            appID as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func openSettingsPane(_ paneIDs: [String]) -> Bool {
        for paneID in paneIDs {
            guard let url = URL(string: "x-apple.systempreferences:\(paneID)") else { continue }
            if NSWorkspace.shared.open(url) { return true }
        }
        return false
    }

    private static func openSystemSettings() {
        let url = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Custom Card Box View
private final class CardBoxView: NSView {
    var cornerRadius: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.controlBackgroundColor.withAlphaComponent(0.65).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Row View for Each System Item
private final class SystemItemRowView: NSView {
    private let iconImageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let statusContainer = NSStackView()
    private let checkmarkImageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "已隐藏")

    var onAction: (() -> Void)?

    init(symbolName: String, title: String, subtitle: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Icon
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            iconImageView.image = img.withSymbolConfiguration(config)
            iconImageView.contentTintColor = .labelColor
        }

        // Titles
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.stringValue = subtitle
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, subtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        // Button
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.title = "去隐藏 ↗"
        actionButton.bezelStyle = .rounded
        actionButton.font = .systemFont(ofSize: 11.5, weight: .regular)
        actionButton.toolTip = "打开对应的系统设置"
        actionButton.target = self
        actionButton.action = #selector(buttonClicked)

        // Status container (Checkmark)
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.orientation = .horizontal
        statusContainer.alignment = .centerY
        statusContainer.spacing = 4

        if let checkImg = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            checkmarkImageView.image = checkImg.withSymbolConfiguration(config)
            checkmarkImageView.contentTintColor = .systemGreen
        }
        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = .systemGreen
        statusContainer.addArrangedSubview(checkmarkImageView)
        statusContainer.addArrangedSubview(statusLabel)

        addSubview(iconImageView)
        addSubview(textStack)
        addSubview(actionButton)
        addSubview(statusContainer)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),

            iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),

            textStack.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            statusContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusContainer.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func buttonClicked() {
        onAction?()
    }

    func setHiddenState(_ isHidden: Bool) {
        actionButton.isHidden = isHidden
        statusContainer.isHidden = !isHidden
    }
}

// MARK: - Onboarding View Controller
final class OnboardingViewController: NSViewController {
    private let launchSwitch = NSSwitch()
    private let card2Desc = NSTextField(labelWithString: "每项隐藏后会自动打勾，无需回来手动确认。")
    private let finishButton = NSButton()
    private var wifiRow: SystemItemRowView!
    private var batteryRow: SystemItemRowView!
    private var inputRow: SystemItemRowView!
    private var refreshTimer: Timer?
    private var allSystemIconsHidden = false

    var onCompletion: (() -> Void)?

    override func loadView() {
        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 500, height: 610))
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        view = visualEffect
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        refreshAllStatuses()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshAllStatuses()
        startTimer()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopTimer()
        NotificationCenter.default.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private func startTimer() {
        stopTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.refreshIconStatuses()
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func applicationDidBecomeActive() {
        refreshAllStatuses()
    }

    private func setupUI() {
        // App Icon
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let appIcon = NSImage(named: NSImage.applicationIconName) {
            iconView.image = appIcon
        } else if let fallback = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil) {
            iconView.image = fallback
        }

        // Header Title
        let titleLabel = NSTextField(labelWithString: "三合一状态栏")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.alignment = .center

        // Subtitle
        let subtitleLabel = NSTextField(labelWithString: "将电量、Wi‑Fi 与输入法整合为一个图标，释放菜单栏空间")
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center

        // Card 1: Launch at login
        let card1 = CardBoxView()
        card1.translatesAutoresizingMaskIntoConstraints = false

        let step1Badge = makeStepBadge(text: "步骤 1")
        let card1Title = NSTextField(labelWithString: "开机自动启动")
        card1Title.font = .systemFont(ofSize: 14, weight: .semibold)

        let card1Desc = NSTextField(labelWithString: "常驻后台运行，登录 macOS 后自动代替系统状态栏图标。")
        card1Desc.font = .systemFont(ofSize: 11.5, weight: .regular)
        card1Desc.textColor = .secondaryLabelColor

        let card1TextStack = NSStackView(views: [card1Title, card1Desc])
        card1TextStack.orientation = .vertical
        card1TextStack.alignment = .leading
        card1TextStack.spacing = 2

        launchSwitch.translatesAutoresizingMaskIntoConstraints = false
        launchSwitch.target = self
        launchSwitch.action = #selector(launchSwitchChanged(_:))

        card1.addSubview(step1Badge)
        card1.addSubview(card1TextStack)
        card1.addSubview(launchSwitch)

        NSLayoutConstraint.activate([
            step1Badge.leadingAnchor.constraint(equalTo: card1.leadingAnchor, constant: 14),
            step1Badge.topAnchor.constraint(equalTo: card1.topAnchor, constant: 14),

            card1TextStack.leadingAnchor.constraint(equalTo: card1.leadingAnchor, constant: 14),
            card1TextStack.topAnchor.constraint(equalTo: step1Badge.bottomAnchor, constant: 8),
            card1TextStack.trailingAnchor.constraint(equalTo: launchSwitch.leadingAnchor, constant: -12),
            card1TextStack.bottomAnchor.constraint(equalTo: card1.bottomAnchor, constant: -14),

            launchSwitch.trailingAnchor.constraint(equalTo: card1.trailingAnchor, constant: -14),
            launchSwitch.centerYAnchor.constraint(equalTo: card1TextStack.centerYAnchor)
        ])

        // Card 2: Hide System Icons
        let card2 = CardBoxView()
        card2.translatesAutoresizingMaskIntoConstraints = false

        let step2Badge = makeStepBadge(text: "步骤 2")
        let card2Title = NSTextField(labelWithString: "清理系统原生状态栏图标")
        card2Title.font = .systemFont(ofSize: 14, weight: .semibold)

        card2Desc.font = .systemFont(ofSize: 11.5, weight: .regular)
        card2Desc.textColor = .secondaryLabelColor

        let card2HeaderStack = NSStackView(views: [card2Title, card2Desc])
        card2HeaderStack.orientation = .vertical
        card2HeaderStack.alignment = .leading
        card2HeaderStack.spacing = 2

        wifiRow = SystemItemRowView(symbolName: "wifi", title: "Wi‑Fi 图标", subtitle: SystemIconInspector.wifiInstruction)
        wifiRow.onAction = { SystemIconInspector.openControlCenterSettings() }

        batteryRow = SystemItemRowView(symbolName: "battery.100", title: "电池与电量图标", subtitle: SystemIconInspector.batteryInstruction)
        batteryRow.onAction = { SystemIconInspector.openControlCenterSettings() }

        inputRow = SystemItemRowView(symbolName: "character.cursor.ibeam", title: "输入法菜单图标", subtitle: SystemIconInspector.inputInstruction)
        inputRow.onAction = { SystemIconInspector.openKeyboardSettings() }

        let div1 = makeDivider()
        let div2 = makeDivider()
        let div3 = makeDivider()

        let rowsStack = NSStackView(views: [wifiRow, div2, batteryRow, div3, inputRow])
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.spacing = 0
        rowsStack.distribution = .fill

        card2.addSubview(step2Badge)
        card2.addSubview(card2HeaderStack)
        card2.addSubview(div1)
        card2.addSubview(rowsStack)

        NSLayoutConstraint.activate([
            step2Badge.leadingAnchor.constraint(equalTo: card2.leadingAnchor, constant: 14),
            step2Badge.topAnchor.constraint(equalTo: card2.topAnchor, constant: 14),

            card2HeaderStack.leadingAnchor.constraint(equalTo: card2.leadingAnchor, constant: 14),
            card2HeaderStack.topAnchor.constraint(equalTo: step2Badge.bottomAnchor, constant: 8),
            card2HeaderStack.trailingAnchor.constraint(equalTo: card2.trailingAnchor, constant: -14),

            div1.leadingAnchor.constraint(equalTo: card2.leadingAnchor, constant: 14),
            div1.trailingAnchor.constraint(equalTo: card2.trailingAnchor, constant: -14),
            div1.topAnchor.constraint(equalTo: card2HeaderStack.bottomAnchor, constant: 10),

            rowsStack.leadingAnchor.constraint(equalTo: card2.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: card2.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: div1.bottomAnchor, constant: 4),
            rowsStack.bottomAnchor.constraint(equalTo: card2.bottomAnchor, constant: -8)
        ])

        // Bottom Action Buttons
        let laterButton = NSButton()
        laterButton.translatesAutoresizingMaskIntoConstraints = false
        laterButton.title = "稍后再提醒"
        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(laterButtonClicked)

        finishButton.translatesAutoresizingMaskIntoConstraints = false
        finishButton.title = "完成并开始使用"
        finishButton.bezelStyle = .rounded
        finishButton.keyEquivalent = "\r"
        finishButton.target = self
        finishButton.action = #selector(finishButtonClicked)

        view.addSubview(iconView)
        view.addSubview(titleLabel)
        view.addSubview(subtitleLabel)
        view.addSubview(card1)
        view.addSubview(card2)
        view.addSubview(laterButton)
        view.addSubview(finishButton)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),

            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            card1.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            card1.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            card1.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            card2.topAnchor.constraint(equalTo: card1.bottomAnchor, constant: 14),
            card2.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            card2.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            laterButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            laterButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            laterButton.widthAnchor.constraint(equalToConstant: 100),
            laterButton.heightAnchor.constraint(equalToConstant: 32),

            finishButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            finishButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            finishButton.widthAnchor.constraint(equalToConstant: 140),
            finishButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func makeStepBadge(text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 5
        container.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10.5, weight: .bold)
        label.textColor = .controlAccentColor

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
        ])
        return container
    }

    private func makeDivider() -> NSView {
        let div = NSView()
        div.translatesAutoresizingMaskIntoConstraints = false
        div.wantsLayer = true
        div.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        div.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return div
    }

    func refreshAllStatuses() {
        launchSwitch.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        refreshIconStatuses()
    }

    func refreshIconStatuses() {
        let wifiHidden = SystemIconInspector.isWiFiHidden
        let batteryHidden = SystemIconInspector.isBatteryHidden
        let inputHidden = SystemIconInspector.isInputMenuHidden

        wifiRow.setHiddenState(wifiHidden)
        batteryRow.setHiddenState(batteryHidden)
        inputRow.setHiddenState(inputHidden)

        allSystemIconsHidden = wifiHidden && batteryHidden && inputHidden
        if allSystemIconsHidden {
            card2Desc.stringValue = "✨ 原生图标已全部隐藏，状态栏已处于最佳整洁状态！"
            card2Desc.textColor = .systemGreen
        } else {
            let remaining = [wifiHidden, batteryHidden, inputHidden].filter { !$0 }.count
            card2Desc.stringValue = "还有 \(remaining) 项待隐藏；完成后这里会自动打勾。"
            card2Desc.textColor = .secondaryLabelColor
        }
    }

    @objc private func launchSwitchChanged(_ sender: NSSwitch) {
        do {
            try LaunchAtLoginManager.shared.setEnabled(sender.state == .on)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            sender.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        }
    }

    @objc private func laterButtonClicked() {
        onCompletion?()
    }

    @objc private func finishButtonClicked() {
        refreshIconStatuses()
        if !allSystemIconsHidden {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "还有系统图标没有隐藏"
            alert.informativeText = "建议先点每一项右侧的“去隐藏”，这样菜单栏不会出现重复图标。你也可以暂时跳过，之后右键三合一图标重新打开引导。"
            alert.addButton(withTitle: "继续设置")
            alert.addButton(withTitle: "仍然完成")
            if alert.runModal() == .alertFirstButtonReturn {
                return
            }
        }
        UserDefaults.standard.set(true, forKey: onboardingDefaultsKey)
        onCompletion?()
    }
}

// MARK: - Onboarding Window Controller
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()

    private let onboardingViewController = OnboardingViewController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        window.contentViewController = onboardingViewController
        onboardingViewController.onCompletion = { [weak self] in
            self?.close()
        }
    }

    func show() {
        guard let window = window else { return }
        onboardingViewController.refreshAllStatuses()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
