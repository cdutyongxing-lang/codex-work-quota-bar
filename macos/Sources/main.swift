import AppKit
import ServiceManagement
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var panel: QuotaPanel!
    private let view = QuotaView()
    private let defaults = UserDefaults.standard
    private let anchorQueue = DispatchQueue(label: "quota.anchor", qos: .utility)
    private let serverQueue = DispatchQueue(label: "quota.server", qos: .utility)
    private var server: AppServer? // accessed only on serverQueue
    private var serverPath: URL?
    private var anchorBusy = false
    private var refreshState = RefreshState()
    private var lastOwner: CGRect?
    private var snapshot: QuotaSnapshot?
    private var selectedBucket: String?
    private var paused: Bool { refreshState.paused }
    private var followWindow = false
    private var manual = false
    private var dragging = false
    private var calibrating = false
    private var status = "等待 ChatGPT / Codex 打开"
    private var placementStatus: String?
    private var stale = false
    private var timer: Timer?
    private let guardFiles = QuotaGuardFiles()
    private var guardEnabled = false
    private var guardThreshold = 15
    private var guardError: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }) else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        manual = defaults.bool(forKey: "manualPlacement")
        followWindow = defaults.bool(forKey: "followWindow")
        selectedBucket = defaults.string(forKey: "bucket")
        guardEnabled = defaults.bool(forKey: "quotaGuardEnabled")
        let savedThreshold = defaults.object(forKey: "quotaGuardThreshold") as? Int ?? 15
        guardThreshold = QuotaGuardState.validThreshold(savedThreshold) ? savedThreshold : 15
        if guardEnabled {
            do {
                if let executable = Bundle.main.executableURL {
                    try QuotaGuardInstaller().install(executable: executable)
                }
            } catch {
                guardEnabled = false
                guardError = "低额度接入更新失败：" + error.localizedDescription
            }
        }
        panel = QuotaPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 26),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        view.onDrag = { [weak self] _ in self?.dragging = true }
        view.onDragEnd = { [weak self] in self?.savePlacement() }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "chart.pie", accessibilityDescription: "Codex 额度条")
        updateMenu()
        // Menu-bar quotas work without Accessibility. Enable window following explicitly.
        let tracker = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in self?.tick() }
        timer = tracker
        RunLoop.main.add(tracker, forMode: .common)
        tick()
    }

    private func isCodex(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier == "com.openai.codex" ||
            application.bundleURL?.lastPathComponent.lowercased() == "codex.app"
    }

    private func tick(manualRefresh: Bool = false) {
        let running = NSWorkspace.shared.runningApplications.filter { isCodex($0) && !$0.isTerminated }
        let front = NSWorkspace.shared.frontmostApplication
        let app = running.first(where: { $0.processIdentifier == front?.processIdentifier }) ??
            running.first(where: { $0.processIdentifier == refreshState.hostPID }) ?? running.first
        if refreshState.setHost(app?.processIdentifier) {
            serverQueue.async { [weak self] in
                self?.server?.close(); self?.server = nil; self?.serverPath = nil
            }
            stale = snapshot != nil
            status = app == nil ? "等待 ChatGPT / Codex 打开" : "等待读取额度"
            placementStatus = nil
            updateContent()
        }
        guard let app = app else {
            panel.orderOut(nil)
            return
        }
        if let ticket = refreshState.begin(manual: manualRefresh) { refresh(app, ticket: ticket) }
        guard !paused else { panel.orderOut(nil); return }
        view.needsDisplay = true // refresh countdown without extra server calls.
        guard followWindow else { panel.orderOut(nil); return }
        guard let front = NSWorkspace.shared.frontmostApplication, isCodex(front),
              !paused, AXIsProcessTrusted() else {
            panel.orderOut(nil)
            if !AXIsProcessTrusted(), placementStatus != "菜单栏可用；跟随窗口需辅助功能权限" {
                placementStatus = "菜单栏可用；跟随窗口需辅助功能权限"; updateMenu()
            }
            return
        }
        guard !dragging && !anchorBusy else { return }
        anchorBusy = true
        let pid = front.processIdentifier
        let manualMode = manual || calibrating
        anchorQueue.async { [weak self] in
            let geometry: ComposerAnchor?
            if manualMode, let (_, owner) = AccessibilityAnchor.window(pid) {
                geometry = ComposerAnchor(owner: owner, slot: owner)
            } else { geometry = AccessibilityAnchor.read(pid) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.anchorBusy = false
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.refreshState.hostPID == pid, self.followWindow,
                      !self.paused && !self.dragging else { self.panel.orderOut(nil); return }
                guard let geometry = geometry else {
                    self.panel.orderOut(nil)
                    self.placementStatus = "暂未找到输入框，可从菜单手动校准"; self.updateMenu(); return
                }
                if self.placementStatus != nil { self.placementStatus = nil; self.updateMenu() }
                self.lastOwner = geometry.owner
                let frame: CGRect
                if manualMode {
                    let x = self.defaults.object(forKey: "manualX") as? Double ?? 0.3
                    let y = self.defaults.object(forKey: "manualY") as? Double ?? 0.9
                    frame = RelativePlacement.frame(owner: geometry.owner, x: x, y: y,
                                                    width: min(360, geometry.owner.width - 20), height: 26)
                } else {
                    frame = CGRect(x: geometry.slot.minX, y: geometry.slot.minY,
                                   width: min(360, geometry.slot.width), height: 26)
                }
                self.panel.setFrame(AccessibilityAnchor.cocoaRect(frame), display: true)
                self.panel.orderFrontRegardless()
            }
        }
    }

    private func executable(_ app: NSRunningApplication) -> URL? {
        var candidates: [String] = []
        if let configured = defaults.string(forKey: "cliPath") { candidates.append(configured) }
        if let bundle = app.bundleURL?.path {
            candidates += [bundle + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                           bundle + "/Contents/Resources/codex", bundle + "/Contents/Resources/bin/codex"]
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private func refresh(_ app: NSRunningApplication, ticket: RefreshState.Ticket) {
        guard let path = executable(app) else {
            _ = refreshState.finish(ticket)
            status = "未找到 Codex CLI：菜单中选择路径"; stale = true; updateContent(); return
        }
        status = "正在读取额度…"
        updateContent()
        serverQueue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<QuotaSnapshot, Error>
            do {
                if self.server == nil || self.serverPath != path {
                    self.server?.close()
                    self.server = try AppServer(executable: path)
                    self.serverPath = path
                }
                result = .success(try self.server!.read())
            } catch {
                self.server?.close(); self.server = nil; self.serverPath = nil
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard self.refreshState.finish(ticket) else { return }
                switch result {
                case .success(let value):
                    self.snapshot = value
                    self.stale = false
                    self.status = value.windows(value.selected(self.selectedBucket)).isEmpty ? "账户暂未返回额度" : "额度已更新"
                case .failure(let error): self.status = error.localizedDescription; self.stale = true
                }
                self.updateContent()
            }
        }
    }

    private func updateContent() {
        publishGuardState()
        view.windows = snapshot?.windows(snapshot?.selected(selectedBucket)) ?? []
        view.status = status
        view.stale = stale
        let indicator = paused ? " · 已暂停" : (stale ? " · 待更新" : "")
        item.button?.title = view.windows.isEmpty ? (paused ? " 已暂停" : "") : " " + view.windows.map {
            "\($0.compactLabel) \($0.percentage)"
        }.joined(separator: " · ") + indicator
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item.button?.imagePosition = .imageLeading
        var lines = view.windows.map {
            "\($0.label) \($0.percentage) · \($0.countdown() ?? "重置未知") · \($0.resetText ?? "日期未知") 重置（北京时间）"
        }
        if let updated = snapshot?.updated { lines.append("读取时间：\(DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .medium))") }
        if stale { lines.append("数据待更新：" + status) }
        if paused { lines.append("自动刷新已暂停；“立即刷新一次”仍可读取最新额度") }
        view.toolTip = lines.isEmpty ? status : lines.joined(separator: "\n")
        item.button?.toolTip = view.toolTip
        updateMenu()
    }

    private func publishGuardState() {
        let enabled = guardEnabled && !paused && !stale && refreshState.hostPID != nil
        do {
            try guardFiles.publish(QuotaGuardState(enabled: enabled, threshold: guardThreshold, snapshot: snapshot))
        } catch { guardError = "保护状态写入失败：" + error.localizedDescription }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, state: Bool? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        if let state = state { entry.state = state ? .on : .off }
        menu.addItem(entry)
        return entry
    }

    private func updateMenu() {
        let menu = NSMenu()
        let headline = paused ? "已暂停自动刷新" : (placementStatus ?? status)
        let info = NSMenuItem(title: headline, action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        if headline != status {
            let connection = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            connection.isEnabled = false; menu.addItem(connection)
        }
        for quota in view.windows {
            let row = NSMenuItem(title: "\(quota.label) \(quota.percentage) · \(quota.countdown() ?? "重置未知")", action: nil, keyEquivalent: "")
            row.isEnabled = false; menu.addItem(row)
        }
        menu.addItem(.separator())
        _ = add(menu, "立即刷新一次", #selector(refreshNow))
        if let snapshot = snapshot, snapshot.buckets.count > 1 {
            let parent = NSMenuItem(title: "额度类型", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for id in snapshot.buckets.keys.sorted() {
                let row = add(sub, id, #selector(selectBucket(_:)), state: snapshot.selected(selectedBucket) == id)
                row.representedObject = id
            }
            parent.submenu = sub; menu.addItem(parent)
        }
        _ = add(menu, paused ? "恢复自动刷新" : "暂停自动刷新", #selector(togglePaused))
        let protection = NSMenuItem(title: "Codex 低额度保护（\(guardThreshold)%）", action: nil, keyEquivalent: "")
        let protectionMenu = NSMenu()
        _ = add(protectionMenu, "启用低额度提示", #selector(toggleGuard), state: guardEnabled)
        let receipt = guardFiles.receipt()
        let connected = receipt.map { Date().timeIntervalSince1970 - $0.lastCheckAt < 180 } ?? false
        let guardStatus = guardError ?? (guardEnabled ? (connected ? "最近已收到 Codex Hook 检查" : "等待 Codex Hook 调用；首次需 /hooks 信任") : "未启用，不发送提示")
        let protectionInfo = NSMenuItem(title: guardStatus, action: nil, keyEquivalent: "")
        protectionInfo.isEnabled = false; protectionMenu.addItem(protectionInfo)
        if receipt?.hasPrompted(now: Date().timeIntervalSince1970) == true {
            let info = NSMenuItem(title: "本周期已提醒；继续工作由你决定", action: nil, keyEquivalent: "")
            info.isEnabled = false; protectionMenu.addItem(info)
        }
        if let sent = receipt?.lastSentAt {
            let time = DateFormatter.localizedString(from: Date(timeIntervalSince1970: sent), dateStyle: .short, timeStyle: .short)
            let info = NSMenuItem(title: "最近生成提示：\(time)（不代表已保存）", action: nil, keyEquivalent: "")
            info.isEnabled = false; protectionMenu.addItem(info)
        }
        protectionMenu.addItem(.separator())
        for value in [5, 10, 15, 20, 25, 30] {
            let entry = add(protectionMenu, "剩余 \(value)% 时提示", #selector(selectGuardThreshold(_:)), state: value == guardThreshold)
            entry.representedObject = value
        }
        _ = add(protectionMenu, "自定义阈值…", #selector(customGuardThreshold))
        protectionMenu.addItem(.separator())
        _ = add(protectionMenu, "打开 Codex Hook 审查终端…", #selector(openGuardReview))
        _ = add(protectionMenu, "接入与权限说明…", #selector(guardHelp))
        _ = add(protectionMenu, "移除本工具的 Hook 接入", #selector(removeGuard))
        protection.submenu = protectionMenu; menu.addItem(protection)
        _ = add(menu, "跟随 ChatGPT 窗口（需辅助功能）", #selector(toggleFollow), state: followWindow)
        _ = add(menu, calibrating ? "完成校准" : "手动校准位置", #selector(calibrate))
        _ = add(menu, "恢复自动定位", #selector(restore))
        menu.addItem(.separator())
        _ = add(menu, "开启辅助功能权限…", #selector(requestAccessibility))
        _ = add(menu, "选择 Codex CLI…", #selector(chooseCLI))
        let loginStatus = SMAppService.mainApp.status
        _ = add(menu, "随 macOS 登录启动", #selector(toggleLogin), state: loginStatus == .enabled)
        if loginStatus == .requiresApproval { _ = add(menu, "在系统设置批准登录启动…", #selector(openLoginSettings)) }
        _ = add(menu, "使用说明", #selector(openDocs))
        menu.addItem(.separator())
        _ = add(menu, "退出额度条", #selector(quit))
        item.menu = menu
        view.contextMenu = menu
    }

    @objc private func refreshNow() { tick(manualRefresh: true) }
    @objc private func togglePaused() {
        refreshState.setPaused(!paused)
        updateContent(); tick()
    }
    @objc private func toggleGuard() {
        if guardEnabled {
            guardEnabled = false
        } else {
            do {
                guard let executable = Bundle.main.executableURL else { throw QuotaError.message("无法找到保护接入程序") }
                try QuotaGuardInstaller().install(executable: executable)
                guardEnabled = true
            } catch { showError("低额度保护接入失败", error.localizedDescription); return }
        }
        guardError = nil
        defaults.set(guardEnabled, forKey: "quotaGuardEnabled")
        updateContent()
        if guardEnabled { guardHelp() }
    }
    @objc private func selectGuardThreshold(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Int, QuotaGuardState.validThreshold(value) else { return }
        guardThreshold = value
        defaults.set(value, forKey: "quotaGuardThreshold")
        updateContent()
    }
    @objc private func customGuardThreshold() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "设置剩余额度提示阈值"
        alert.informativeText = "输入 1–90 的整数。例如 15 表示 5 小时剩余额度不高于 15% 时提示保存进度。"
        let field = NSTextField(string: String(guardThreshold))
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let value = Int(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              QuotaGuardState.validThreshold(value) else { showError("阈值无效", "请输入 1–90 的整数"); return }
        guardThreshold = value
        defaults.set(value, forKey: "quotaGuardThreshold")
        updateContent()
    }
    @objc private func guardHelp() {
        showError("Codex 低额度提示接入", "首次启用会把本工具的 PostToolUse Hook 合并到 Codex 用户 hooks.json；已有配置会保留并备份。\n\n从本菜单打开“Codex Hook 审查终端”，在 CLI 中输入 /hooks，审查并信任包含 quota-hook 的 PostToolUse 条目，然后退出审查终端，重新打开主应用并启动新会话。未完成信任时不会生效；全程不会替你接受信任或绕过检查。\n\n额度达到阈值后，任务在下一次工具调用完成时收到保存进度并结束本轮的提示；同一本机工具共享的 5 小时周期内，所有会话合计最多一次；你之后发出继续指令即可继续，不必等待重置。它不强制中断，也不能保证 AI 已完成保存。\n\n仅支持加载了该 Hook 的本机 Codex；不控制云端 ChatGPT Work。暂停刷新或关闭保护会停用提示，退出工具也会停用。收尾过程会使用模型额度。")
    }
    @objc private func openGuardReview() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { isCodex($0) }),
              let cli = executable(app) else { showError("未找到 Codex CLI", "请先打开主应用，或从菜单选择官方 Codex CLI"); return }
        do {
            let script = try QuotaGuardInstaller().reviewLauncher(cli: cli)
            NSWorkspace.shared.open(script)
        } catch { showError("无法准备审查终端", error.localizedDescription) }
    }
    @objc private func removeGuard() {
        guardEnabled = false
        defaults.set(false, forKey: "quotaGuardEnabled")
        publishGuardState()
        do { try QuotaGuardInstaller().remove(); guardError = nil }
        catch { guardError = "移除 Hook 失败：" + error.localizedDescription; showError("移除接入失败", error.localizedDescription) }
        updateContent()
    }
    @objc private func toggleFollow() {
        followWindow.toggle()
        defaults.set(followWindow, forKey: "followWindow")
        if followWindow && !AXIsProcessTrusted() { requestAccessibility() }
        if !followWindow { placementStatus = nil }
        updateMenu(); tick()
    }
    @objc private func selectBucket(_ sender: NSMenuItem) {
        selectedBucket = sender.representedObject as? String
        defaults.set(selectedBucket, forKey: "bucket"); updateContent()
    }
    @objc private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func chooseCLI() {
        NSApp.activate(ignoringOtherApps: true)
        let chooser = NSOpenPanel()
        chooser.message = "选择 codex 可执行文件，例如 /opt/homebrew/bin/codex"
        chooser.canChooseDirectories = false; chooser.allowsMultipleSelection = false
        if chooser.runModal() == .OK, let url = chooser.url, FileManager.default.isExecutableFile(atPath: url.path) {
            defaults.set(url.path, forKey: "cliPath")
            refreshState.invalidate()
            tick(manualRefresh: true)
        }
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            updateMenu()
        } catch { showError("登录启动设置失败", error.localizedDescription) }
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func openDocs() {
        if let url = Bundle.main.url(forResource: "使用说明", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func calibrate() {
        if calibrating { savePlacement(); calibrating = false; view.calibrating = false }
        else {
            calibrating = true; view.calibrating = true; refreshState.setPaused(false)
            showError("校准位置", "关闭此提示后切回 Codex，将额度条拖到输入框底部的空白处，再右键选择“完成校准”。位置会按窗口比例保存。")
        }
        updateMenu(); tick()
    }
    @objc private func restore() {
        manual = false; calibrating = false; view.calibrating = false
        defaults.set(false, forKey: "manualPlacement"); updateMenu(); tick()
    }

    private func savePlacement() {
        defer { dragging = false }
        guard dragging || calibrating else { return }
        guard let owner = lastOwner else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = panel.frame
        let top = primaryTop - frame.maxY
        let x = max(0, min(1, (frame.minX - owner.minX) / max(1, owner.width - frame.width)))
        let y = max(0, min(1, (top - owner.minY) / max(1, owner.height - frame.height)))
        defaults.set(Double(x), forKey: "manualX"); defaults.set(Double(y), forKey: "manualY")
        defaults.set(true, forKey: "manualPlacement"); manual = true
    }
    private func showError(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.runModal()
    }
    func applicationWillTerminate(_ notification: Notification) {
        try? guardFiles.publish(QuotaGuardState(enabled: false, threshold: guardThreshold, snapshot: snapshot))
        server?.close()
    }
}

if CommandLine.arguments.contains("--quota-hook") {
    QuotaGuardFiles.runHook()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
