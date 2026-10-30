import Foundation
import CoreGraphics

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: " + name) }
}

let now = Date(timeIntervalSince1970: 1700000000)
let weekly: [String: Any] = ["usedPercent": 31, "windowDurationMins": 10080,
                           "resetsAt": now.addingTimeInterval(6 * 86400 + 15 * 3600).timeIntervalSince1970]
let q = QuotaWindow(weekly)
check(q.remaining == 69, "usage converts to remaining")
check(q.label == "周剩余", "weekly label")
check(q.compactLabel == "周", "compact weekly label")
check(QuotaWindow(["windowDurationMins": 300]).compactLabel == "5h", "compact five-hour label")
check(q.countdown(now: now) == "6天15小时", "days and hours")
check(QuotaWindow(["usedPercent": 1]).remaining == 99, "numeric one is not a boolean")
check(QuotaWindow(["usedPercent": true]).remaining == nil, "boolean is invalid")
check(QuotaWindow(["usedPercent": 140]).remaining == 0, "upper clamp")
check(QuotaWindow(["usedPercent": -4]).remaining == 100, "lower clamp")
check(QuotaWindow([:]).percentage == "未知", "missing usage never becomes full")
check(QuotaWindow(["resetsAt": 1700000030]).countdown(now: now) == "1分钟", "sub-minute rounds up")
check(QuotaWindow(["resetsAt": 1699999999]).countdown(now: now) == "等待重置", "expired quota does not reset locally")
check(QuotaWindow(["resetsAt": 1700000000]).resetText == "11/15 06:13", "Beijing reset date")
let snapshot = QuotaSnapshot(["rateLimitsByLimitId": ["other": ["primary": weekly],
                                                     "codex": ["secondary": weekly]]])
check(snapshot.selected(nil) == "codex", "prefer Codex bucket")
check(snapshot.selected("other") == "other", "respect user's bucket")
check(snapshot.windows("codex").count == 1, "no fabricated primary window")
check(QuotaSnapshot(["rateLimits": ["primary": weekly]]).windows("codex").count == 1, "legacy API fallback")
check(QuotaSnapshot([:]).windows(nil).isEmpty, "no quotas handled safely")
let dual = QuotaSnapshot(["rateLimitsByLimitId": ["codex": [
    "primary": ["usedPercent": 20, "windowDurationMins": 300],
    "secondary": ["usedPercent": 15, "windowDurationMins": 10080]
]]])
check(dual.windows("codex").map { "\($0.compactLabel) \($0.percentage)" }.joined(separator: " · ") == "5h 80% · 周 85%", "both quota windows shown with remaining percentages")
let owner = CGRect(x: -1000, y: 80, width: 800, height: 600)
let placement = RelativePlacement.frame(owner: owner, x: 0.5, y: 1, width: 360, height: 26)
check(owner.contains(placement), "manual placement stays inside negative-coordinate monitor")
let resized = RelativePlacement.frame(owner: CGRect(x: 100, y: 50, width: 250, height: 200),
                                     x: 2, y: -1, width: 360, height: 26)
check(resized == CGRect(x: 100, y: 50, width: 250, height: 26), "resize clamps width and ratios")

// User flows: pause, refresh once, close/reopen host, resume, and late replies.
var schedule = RefreshState()
check(schedule.begin(now: now) == nil, "no request without host")
check(schedule.setHost(101), "detect first host")
let first = schedule.begin(now: now)!
check(schedule.begin(now: now, manual: true) == nil, "manual refresh does not duplicate an active request")
check(schedule.finish(first), "accept current host reply")
check(schedule.begin(now: now.addingTimeInterval(59)) == nil, "normal polling waits sixty seconds")
let periodic = schedule.begin(now: now.addingTimeInterval(60))!
check(schedule.finish(periodic), "poll at sixty seconds completes")
schedule.setPaused(true)
check(schedule.begin(now: now.addingTimeInterval(120)) == nil, "pause stops automatic reads")
let single = schedule.begin(now: now.addingTimeInterval(120), manual: true)!
check(schedule.finish(single) && schedule.paused, "manual read works once while remaining paused")
check(schedule.setHost(nil), "detect host close while paused")
check(schedule.setHost(202), "detect host reopen while paused")
check(schedule.begin(now: now.addingTimeInterval(121)) == nil, "host reopen respects explicit pause")
let afterReopen = schedule.begin(now: now.addingTimeInterval(121), manual: true)!
check(schedule.finish(afterReopen), "manual read works after host reopen while paused")
schedule.setPaused(false)
let resumed = schedule.begin(now: now.addingTimeInterval(122))!
check(schedule.finish(resumed), "resume reads immediately without waiting another minute")
let oldReply = schedule.begin(now: now.addingTimeInterval(182))!
_ = schedule.setHost(nil)
_ = schedule.setHost(303)
let currentReply = schedule.begin(now: now.addingTimeInterval(183))!
check(!schedule.finish(oldReply), "ignore late result from old host")
check(schedule.begin(now: now.addingTimeInterval(184)) == nil, "late reply does not clear new host's in-flight request")
check(schedule.finish(currentReply), "new host reply completes normally")
check(!schedule.setHost(303), "same running host does not reset polling interval")

// Quota protection: local state + real hook wire format, never a live AI task.
let timestamp = now.timeIntervalSince1970
let event: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "test-session-a"]
func guardState(_ remaining: Double? = 15, enabled: Bool = true, threshold: Int = 15,
                age: Double = 0, reset: Double? = nil) -> QuotaGuardState {
    QuotaGuardState(enabled: enabled, threshold: threshold, updatedAt: timestamp - age,
                    remaining: remaining, resetsAt: reset ?? timestamp + 3600)
}
func guardOutput(_ state: QuotaGuardState, input: [String: Any] = event) -> [String: Any]? {
    var ledger = QuotaGuardLedger()
    return QuotaGuardPolicy.evaluate(input: input, state: state, ledger: &ledger, now: timestamp)
}
check(guardOutput(guardState(16)) == nil, "above threshold stays silent")
check(guardOutput(guardState())?["hookSpecificOutput"] != nil, "exactly fifteen percent emits supported hook context")
check(guardOutput(guardState(20, threshold: 20)) != nil, "custom threshold is respected")
check(guardOutput(guardState(16, threshold: 10)) == nil, "lower threshold does not trigger early")
check(guardOutput(guardState(enabled: false)) == nil, "disabled or paused protection stays silent")
check(guardOutput(guardState(age: 181)) == nil, "stale monitor state cannot trigger")
check(guardOutput(guardState(age: -6)) == nil, "future-dated monitor state cannot trigger")
check(guardOutput(guardState(reset: timestamp)) == nil, "expired window cannot trigger")
check(guardOutput(guardState(nil)) == nil, "missing quota never means zero")
check(guardOutput(guardState(-1)) == nil && guardOutput(guardState(101)) == nil, "invalid remaining range cannot trigger")
check(guardOutput(guardState(threshold: 0)) == nil && guardOutput(guardState(threshold: 91)) == nil, "invalid thresholds rejected")
check(QuotaGuardState.validThreshold(1) && QuotaGuardState.validThreshold(90), "custom threshold bounds supported")
check(guardOutput(guardState(), input: ["hook_event_name": "SessionStart", "session_id": "test"]) == nil, "does not wake idle sessions")
check(guardOutput(guardState(), input: ["hook_event_name": "PostToolUse"]) == nil, "missing session ID stays silent")
var delivery = QuotaGuardLedger()
check(QuotaGuardPolicy.evaluate(input: event, state: guardState(), ledger: &delivery, now: timestamp) != nil, "first session delivery")
check(QuotaGuardPolicy.evaluate(input: event, state: guardState(10), ledger: &delivery, now: timestamp) == nil, "same session/window never receives repeated prompts")
let otherEvent: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "test-session-b"]
check(QuotaGuardPolicy.evaluate(input: otherEvent, state: guardState(10), ledger: &delivery, now: timestamp) == nil, "another session cannot repeat the window's prompt")
check(!delivery.sessions.keys.contains("test-session-a"), "receipt stores only hashed session IDs")
check(QuotaGuardPolicy.evaluate(input: event, state: guardState(1, threshold: 30), ledger: &delivery, now: timestamp) == nil, "changing threshold after notification cannot repeat prompt")
check(QuotaGuardPolicy.evaluate(input: event, state: guardState(enabled: false), ledger: &delivery, now: timestamp) == nil, "disable preserves current notification")
check(QuotaGuardPolicy.evaluate(input: otherEvent, state: guardState(), ledger: &delivery, now: timestamp) == nil, "re-enable preserves notification across sessions")
check(QuotaGuardPolicy.evaluate(input: event, state: guardState(reset: timestamp+3601), ledger: &delivery, now: timestamp) == nil, "reset timestamp correction does not rearm window")
check(delivery.windowReset == timestamp+3601, "reset extension is remembered")
check(QuotaGuardPolicy.evaluate(input: otherEvent, state: guardState(reset: timestamp+3599), ledger: &delivery, now: timestamp) == nil, "reset moving backwards does not rearm window")
check(delivery.windowReset == timestamp+3601, "reset correction never shortens notification suppression")
let nextTime = timestamp+3602
let nextState = QuotaGuardState(enabled: true, threshold: 15, updatedAt: nextTime,
                                remaining: 10, resetsAt: timestamp+21600)
check(QuotaGuardPolicy.evaluate(input: event, state: nextState, ledger: &delivery, now: nextTime) != nil, "fresh next-window quota rearms protection after actual boundary")
check(QuotaGuardPolicy.evaluate(input: otherEvent, state: nextState, ledger: &delivery, now: nextTime) == nil, "next window still permits only one prompt across sessions")
let context = (guardOutput(guardState())?["hookSpecificOutput"] as? [String: Any])?["additionalContext"] as? String ?? ""
check(context.contains("只适用于触发时正在处理的这一轮") && context.contains("不要仅因这条历史提示再次保存并停止"), "prompt explicitly allows future user-directed continuation")
let legacyData = try JSONSerialization.data(withJSONObject: ["windowReset": timestamp+3600,
    "sessions": ["legacy-session-hash": timestamp], "lastCheckAt": timestamp, "lastSentAt": timestamp])
var legacyDelivery = try JSONDecoder().decode(QuotaGuardLedger.self, from: legacyData)
check(QuotaGuardPolicy.evaluate(input: otherEvent, state: guardState(), ledger: &legacyDelivery, now: timestamp) == nil, "v1.1.0 receipt suppresses new sessions after upgrade")
var legacySessionOnly = QuotaGuardLedger(windowReset: timestamp+3600, sessions: ["legacy": timestamp])
check(QuotaGuardPolicy.evaluate(input: otherEvent, state: guardState(), ledger: &legacySessionOnly, now: timestamp) == nil, "legacy session receipt works even without lastSentAt")
var boundaryLedger = try JSONDecoder().decode(QuotaGuardLedger.self, from: legacyData)
let beforeBoundary = QuotaGuardState(enabled: true, threshold: 15, updatedAt: timestamp+3599,
                                     remaining: 10, resetsAt: timestamp+21600)
check(QuotaGuardPolicy.evaluate(input: event, state: beforeBoundary, ledger: &boundaryLedger, now: timestamp+3601) == nil, "cached pre-boundary quota cannot rearm protection")
check(QuotaGuardPolicy.evaluate(input: event, state: nextState, ledger: &boundaryLedger, now: nextTime) != nil, "fresh post-boundary snapshot can notify")
let exported = QuotaGuardState(enabled: true, threshold: 15, snapshot: dual)
check(exported.remaining == 80, "monitor exports five-hour remaining, not weekly remaining")
check(QuotaGuardState(enabled: true, threshold: 15, snapshot: snapshot).remaining == nil, "weekly-only snapshots do not trigger five-hour protection")
let unrelated = QuotaSnapshot(["rateLimitsByLimitId": ["other": ["primary": ["usedPercent": 99, "windowDurationMins": 300]]]])
check(QuotaGuardState(enabled: true, threshold: 15, snapshot: unrelated).remaining == nil, "unrelated quota buckets ignored")
let protectionTemp = FileManager.default.temporaryDirectory.appendingPathComponent("quota-guard-test-"+UUID().uuidString)
try FileManager.default.createDirectory(at: protectionTemp, withIntermediateDirectories: true)
let largeInput = protectionTemp.appendingPathComponent("large-input.json")
var largeEvent = event
largeEvent["tool_response"] = String(repeating: "x", count: 150000)
try JSONSerialization.data(withJSONObject: largeEvent).write(to: largeInput)
let largeHandle = try FileHandle(forReadingFrom: largeInput)
check(QuotaGuardFiles.readInput(largeHandle)?["session_id"] as? String == "test-session-a", "multi-chunk tool result is fully parsed")
try largeHandle.close()
try Data(repeating: 120, count: 1_048_577).write(to: largeInput)
let oversizedHandle = try FileHandle(forReadingFrom: largeInput)
check(QuotaGuardFiles.readInput(oversizedHandle) == nil, "oversized hook input fails silently")
try oversizedHandle.close()
let protectionFiles = QuotaGuardFiles(root: protectionTemp.appendingPathComponent("support"))
try protectionFiles.publish(guardState())
check(protectionFiles.handle(event, now: timestamp) != nil, "hook file path delivers once")
check(QuotaGuardFiles(root: protectionFiles.root).handle(event, now: timestamp) == nil, "delivery survives monitor/helper restarts")
check(QuotaGuardFiles(root: protectionFiles.root).handle(otherEvent, now: timestamp) == nil, "new session after helper restart stays silent")
check(protectionFiles.receipt()?.lastSentAt == timestamp, "records delivery time without claiming checkpoint success")
try protectionFiles.publish(guardState(reset: timestamp+3601))
check(protectionFiles.handle(otherEvent, now: timestamp+1) == nil, "silent reset correction stays silent on disk path")
check(protectionFiles.receipt()?.windowReset == timestamp+3601, "silent reset correction persists immediately")
check(QuotaGuardFiles(root: protectionFiles.root).handle(otherEvent, now: timestamp+2) == nil, "persisted reset correction survives restart")
try protectionFiles.publish(guardState(enabled: false))
check(protectionFiles.handle(otherEvent, now: timestamp) == nil, "turning protection off takes effect on the next tool boundary")
try Data("invalid".utf8).write(to: protectionFiles.state)
check(protectionFiles.handle(otherEvent, now: timestamp) == nil, "invalid state fails silently")
try protectionFiles.publish(guardState())
try Data("invalid".utf8).write(to: protectionFiles.ledger)
check(protectionFiles.handle(otherEvent, now: timestamp) == nil, "corrupt receipts do not cause duplicate prompting")
let concurrentFiles = QuotaGuardFiles(root: protectionTemp.appendingPathComponent("concurrent"))
try concurrentFiles.publish(guardState())
let countLock = NSLock()
var outputCount = 0
DispatchQueue.concurrentPerform(iterations: 12) { index in
    let concurrentEvent: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "parallel-session-\(index)"]
    if concurrentFiles.handle(concurrentEvent, now: timestamp) != nil {
        countLock.lock(); outputCount += 1; countLock.unlock()
    }
}
check(outputCount == 1, "parallel completions from different sessions emit at most one prompt")
let fakeHome = protectionTemp.appendingPathComponent("codex")
try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
let originalHook: [String: Any] = ["description": "Existing user hooks", "hooks": ["PostToolUse": [["hooks": [["type": "command", "command": "echo existing"]]]]]]
let originalData = try JSONSerialization.data(withJSONObject: originalHook)
let configFile = fakeHome.appendingPathComponent("hooks.json")
try originalData.write(to: configFile)
let fakeExecutable = protectionTemp.appendingPathComponent("fake-executable")
try Data("not executed by tests".utf8).write(to: fakeExecutable)
let installerFiles = QuotaGuardFiles(root: protectionTemp.appendingPathComponent("installer"))
let installer = QuotaGuardInstaller(files: installerFiles, codexHome: fakeHome)
try installer.install(executable: fakeExecutable)
check(installer.isInstalled(), "installer creates executable helper and hook definition")
let merged = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as! [String: Any]
let mergedGroups = (merged["hooks"] as! [String: Any])["PostToolUse"] as! [[String: Any]]
check(mergedGroups.count == 2 && merged["description"] as? String == "Existing user hooks", "installer preserves existing hooks and metadata")
let backups = try FileManager.default.contentsOfDirectory(at: fakeHome, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("hooks.quota-bar-backup-") }
let backupData = try backups.first.map { try Data(contentsOf: $0) }
check(backups.count == 1 && backupData == originalData, "installer backs up original config byte-for-byte")
try installerFiles.publish(guardState())
_ = installerFiles.handle(event, now: timestamp)
let upgradeReceipt = try Data(contentsOf: installerFiles.ledger)
let installedData = try Data(contentsOf: configFile)
try installer.install(executable: fakeExecutable)
let reinstalledData = try Data(contentsOf: configFile)
check(reinstalledData == installedData, "reinstall does not duplicate or rewrite hook definition")
let receiptAfterUpgrade = try Data(contentsOf: installerFiles.ledger)
check(receiptAfterUpgrade == upgradeReceipt && installerFiles.handle(otherEvent, now: timestamp) == nil, "helper upgrade preserves receipts and suppresses another session")
let launcher = try installer.reviewLauncher(cli: fakeExecutable)
let shellCheck = Process()
shellCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
shellCheck.arguments = ["-n", launcher.path]
try shellCheck.run(); shellCheck.waitUntilExit()
check(shellCheck.terminationStatus == 0, "review launcher shell syntax is valid without launching CLI")
try installer.remove()
check(!installer.isInstalled(), "remove disconnects only the quota guard hook")
let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: configFile)) as! [String: Any]
let survivingGroups = (removed["hooks"] as! [String: Any])["PostToolUse"] as! [[String: Any]]
check(survivingGroups.count == 1 && (survivingGroups[0]["hooks"] as! [[String: Any]])[0]["command"] as? String == "echo existing", "remove preserves other user hooks")
let invalidHome = protectionTemp.appendingPathComponent("invalid-home")
try FileManager.default.createDirectory(at: invalidHome, withIntermediateDirectories: true)
let invalidConfig = invalidHome.appendingPathComponent("hooks.json")
try Data("broken user config".utf8).write(to: invalidConfig)
var refused = false
do { try QuotaGuardInstaller(files: installerFiles, codexHome: invalidHome).install(executable: fakeExecutable) }
catch { refused = true }
let preservedInvalidData = try Data(contentsOf: invalidConfig)
check(refused && preservedInvalidData == Data("broken user config".utf8), "invalid existing config is never overwritten")

// Real stdio lifecycle against a fake local server; no credentials or network.
// Kept in a fresh temp directory; no batch deletion is performed.
let temp = FileManager.default.temporaryDirectory.appendingPathComponent("quota-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
let fake = temp.appendingPathComponent("codex")
let script = """
#!/usr/bin/env python3
import json, sys
initialized = False
for line in sys.stdin:
    message = json.loads(line)
    method = message['method']
    if method == 'initialized':
        initialized = True
        continue
    if method == 'initialize':
        result = {}
    elif method == 'account/rateLimits/read' and initialized:
        result = {'rateLimits': {'primary': {'usedPercent': 25, 'windowDurationMins': 10080}}}
    else:
        print(json.dumps({'id': message['id'], 'error': {'message': 'unexpected method'}}), flush=True)
        continue
    print(json.dumps({'method': 'ignore/notification'}), flush=True)
    print(json.dumps({'id': message['id'], 'result': result}), flush=True)
"""
try script.write(to: fake, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
let server = try AppServer(executable: fake)
let read = try server.read()
check(read.windows("codex").first?.remaining == 75, "initialize, initialized, read protocol")
let second = try server.read()
check(second.windows("codex").count == 1, "persistent server supports repeat reads")
server.close()
print("PASS: \(checks) checks")
