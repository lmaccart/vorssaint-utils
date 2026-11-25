// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Reads Oh My Pi session logs (~/.omp/agent/sessions). Each session is one
/// append-only file of entries; only the session header, its model changes,
/// the prompts, the replies and Oh My Pi's own small model calls are
/// decoded, and of those only counters, model names, times and the working
/// folder are kept. Replies say how they ended, so a prompt opens a turn, a
/// reply that called tools keeps it going, and a reply that stopped or
/// failed ends it.
///
/// Oh My Pi's statistics database is not read: Oh My Pi only fills it when
/// its own statistics command runs, so a session at work would not show
/// until then. The logs are written as the work happens.
struct OhMyPiReader: AgentHarnessReader {
    var provider: AgentProvider { .omp }

    func parse(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        // Every entry opens with its type; anything else in the file, tool
        // results included, never has to be decoded to be passed over.
        switch Self.entryType(line) {
        case "session":
            guard let json = AgentLogParser.object(line) else { return [] }
            if let session = json["id"] as? String, !session.isEmpty {
                state.session = AgentLogParser.native(session)
            }
            if let cwd = json["cwd"] as? String, !cwd.isEmpty {
                state.project = AgentLogParser.projectName(cwd)
            }
            return []
        case "model_change":
            guard let json = AgentLogParser.object(line),
                  let model = json["model"] as? String, !model.isEmpty else { return [] }
            state.model = AgentPricing.normalized(model)
            return []
        case "model_usage":
            // Oh My Pi's own calls, for titles and judging and the like:
            // they cost what a prompt's replies cost, but open and end no turn.
            guard let json = AgentLogParser.object(line) else { return [] }
            let model = json["model"] as? String ?? ""
            if !model.isEmpty { state.model = AgentLogParser.native(model) }
            guard let usage = ohMyPiUsage(json, usage: json["usage"] as? [String: Any],
                                          id: json["id"] as? String ?? "", state: state, now: now) else { return [] }
            return [usage]
        case "message":
            return message(line, state: &state, now: now)
        default:
            return []
        }
    }

    private func message(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        // A tool result arrives inside a turn and can be large; while a turn
        // is open, the line only has to say that work goes on.
        if AgentLogParser.contains(line, #""role": "toolResult""#) || AgentLogParser.contains(line, #""role":"toolResult""#) {
            return state.turnOpen ? [.turnActive(nil)] : []
        }
        guard let json = AgentLogParser.object(line),
              let message = json["message"] as? [String: Any],
              let role = message["role"] as? String else { return [] }
        let date = AgentLogParser.timestamp(json["timestamp"]) ?? now
        switch role {
        case "user":
            let wasOpen = state.turnOpen
            state.turnOpen = true
            return [wasOpen ? .turnActive(date) : .turnBegan(date),
                    .turnContext(model: state.model, project: state.project)]
        case "assistant":
            if let model = message["model"] as? String, !model.isEmpty {
                state.model = AgentLogParser.native(model)
            }
            var entries: [AgentLogEntry] = []
            if !state.turnOpen { entries.append(.turnBegan(date)) }
            if let usage = ohMyPiUsage(json, usage: message["usage"] as? [String: Any],
                                       id: json["id"] as? String ?? "", state: state, now: now) {
                entries.append(usage)
            }
            let stop = message["stopReason"] as? String ?? ""
            if stop == "toolUse" {
                state.turnOpen = true
                entries.append(.turnActive(date))
            } else {
                state.turnOpen = false
                entries.append(.turnEnded(date, completed: stop == "stop" || stop == "length", duration: nil))
            }
            return entries
        default:
            return state.turnOpen ? [.turnActive(nil)] : []
        }
    }

    /// The entry type an Oh My Pi line opens with, without decoding the
    /// line: its first key is always the type, written with or without a
    /// space after the colon.
    private static func entryType(_ line: Data) -> String? {
        line.withUnsafeBytes { bytes in
            guard bytes.count > 10,
                  bytes[0] == 0x7B, bytes[1] == 0x22 else { return nil }
            var index = 2
            // The key itself.
            let key = "type".utf8
            for byte in key {
                guard bytes[index] == byte else { return nil }
                index += 1
            }
            guard bytes[index] == 0x22 else { return nil }
            index += 1
            guard bytes[index] == 0x3A else { return nil }
            index += 1
            while index < bytes.count, bytes[index] == 0x20 { index += 1 }
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            index += 1
            var end = index
            while end < bytes.count, bytes[end] != 0x22, end - index < 32 { end += 1 }
            guard end < bytes.count, bytes[end] == 0x22 else { return nil }
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[index..<end]), as: UTF8.self)
        }
    }

    /// What one Oh My Pi reply used, priced from the list when it knows the
    /// model; a model the list does not know costs what Oh My Pi recorded,
    /// which already counts its cache traffic. A reply that recorded no cost
    /// stays an estimate of zero, as a local or free model's does, so a price
    /// the list learns later still applies.
    private func ohMyPiUsage(_ json: [String: Any], usage: [String: Any]?, id: String,
                             state: AgentLogState, now: Date) -> AgentLogEntry? {
        guard let usage else { return nil }
        let date = AgentLogParser.timestamp(json["timestamp"]) ?? now
        let tokens = AgentTokens(input: AgentLogParser.int(usage["input"]),
                                 cacheWrite: AgentLogParser.int(usage["cacheWrite"]),
                                 cacheRead: AgentLogParser.int(usage["cacheRead"]),
                                 output: AgentLogParser.int(usage["output"]),
                                 reasoning: AgentLogParser.int(usage["reasoningTokens"]))
        let recordedCost = ((usage["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue
        guard tokens.total > 0 || (recordedCost ?? 0) > 0 else { return nil }
        var billable = AgentBillable(tokens: tokens)
        // Oh My Pi says how much of the cache it wrote was kept for an hour.
        billable.longCacheWrite = AgentLogParser.int((usage["cttl"] as? [String: Any])?["ephemeral1h"])
        let priced = AgentPricing.cost(billable, model: state.model)
        let cost: Double?
        let isReported: Bool
        if let calculated = priced.cost {
            cost = calculated
            isReported = false
        } else if let recordedCost, recordedCost > 0 {
            cost = recordedCost
            isReported = true
        } else {
            cost = recordedCost
            isReported = false
        }
        let key = "omp:\(state.session):\(id.isEmpty ? "\(date.timeIntervalSince1970)" : id)"
        let record = AgentUsageRecord(provider: .omp, date: date, model: state.model, project: state.project,
                                      session: state.session, tokens: tokens, cost: cost, savings: priced.savings,
                                      reportedCost: isReported)
        return .usage(key: key, record: record, billable: billable)
    }
}
