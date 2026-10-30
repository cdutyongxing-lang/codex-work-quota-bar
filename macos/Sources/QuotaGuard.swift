import Foundation
import CoreFoundation
import CryptoKit
import Darwin

struct QuotaGuardState: Codable {
    let enabled: Bool
    let threshold: Int
    let updatedAt: Double
    let remaining: Double?
    let resetsAt: Double?

    static func validThreshold(_ value: Int) -> Bool { (1...90).contains(value) }

    init(enabled: Bool, threshold: Int, snapshot: QuotaSnapshot?) {
        self.enabled = enabled
        self.threshold = threshold
        updatedAt = snapshot?.updated.timeIntervalSince1970 ?? 0
        // Only the Codex five-hour bucket, never an unrelated model or weekly limit.
        let window = snapshot?.windows("codex").first(where: { $0.minutes == 300 })
        remaining = window?.remaining
        resetsAt = window?.reset?.timeIntervalSince1970
    }

    init(enabled: Bool, threshold: Int, updatedAt: Double, remaining: Double?, resetsAt: Double?) {
        self.enabled = enabled; self.threshold = threshold; self.updatedAt = updatedAt
        self.remaining = remaining; self.resetsAt = resetsAt
    }
}

struct QuotaGuardLedger: Codable {
    var windowReset: Double?
    var sessions: [String: Double] = [:] // SHA256 session identifiers, never chat content.
    var lastCheckAt: Double = 0
    var lastSentAt: Double?

    // v1.1.0 receipts are also evidence that this entire window was notified.
    func hasPrompted(now: Double) -> Bool {
        guard let reset = windowReset, reset.isFinite, reset > now else { return false }
        return lastSentAt != nil || !sessions.isEmpty
    }
}

enum QuotaGuardPolicy {
    static func evaluate(input: [String: Any], state: QuotaGuardState,
                         ledger: inout QuotaGuardLedger, now: Double) -> [String: Any]? {
        guard input["hook_event_name"] as? String == "PostToolUse",
              let session = input["session_id"] as? String,
              !session.isEmpty, session.utf8.count <= 512 else { return nil }
        ledger.lastCheckAt = now
        guard state.enabled, QuotaGuardState.validThreshold(state.threshold),
              state.updatedAt.isFinite, now - state.updatedAt >= -5,
              now - state.updatedAt <= 180,
              let remaining = state.remaining, remaining.isFinite, (0...100).contains(remaining),
              remaining <= Double(state.threshold),
              let reset = state.resetsAt, reset.isFinite, reset > now else { return nil }
        if ledger.hasPrompted(now: now) {
            // A corrected reset timestamp does not start a new quota window.
            // Remember extensions even on silent checks, including across restarts.
            ledger.windowReset = max(ledger.windowReset!, reset)
            return nil
        }
        // A pre-boundary snapshot cannot rearm a previously notified window.
        if let previousReset = ledger.windowReset, state.updatedAt < previousReset { return nil }
        ledger.windowReset = reset
        ledger.sessions = [:]
        let key = SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
        ledger.sessions[key] = now
        ledger.lastSentAt = now
        let percent = String(format: "%.1f", remaining)
        let message = """
        用户已启用 Codex 低额度保护：当前 5 小时剩余 \(percent)%，触发阈值 \(state.threshold)%。
        这是本机本个 5 小时周期唯一的一次收尾提示，只适用于触发时正在处理的这一轮，不是对后续轮次的持续限制。
        请在最近的安全节点停止新增工作，保存已经完成的文件修改，不要撤销已有成果。
        在当前项目的进度文件中记录：已完成、未完成、修改的文件、测试结果、下一步及恢复所需信息；没有进度文件时可新建 CHECKPOINT.md。
        完成保存后向用户说明进度文件位置，然后结束本轮，等待用户下一条指示。不要睡眠等待重置、持续轮询额度或自动恢复工作。
        用户之后明确要求“继续”或发送新的工作指令时，应正常执行；不要仅因这条历史提示再次保存并停止，也无需等待额度恢复。是否继续由用户决定。
        不要为此自动提交或推送 Git、部署、删除文件或强制终止外部任务。若无法写文件，说明原因并在回复中给出可恢复的进度摘要。
        这是一条收尾提示，并不表示保存已经完成。
        """
        return ["systemMessage": "Codex 额度条：5h 剩余 \(percent)%，已提示保存进度并收尾",
                "hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": message]]
    }
}

struct QuotaGuardFiles {
    let root: URL
    var state: URL { root.appendingPathComponent("quota-state.json") }
    var ledger: URL { root.appendingPathComponent("hook-receipts.json") }
    var helper: URL { root.appendingPathComponent("quota-hook") }

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexQuotaBar")) { self.root = root }

    func prepare() throws {
        let manager = FileManager.default
        // Do not follow a replaced support directory or helper into other files.
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw QuotaError.message("保护资料目录是符号链接，未进行写入")
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    }

    func publish(_ value: QuotaGuardState) throws {
        if !value.enabled && !FileManager.default.fileExists(atPath: root.path) { return }
        try prepare()
        try JSONEncoder().encode(value).write(to: state, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: state.path)
    }

    func receipt() -> QuotaGuardLedger? {
        guard let data = try? Data(contentsOf: ledger), data.count <= 1_048_576 else { return nil }
        return try? JSONDecoder().decode(QuotaGuardLedger.self, from: data)
    }

    func handle(_ input: [String: Any], now: Double = Date().timeIntervalSince1970) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: root.path),
              let data = try? Data(contentsOf: state), data.count < 65536,
              let value = try? JSONDecoder().decode(QuotaGuardState.self, from: data) else { return nil }
        let fd = open(root.appendingPathComponent("hook.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        let existing = receipt()
        if FileManager.default.fileExists(atPath: ledger.path) && existing == nil { return nil }
        var log = existing ?? QuotaGuardLedger()
        let previousCheck = log.lastCheckAt
        let previousWindow = log.windowReset
        let output = QuotaGuardPolicy.evaluate(input: input, state: value, ledger: &log, now: now)
        if output != nil || log.windowReset != previousWindow || log.lastCheckAt - previousCheck >= 30 {
            // Persist before returning context: at most once per window, across all sessions.
            guard let encoded = try? JSONEncoder().encode(log) else { return nil }
            do {
                try encoded.write(to: ledger, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ledger.path)
            } catch { return nil }
        }
        return output
    }

    static func readInput(_ handle: FileHandle) -> [String: Any]? {
        var input = Data()
        do {
            while let chunk = try handle.read(upToCount: min(65536, 1_048_577 - input.count)), !chunk.isEmpty {
                input.append(chunk)
                if input.count > 1_048_576 { return nil }
            }
        } catch { return nil }
        return (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    }

    static func runHook() {
        // Read through EOF: a large tool result can arrive in several pipe chunks.
        // Fail open and silently on oversized/invalid input.
        guard let object = readInput(FileHandle.standardInput),
              let output = QuotaGuardFiles().handle(object),
              var data = try? JSONSerialization.data(withJSONObject: output) else { return }
        data.append(10)
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
}

struct QuotaGuardInstaller {
    let files: QuotaGuardFiles
    let codexHome: URL
    var config: URL { codexHome.appendingPathComponent("hooks.json") }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    var command: String { Self.quote(files.helper.path) + " --quota-hook" }

    init(files: QuotaGuardFiles = QuotaGuardFiles(), codexHome: URL? = nil) {
        self.files = files
        self.codexHome = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private func configuration() throws -> [String: Any] {
        if (try? config.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw QuotaError.message("hooks.json 是符号链接，请手动配置；没有覆盖原文件")
        }
        guard FileManager.default.fileExists(atPath: config.path) else { return [:] }
        let data = try Data(contentsOf: config)
        guard data.count < 1_048_576,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.message("现有 hooks.json 无法解析，没有覆盖原配置")
        }
        return value
    }

    func isInstalled() -> Bool {
        guard let value = try? configuration(), let hooks = value["hooks"] as? [String: Any],
              let groups = hooks["PostToolUse"] as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
        } && FileManager.default.isExecutableFile(atPath: files.helper.path)
    }

    func install(executable: URL) throws {
        var value = try configuration()
        if value["hooks"] != nil && !(value["hooks"] is [String: Any]) {
            throw QuotaError.message("现有 hooks 配置格式不兼容，没有覆盖原配置")
        }
        var hooks = value["hooks"] as? [String: Any] ?? [:]
        if hooks["PostToolUse"] != nil && !(hooks["PostToolUse"] is [[String: Any]]) {
            throw QuotaError.message("PostToolUse 配置格式不兼容，没有覆盖原配置")
        }
        var groups = hooks["PostToolUse"] as? [[String: Any]] ?? []
        let installed = groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { $0["command"] as? String == command }
        }
        try files.prepare()
        let binary = try Data(contentsOf: executable)
        try binary.write(to: files.helper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: files.helper.path)
        if installed { return }
        groups.append(["matcher": "*", "hooks": [["type": "command", "command": command,
            "timeout": 3, "additionalContextLimit": 800,
            "statusMessage": "检查本地 Codex 额度保护"]]])
        hooks["PostToolUse"] = groups
        value["hooks"] = hooks
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: config.path) {
            let backup = codexHome.appendingPathComponent("hooks.quota-bar-backup-" + UUID().uuidString + ".json")
            try FileManager.default.copyItem(at: config, to: backup)
        }
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: config, options: .atomic)
    }

    func remove() throws {
        var value = try configuration()
        guard var hooks = value["hooks"] as? [String: Any],
              let groups = hooks["PostToolUse"] as? [[String: Any]] else { return }
        var changed = false
        let retained: [[String: Any]] = groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let keep = handlers.filter { $0["command"] as? String != command }
            if keep.count == handlers.count { return group }
            changed = true
            guard !keep.isEmpty else { return nil }
            var result = group; result["hooks"] = keep; return result
        }
        guard changed else { return }
        hooks["PostToolUse"] = retained
        value["hooks"] = hooks
        let backup = codexHome.appendingPathComponent("hooks.quota-bar-backup-" + UUID().uuidString + ".json")
        try FileManager.default.copyItem(at: config, to: backup)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: config, options: .atomic)
    }

    func reviewLauncher(cli: URL) throws -> URL {
        try files.prepare()
        let directory = files.root.appendingPathComponent("hook-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let script = files.root.appendingPathComponent("review-hooks.command")
        let text = """
        #!/bin/zsh
        printf '%s\\n' '请在 Codex 界面中输入 /hooks，审查并信任包含 quota-hook 的 PostToolUse 条目。完成后可退出这个终端会话；这里不会自动发送模型请求。'
        cd \(Self.quote(directory.path)) || exit 1
        exec \(Self.quote(cli.path))

        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}
