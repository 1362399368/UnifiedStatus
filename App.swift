import AppKit
import Carbon
import CoreWLAN
import CoreGraphics
import IOKit
import IOKit.ps
import SystemConfiguration

private let appBundleIdentifier = "com.local.unified-status"

struct SystemSnapshot: Equatable {
    var batteryPercent = 100
    var isCharging = false
    var isPluggedIn = false
    var isFullyCharged = false
    var timeRemaining = "正在计算"
    var externalPowerWatts: Double?

    var wifiBars = 0
    var wifiName = "未连接"
    var wifiDetail = "Wi‑Fi 已断开"
    var vpnActive = false

    var inputGlyph = "A"
    var inputName = "ABC"
    var inputDetail = "英文输入"
}

final class SystemStatusReader {
    private struct InputPresentation {
        let sourceID: String
        let glyph: String
        let name: String
        let detail: String
    }

    private enum InputDefaultsKey {
        static let sourceID = "UnifiedStatusLastInputSourceID"
        static let glyph = "UnifiedStatusLastInputGlyph"
        static let name = "UnifiedStatusLastInputName"
        static let detail = "UnifiedStatusLastInputDetail"
    }

    private var retainedInput: InputPresentation?

    init() {
        let defaults = UserDefaults.standard
        if
            let sourceID = defaults.string(forKey: InputDefaultsKey.sourceID),
            let glyph = defaults.string(forKey: InputDefaultsKey.glyph),
            let name = defaults.string(forKey: InputDefaultsKey.name),
            let detail = defaults.string(forKey: InputDefaultsKey.detail)
        {
            retainedInput = InputPresentation(sourceID: sourceID, glyph: glyph, name: name, detail: detail)
        }
    }

    func read() -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        readBattery(into: &snapshot)
        readWiFi(into: &snapshot)
        readVPN(into: &snapshot)
        readInputSource(into: &snapshot)
        return snapshot
    }

    private func readBattery(into snapshot: inout SystemSnapshot) {
        guard
            let infoRef = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(infoRef)?.takeRetainedValue() as? [CFTypeRef],
            let source = sources.first,
            let raw = IOPSGetPowerSourceDescription(infoRef, source)?.takeUnretainedValue() as? [String: Any]
        else { return }

        let current = raw["Current Capacity"] as? Int ?? 0
        let maximum = max(raw["Max Capacity"] as? Int ?? 100, 1)
        snapshot.batteryPercent = max(0, min(100, Int((Double(current) / Double(maximum) * 100).rounded())))
        snapshot.isFullyCharged = snapshot.batteryPercent >= 100
        snapshot.isCharging = (raw["Is Charging"] as? Bool ?? false) && !snapshot.isFullyCharged
        snapshot.isPluggedIn = (raw["Power Source State"] as? String) == "AC Power"
        if snapshot.isPluggedIn {
            snapshot.externalPowerWatts = readExternalPowerWatts()
        }

        if snapshot.isFullyCharged {
            snapshot.timeRemaining = "已满足～"
        } else if snapshot.isCharging {
            let minutes = raw["Time to Full Charge"] as? Int ?? -1
            if minutes == 0 {
                snapshot.timeRemaining = "不到 1 分钟"
            } else {
                snapshot.timeRemaining = minutes > 0 ? format(minutes: minutes) : "正在计算"
            }
        } else {
            snapshot.timeRemaining = "不在充电哦"
        }
    }

    private func readExternalPowerWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard
            IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let properties
        else { return nil }
        let battery = properties.takeRetainedValue() as NSDictionary

        if let telemetry = battery["PowerTelemetryData"] as? NSDictionary {
            // SystemPowerIn is the live adapter input. Unlike BatteryPower it
            // remains meaningful after the battery reaches 100%, when the
            // adapter is mainly powering the Mac itself.
            if let milliwatts = number(telemetry["SystemPowerIn"]), milliwatts > 0 {
                return milliwatts / 1_000
            }
            if let milliwatts = number(telemetry["BatteryPower"]), milliwatts > 0 {
                return milliwatts / 1_000
            }
        }

        guard let millivolts = number(battery["Voltage"]), let milliamps = number(battery["InstantAmperage"]) else { return nil }
        let watts = millivolts * milliamps / 1_000_000
        return watts >= 0 ? watts : nil
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return Double(value.int64Value) }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Double { return value }
        return nil
    }

    private func format(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) 分钟" }
        if remainder == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainder) 分钟"
    }

    private func readWiFi(into snapshot: inout SystemSnapshot) {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else {
            snapshot.wifiBars = 0
            snapshot.wifiName = "Wi‑Fi 已关闭"
            snapshot.wifiDetail = "打开 Wi‑Fi 后自动更新"
            return
        }

        let rssi = interface.rssiValue()
        guard rssi < 0 else {
            snapshot.wifiBars = 0
            snapshot.wifiName = "未连接"
            snapshot.wifiDetail = "Wi‑Fi 可用"
            return
        }

        snapshot.wifiBars = rssi >= -55 ? 3 : (rssi >= -70 ? 2 : 1)
        snapshot.wifiName = interface.ssid()?.isEmpty == false ? interface.ssid()! : "已连接的 Wi‑Fi"
        let channel = interface.wlanChannel()?.channelNumber
        snapshot.wifiDetail = channel.map { "信号 \(rssi) dBm · 信道 \($0)" } ?? "信号 \(rssi) dBm"
    }

    private func readVPN(into snapshot: inout SystemSnapshot) {
        snapshot.vpnActive = false
        guard
            let preferences = SCPreferencesCreate(nil, "\(appBundleIdentifier).vpn-check" as CFString, nil),
            let currentSet = SCNetworkSetCopyCurrent(preferences),
            let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService]
        else { return }

        let vpnTypes: Set<String> = ["VPN", "IPSec", "L2TP", "PPTP"]
        func isVPNInterface(_ root: SCNetworkInterface) -> Bool {
            var cursor: SCNetworkInterface? = root
            while let interface = cursor {
                if let type = SCNetworkInterfaceGetInterfaceType(interface) as String?, vpnTypes.contains(type) {
                    return true
                }
                cursor = SCNetworkInterfaceGetInterface(interface)
            }
            return false
        }

        for service in services where SCNetworkServiceGetEnabled(service) {
            guard
                let interface = SCNetworkServiceGetInterface(service),
                isVPNInterface(interface),
                let serviceID = SCNetworkServiceGetServiceID(service),
                let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID, nil, nil)
            else { continue }

            if SCNetworkConnectionGetStatus(connection) == .connected {
                snapshot.vpnActive = true
                return
            }
        }
    }

    private func readInputSource(into snapshot: inout SystemSnapshot) {
        // Polling may safely discover ASCII and non-Chinese sources. Pinyin is
        // only allowed to replace a remembered A from the source-change event
        // path below, where we can tell a keyboard switch from a focus change.
        if let candidate = sampleInputSource(),
           retainedInput == nil || candidate.glyph == "A" || candidate.glyph != "拼" {
            accept(candidate)
        }

        guard let presentation = retainedInput ?? sampleInputSource() else { return }
        snapshot.inputGlyph = presentation.glyph
        snapshot.inputName = presentation.name.isEmpty ? presentation.sourceID : presentation.name
        snapshot.inputDetail = presentation.detail
    }

    func handleInputSourceChange(explicitSwitch: Bool) {
        guard let candidate = sampleInputSource() else { return }
        if retainedInput == nil || candidate.glyph == "A" || candidate.glyph != "拼" || explicitSwitch {
            accept(candidate)
        }
    }

    func likelyExplicitKeyboardSwitch() -> Bool {
        let state = CGEventSourceStateID.combinedSessionState
        let keyAge = CGEventSource.secondsSinceLastEventType(state, eventType: .keyDown)
        let flagsAge = CGEventSource.secondsSinceLastEventType(state, eventType: .flagsChanged)
        let mouseAge = min(
            CGEventSource.secondsSinceLastEventType(state, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(state, eventType: .rightMouseDown)
        )
        let flags = CGEventSource.flagsState(state)
        let switchModifier = flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskCommand)
            || flags.contains(.maskSecondaryFn)
            || flags.contains(.maskAlphaShift)

        return mouseAge > 0.20 && ((keyAge < 0.65 && switchModifier) || flagsAge < 0.45)
    }

    private func sampleInputSource() -> InputPresentation? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let sourceID = property(source, kTISPropertyInputSourceID) ?? ""
        let localizedName = property(source, kTISPropertyLocalizedName) ?? sourceID
        let haystack = (sourceID + " " + localizedName).lowercased()

        if haystack.contains("pinyin") || haystack.contains("拼音") || haystack.contains("itabc") || haystack.contains("scim") {
            return InputPresentation(sourceID: sourceID, glyph: "拼", name: localizedName, detail: "中文拼音输入")
        } else if haystack.contains("abc") || haystack.contains("keylayout.us") || haystack.contains("british") || haystack.contains("english") {
            return InputPresentation(sourceID: sourceID, glyph: "A", name: localizedName, detail: "英文输入")
        } else if haystack.contains("japanese") || haystack.contains("kotoeri") || haystack.contains("hiragana") {
            return InputPresentation(sourceID: sourceID, glyph: "あ", name: localizedName, detail: "日文输入")
        } else if haystack.contains("korean") || haystack.contains("hangul") {
            return InputPresentation(sourceID: sourceID, glyph: "한", name: localizedName, detail: "韩文输入")
        } else {
            return InputPresentation(sourceID: sourceID, glyph: localizedName.first.map(String.init) ?? "文", name: localizedName, detail: "当前输入来源")
        }
    }

    private func accept(_ input: InputPresentation) {
        retainedInput = input
        persist(input)
    }

    private func persist(_ input: InputPresentation) {
        let defaults = UserDefaults.standard
        defaults.set(input.sourceID, forKey: InputDefaultsKey.sourceID)
        defaults.set(input.glyph, forKey: InputDefaultsKey.glyph)
        defaults.set(input.name, forKey: InputDefaultsKey.name)
        defaults.set(input.detail, forKey: InputDefaultsKey.detail)
    }

    private func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

enum StatusIconRenderer {
    static func image(snapshot: SystemSnapshot, dark: Bool, highlighted: Bool = false) -> NSImage {
        let size = NSSize(width: 28, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let main = highlighted ? NSColor.white : (dark ? NSColor.white.withAlphaComponent(0.96) : NSColor.black.withAlphaComponent(0.82))
        let track = highlighted ? NSColor.white.withAlphaComponent(0.32) : main.withAlphaComponent(0.28)
        let battery = snapshot.batteryPercent <= 20 && !snapshot.isCharging ? NSColor.systemRed : main
        let charging = NSColor(calibratedRed: 0.32, green: 0.90, blue: 0.52, alpha: 1)

        let center = NSPoint(x: 14, y: 10.9)
        let radius: CGFloat = 8.1
        let lineWidth: CGFloat = 1.65

        // Symmetric 240° battery track. AppKit uses a bottom-left origin here,
        // so the omitted 30°...150° segment is the opening at the top.
        let trackPath = NSBezierPath()
        trackPath.lineWidth = lineWidth
        trackPath.lineCapStyle = .round
        trackPath.appendArc(withCenter: center, radius: radius, startAngle: 150, endAngle: 390, clockwise: false)
        track.setStroke()
        trackPath.stroke()

        // Fill starts on the left and ends toward the right, so the empty segment remains on the right.
        let fraction = CGFloat(max(0, min(100, snapshot.batteryPercent))) / 100
        if fraction > 0.001 {
            let fillPath = NSBezierPath()
            fillPath.lineWidth = lineWidth
            fillPath.lineCapStyle = .round
            fillPath.appendArc(withCenter: center, radius: radius, startAngle: 150, endAngle: 150 + 240 * fraction, clockwise: false)
            battery.setStroke()
            fillPath.stroke()
        }

        // Three equally spaced points sit on the same circle inside the top opening.
        // The opening endpoints are 30° and 150°. Placing the points at
        // 60°/90°/120° makes all four angular gaps exactly 30°. The array is
        // ordered left-to-right so a two-bar signal leaves the right point open.
        let dotAngles: [CGFloat] = [120, 90, 60]
        for (index, degrees) in dotAngles.enumerated() {
            let angle = degrees * .pi / 180
            let p = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            let dotRadius: CGFloat = 1.05
            let rect = NSRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            let dot = NSBezierPath(ovalIn: rect)
            dot.lineWidth = 0.9
            main.setStroke()
            if index < snapshot.wifiBars {
                main.setFill()
                dot.fill()
            } else {
                dot.stroke()
            }
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let glyphFont = NSFont.systemFont(ofSize: snapshot.inputGlyph == "A" ? 8.4 : 8.0, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: glyphFont,
            .foregroundColor: main,
            .paragraphStyle: paragraph
        ]
        let glyphRect = NSRect(x: 7, y: center.y - 4.9, width: 14, height: 10)
        snapshot.inputGlyph.draw(in: glyphRect, withAttributes: attrs)

        if snapshot.isCharging {
            let boltCenter = NSPoint(x: center.x, y: 2.6)
            let badge = NSBezierPath(ovalIn: NSRect(x: boltCenter.x - 2.4, y: boltCenter.y - 2.4, width: 4.8, height: 4.8))
            charging.setFill()
            badge.fill()
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: boltCenter.x + 0.35, y: boltCenter.y + 2.0))
            bolt.line(to: NSPoint(x: boltCenter.x - 1.05, y: boltCenter.y + 0.15))
            bolt.line(to: NSPoint(x: boltCenter.x - 0.15, y: boltCenter.y + 0.15))
            bolt.line(to: NSPoint(x: boltCenter.x - 0.55, y: boltCenter.y - 1.85))
            bolt.line(to: NSPoint(x: boltCenter.x + 1.15, y: boltCenter.y + 0.35))
            bolt.line(to: NSPoint(x: boltCenter.x + 0.2, y: boltCenter.y + 0.35))
            bolt.close()
            NSColor.black.withAlphaComponent(0.75).setFill()
            bolt.fill()
        }

        image.isTemplate = false
        return image
    }
}

final class DashboardView: NSView {
    private enum RowIcon {
        case text(String)
        case wifi
        case battery(level: CGFloat)
    }

    var onSpeedTest: (() -> Void)?
    var snapshot = SystemSnapshot() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    private var wifiRowRect: NSRect {
        NSRect(x: 14, y: 126, width: bounds.width - 28, height: 58)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedWhite: 0.095, alpha: 0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).fill()

        drawText("系统状态", in: NSRect(x: 22, y: 18, width: 240, height: 25), size: 18, weight: .semibold, color: .white)
        drawText("实时更新", in: NSRect(x: 271, y: 23, width: 70, height: 18), size: 11, weight: .medium, color: NSColor.systemGreen)

        drawRow(
            y: 58,
            icon: .text(snapshot.inputGlyph),
            title: snapshot.inputName,
            detail: snapshot.inputDetail,
            tint: NSColor(calibratedRed: 0.43, green: 0.58, blue: 1, alpha: 1)
        )

        let wifiTint = snapshot.vpnActive ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.92)
        drawRow(
            y: 126,
            icon: .wifi,
            title: snapshot.wifiName,
            detail: snapshot.wifiDetail,
            tint: wifiTint,
            actionTitle: "测速 ↗"
        )

        let batteryTitle = "电池 \(snapshot.batteryPercent)%"
        let batteryDetail: String
        if snapshot.isPluggedIn {
            let power = snapshot.externalPowerWatts.map { "实时功率 " + String(format: "%.1f W", $0) } ?? "实时功率读取中"
            if snapshot.isFullyCharged {
                batteryDetail = "已满足～ · \(power)"
            } else if snapshot.isCharging {
                batteryDetail = "正在充电 · \(snapshot.timeRemaining) · \(power)"
            } else {
                batteryDetail = "不在充电哦 · \(power)"
            }
        } else {
            batteryDetail = snapshot.timeRemaining
        }
        let batteryTint = snapshot.batteryPercent <= 20 && !snapshot.isCharging
            ? NSColor.systemRed
            : (snapshot.isCharging ? NSColor.systemGreen : NSColor(calibratedRed: 0.61, green: 0.83, blue: 0.44, alpha: 1))
        let batteryLevel = CGFloat(snapshot.batteryPercent) / 100
        drawRow(
            y: 194,
            icon: .battery(level: batteryLevel),
            title: batteryTitle,
            detail: batteryDetail,
            tint: batteryTint,
            progress: batteryLevel
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if wifiRowRect.contains(point) {
            onSpeedTest?()
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(wifiRowRect, cursor: .pointingHand)
    }

    private func drawRow(y: CGFloat, icon: RowIcon, title: String, detail: String, tint: NSColor, actionTitle: String? = nil, progress: CGFloat? = nil) {
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 14, y: y, width: bounds.width - 28, height: 58), xRadius: 11, yRadius: 11).fill()

        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: NSRect(x: 25, y: y + 9, width: 40, height: 40), xRadius: 10, yRadius: 10).fill()

        switch icon {
        case .text(let symbol):
            drawText(symbol, in: NSRect(x: 25, y: y + 18, width: 40, height: 22), size: 15, weight: .semibold, color: tint, alignment: .center)
        case .wifi:
            drawWiFiIcon(y: y, tint: tint)
        case .battery(let level):
            drawBatteryIcon(y: y, level: level, tint: tint)
        }

        let titleWidth: CGFloat = progress != nil ? 154 : (actionTitle == nil ? 244 : 184)
        drawText(title, in: NSRect(x: 78, y: y + 10, width: titleWidth, height: 21), size: 14, weight: .semibold, color: .white)
        drawText(detail, in: NSRect(x: 78, y: y + 32, width: 244, height: 17), size: 11, weight: .regular, color: NSColor.white.withAlphaComponent(0.56))

        if let actionTitle {
            let actionRect = NSRect(x: 272, y: y + 10, width: 54, height: 21)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: actionRect, xRadius: 7, yRadius: 7).fill()
            drawText(actionTitle, in: NSRect(x: actionRect.minX, y: actionRect.minY + 3, width: actionRect.width, height: 16), size: 10.5, weight: .medium, color: tint, alignment: .center)
        }

        if let progress {
            let trackRect = NSRect(x: 244, y: y + 15, width: 78, height: 6)
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 3, yRadius: 3).fill()
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: trackRect.width * max(0, min(1, progress)), height: trackRect.height)
            tint.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func drawWiFiIcon(y: CGFloat, tint: NSColor) {
        guard let image = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        ) else { return }
        image.draw(in: NSRect(x: 36, y: y + 20, width: 18, height: 18))
    }

    private func drawBatteryIcon(y: CGFloat, level: CGFloat, tint: NSColor) {
        let body = NSRect(x: 31, y: y + 22, width: 25, height: 14)
        let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.55
        tint.setStroke()
        outline.stroke()

        let terminal = NSBezierPath(roundedRect: NSRect(x: 56.8, y: y + 26, width: 2.5, height: 6), xRadius: 1.2, yRadius: 1.2)
        tint.setFill()
        terminal.fill()

        let inner = NSRect(x: body.minX + 2.4, y: body.minY + 2.4, width: body.width - 4.8, height: body.height - 4.8)
        let fillWidth = inner.width * max(0, min(1, level))
        if fillWidth > 0.4 {
            let fill = NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height), xRadius: 1.5, yRadius: 1.5)
            tint.setFill()
            fill.fill()
        }
    }

    private func drawText(_ text: String, in rect: NSRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        text.draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}

final class DashboardController: NSViewController {
    let dashboard = DashboardView(frame: NSRect(x: 0, y: 0, width: 356, height: 266))

    override func loadView() {
        view = dashboard
        preferredContentSize = dashboard.frame.size
    }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
    private let reader = SystemStatusReader()
    private var snapshot = SystemSnapshot()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var hoverTimer: Timer?
    private var outsideSince: TimeInterval?
    private var lastWorkspaceActivation = -Double.infinity
    private let popover = NSPopover()
    private let dashboardController = DashboardController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        LaunchAtLoginManager.shared.reconcileRegistrations()
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemPressed(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.toolTip = "输入法 · Wi‑Fi · 电池"

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = dashboardController
        dashboardController.dashboard.onSpeedTest = { [weak self] in
            guard let url = URL(string: "https://ptclspeed.speedtestcustom.com") else { return }
            self?.popover.performClose(nil)
            NSWorkspace.shared.open(url)
        }

        let sourceChangeName = Notification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceDidChange(_:)),
            name: sourceChangeName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        refresh()
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)

        if !UserDefaults.standard.bool(forKey: onboardingDefaultsKey) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                OnboardingWindowController.shared.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        stopPopoverAutoCloseMonitoring()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        lastWorkspaceActivation = ProcessInfo.processInfo.systemUptime
    }

    @objc private func inputSourceDidChange(_ notification: Notification) {
        let activationAge = ProcessInfo.processInfo.systemUptime - lastWorkspaceActivation
        let explicitSwitch = activationAge >= 0.8 && reader.likelyExplicitKeyboardSwitch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.reader.handleInputSourceChange(explicitSwitch: explicitSwitch)
            self.refresh()
        }
    }

    @objc private func refresh() {
        let next = reader.read()
        if next != snapshot || statusItem.button?.image == nil {
            snapshot = next
            dashboardController.dashboard.snapshot = next
            updateIcon()
        }
    }

    private func updateIcon(highlighted: Bool = false) {
        guard let button = statusItem.button else { return }
        let match = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        button.image = StatusIconRenderer.image(snapshot: snapshot, dark: match == .darkAqua, highlighted: highlighted)
        button.imageScaling = .scaleNone
        button.setAccessibilityLabel("\(snapshot.inputName)，Wi‑Fi \(snapshot.wifiBars) 格，电池 \(snapshot.batteryPercent)%")
    }

    @objc private func statusItemPressed(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            refresh()
            updateIcon(highlighted: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            startPopoverAutoCloseMonitoring()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverAutoCloseMonitoring()
        updateIcon()
    }

    private func startPopoverAutoCloseMonitoring() {
        stopPopoverAutoCloseMonitoring()
        outsideSince = nil
        let timer = Timer(timeInterval: 0.15, target: self, selector: #selector(checkPopoverHover), userInfo: nil, repeats: true)
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPopoverAutoCloseMonitoring() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        outsideSince = nil
    }

    @objc private func checkPopoverHover() {
        guard popover.isShown else {
            stopPopoverAutoCloseMonitoring()
            return
        }

        let mouse = NSEvent.mouseLocation
        let overButton: Bool
        if let button = statusItem.button, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -3, dy: -3)
            overButton = buttonFrame.contains(mouse)
        } else {
            overButton = false
        }

        let overPopover = dashboardController.view.window?.frame.insetBy(dx: -3, dy: -3).contains(mouse) ?? false
        if overButton || overPopover {
            outsideSince = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let outsideSince {
            if now - outsideSince >= 3 {
                popover.performClose(nil)
            }
        } else {
            outsideSince = now
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let onboarding = NSMenuItem(title: "新手引导与设置…", action: #selector(openOnboarding), keyEquivalent: "")
        onboarding.target = self
        menu.addItem(onboarding)
        menu.addItem(NSMenuItem.separator())

        let launch = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launch.target = self
        launch.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(NSMenuItem.separator())

        let settings = NSMenuItem(title: "打开\(SystemIconInspector.settingsDisplayName)…", action: #selector(openControlCenterSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let inputSettings = NSMenuItem(title: "打开输入法设置…", action: #selector(openInputSettings), keyEquivalent: "")
        inputSettings.target = self
        menu.addItem(inputSettings)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "退出三合一状态", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openOnboarding() {
        OnboardingWindowController.shared.show()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            let target = !LaunchAtLoginManager.shared.isEnabled
            try LaunchAtLoginManager.shared.setEnabled(target)
            sender.state = target ? .on : .off
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func openControlCenterSettings() {
        SystemIconInspector.openControlCenterSettings()
    }

    @objc private func openInputSettings() {
        SystemIconInspector.openKeyboardSettings()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
