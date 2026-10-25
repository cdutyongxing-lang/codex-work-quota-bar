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
