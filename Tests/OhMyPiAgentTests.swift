// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum OhMyPiAgentTests {
    private final class Log {
        let now = AgentTimestamp.parse("2026-09-27T15:10:00Z")!
        var state = AgentLogState()
        let store = AgentUsageStore()

        init() {
            store.reportsTransitions = true
            feed(#"{"type": "session", "version": 3, "id": "demo-session", "timestamp": "2026-09-27T15:00:00.000Z", "cwd": "/Users/me/rice/cycling"}"#)
        }

        private func stamp(_ seconds: TimeInterval) -> String {
            let date = now.addingTimeInterval(seconds)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }

        @discardableResult
        func feed(_ line: String) -> [AgentUsageEvent] {
            store.apply(AgentLogParser.parseOhMyPi(Data(line.utf8), state: &state, now: now),
                        file: "demo.jsonl", provider: .omp, tracksTurns: true, modified: now, now: now)
        }

        @discardableResult
        func user(at seconds: TimeInterval) -> [AgentUsageEvent] {
            feed(#"{"type": "message", "id": "u\#(Int(seconds))", "timestamp": "\#(stamp(seconds))", "message": {"role": "user", "content": [{"type": "text", "text": "work"}], "timestamp": 0}}"#)
        }

        @discardableResult
        func assistant(id: String, at seconds: TimeInterval, stop: String = "stop",
                       model: String = "omp-test-model", cost: Double = 0.25,
                       input: Int = 10, output: Int = 5, cacheWrite: Int = 1, longCacheWrite: Int = 0) -> [AgentUsageEvent] {
            let cttl = longCacheWrite > 0 ? #", "cttl": {"ephemeral1h": \#(longCacheWrite)}"# : ""
            return feed(#"{"type": "message", "id": "\#(id)", "timestamp": "\#(stamp(seconds))", "message": {"role": "assistant", "model": "\#(model)", "provider": "test", "usage": {"input": \#(input), "output": \#(output), "cacheRead": 2, "cacheWrite": \#(cacheWrite)\#(cttl), "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": \#(cost)}}, "stopReason": "\#(stop)"}}"#)
        }

        @discardableResult
        func modelUsage(id: String, at seconds: TimeInterval, model: String = "omp-test-model", cost: Double = 0.05) -> [AgentUsageEvent] {
            feed(#"{"type": "model_usage", "id": "\#(id)", "timestamp": "\#(stamp(seconds))", "purpose": "title", "provider": "test", "model": "\#(model)", "usage": {"input": 4, "output": 2, "cacheRead": 0, "cacheWrite": 0, "cost": {"total": \#(cost)}}, "stopReason": "stop"}"#)
        }
    }

    static func run(_ suite: TestSuite) {
        turns(suite)
        costs(suite)
        auxiliary(suite)
        projects(suite)
        files(suite)
    }

    private static func turns(_ suite: TestSuite) {
        let log = Log()
        _ = log.user(at: -120)
        suite.expect(log.store.live.count == 1 && log.store.live.first?.provider == .omp,
                     "an Oh My Pi prompt opens its turn")
        _ = log.assistant(id: "a1", at: -100, stop: "toolUse")
        suite.expect(log.store.live.count == 1 && log.store.records.count == 1,
                     "a reply that called tools counts and keeps the turn going")
        let finished = log.assistant(id: "a2", at: -60)
        suite.expect(log.store.live.isEmpty && log.store.records.count == 2
                        && finished == [.finished(provider: .omp, duration: 60, cost: 0.5,
                                                  tokens: 36, project: "cycling")],
                     "a reply that stopped ends the turn and reports what it used")
        let record = log.store.records.first
        suite.expect(record?.provider == .omp && record?.model == "omp-test-model"
                        && record?.project == "cycling" && record?.session == "demo-session"
                        && record?.tokens == AgentTokens(input: 10, cacheWrite: 1, cacheRead: 2, output: 5),
                     "an Oh My Pi reply keeps its model, project, session and counters")

        let failed = Log()
        _ = failed.user(at: -30)
        let failure = failed.assistant(id: "a1", at: -10, stop: "error")
        suite.expect(failed.store.live.isEmpty && failure.isEmpty,
                     "a failed reply ends its turn without a finish to report")

        // A prompt typed while a turn is still open keeps that turn.
        let resumed = Log()
        _ = resumed.user(at: -120)
        _ = resumed.assistant(id: "a1", at: -100, stop: "toolUse")
        _ = resumed.user(at: -60)
        suite.expect(resumed.store.live.count == 1
                        && resumed.store.live.first?.started == resumed.now.addingTimeInterval(-120),
                     "a prompt inside an open turn leaves the turn it found")
    }

    private static func costs(_ suite: TestSuite) {
        let log = Log()
        _ = log.user(at: -120)
        _ = log.assistant(id: "a1", at: -100)
        suite.expect(log.store.records.first?.cost == 0.25 && log.store.records.first?.reportedCost == true,
                     "a model the price list does not know keeps the cost Oh My Pi recorded")

        let local = Log()
        _ = local.user(at: -120)
        _ = local.assistant(id: "a1", at: -100, cost: 0)
        suite.expect(local.store.records.first?.cost == 0 && local.store.records.first?.reportedCost == false,
                     "a local model that recorded no cost stays an estimate of zero")

        // Cache kept for an hour bills at the long rate, as Oh My Pi records it.
        let cached = Log()
        _ = cached.user(at: -120)
        _ = cached.assistant(id: "a1", at: -100, model: "claude-sonnet-4-6", cost: 9,
                             longCacheWrite: 1)
        let expected = (10 * 3.0 + 1 * 6.0 + 2 * 0.3 + 5 * 15.0) / 1_000_000
        suite.expect(cached.store.records.first.map { abs(($0.cost ?? 0) - expected) < 1e-12 } == true
                        && cached.store.records.first?.reportedCost == false,
                     "a model the list knows is priced from it, long cache writes included")
    }

    private static func auxiliary(_ suite: TestSuite) {
        let log = Log()
        _ = log.user(at: -120)
        _ = log.modelUsage(id: "m1", at: -110)
        suite.expect(log.store.records.count == 1 && log.store.live.count == 1,
                     "Oh My Pi's own model calls count without touching the turn")
        _ = log.assistant(id: "a1", at: -100)
        suite.expect(log.store.records.count == 2 && log.store.live.isEmpty,
                     "a title call neither opens nor ends the turn around it")
    }

    private static func projects(_ suite: TestSuite) {
        let log = Log()
        _ = log.user(at: -120)
        _ = log.assistant(id: "a1", at: -100)
        suite.expect(log.store.records.first?.project == "cycling",
                     "the folder a session works in names its project")
    }

    private static func files(_ suite: TestSuite) {
        let main = "/Users/me/.omp/agent/sessions/-app/2026-09-27_demo.jsonl"
        let subagent = "/Users/me/.omp/agent/sessions/-app/2026-09-27_demo/Reviewer.jsonl"
        let changes = "/Users/me/.omp/agent/sessions/-app/2026-09-27_demo/changes.jsonl"
        suite.expect(AgentLogCursor.ohMyPiParent(of: main) == nil
                        && AgentLogCursor.ohMyPiParent(of: subagent) == main,
                     "a subagent's session belongs to the session folder it sits in")
        let root = AgentLogRoot(provider: .omp, url: URL(fileURLWithPath: "/Users/me/.omp/agent/sessions", isDirectory: true))
        suite.expect(root.accepts(main) && root.accepts(subagent) && !root.accepts(changes),
                     "discovery admits sessions and their subagents, never the change log")
    }
}
