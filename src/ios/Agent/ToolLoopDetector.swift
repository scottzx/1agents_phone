import Foundation
import CryptoKit

private let logger = AppLogger(category: "ToolLoopDetector")

// MARK: - Public types

struct ToolCallRecord {
    let toolName: String
    let argsHash: String
    var resultHash: String?
    let unknownToolName: String?
    let toolCallId: String?
    let timestamp: TimeInterval
}

enum LoopLevel: Equatable {
    case none
    case warning
    case critical
}

struct LoopCheckResult: Equatable {
    let level: LoopLevel
    let message: String?
    let warningKey: String?

    static let pass = LoopCheckResult(level: .none, message: nil, warningKey: nil)
}

struct ToolLoopConfig {
    var historySize: Int
    var warningThreshold: Int
    var unknownToolThreshold: Int
    var criticalThreshold: Int
    var globalCircuitBreakerThreshold: Int

    init(
        historySize: Int = 30,
        warningThreshold: Int = 10,
        unknownToolThreshold: Int = 10,
        criticalThreshold: Int = 20,
        globalCircuitBreakerThreshold: Int = 30
    ) {
        // Auto-correct ordering so warning < critical < globalCircuitBreaker.
        let w = max(1, warningThreshold)
        let c = max(w + 1, criticalThreshold)
        let g = max(c + 1, globalCircuitBreakerThreshold)
        // Ensure history window is large enough to hold the highest threshold.
        let h = max(historySize, g)
        self.warningThreshold = w
        self.criticalThreshold = c
        self.globalCircuitBreakerThreshold = g
        self.unknownToolThreshold = max(1, unknownToolThreshold)
        self.historySize = h
    }
}

// MARK: - Detector

final class ToolLoopDetector {
    private let config: ToolLoopConfig
    private var history: [ToolCallRecord] = []
    /// Map<warningKey, lastBucket> — used to throttle repeated warnings to once per N triggers.
    private var warningBuckets: [String: Int] = [:]
    private let lock = NSLock()

    init(config: ToolLoopConfig = ToolLoopConfig()) {
        self.config = config
    }

    /// Called BEFORE tool execution. Returns critical when execution must be blocked.
    /// Caller must short-circuit on `.critical` and inject the message as the tool result.
    func check(toolName: String, params: [String: Any]) -> LoopCheckResult {
        lock.lock()
        defer { lock.unlock() }

        let argsHash = argsHashFor(toolName, params)

        // Every threshold below counts the call that is ABOUT TO FIRE, not the
        // ones already in history: `check` runs before execution, so a
        // threshold of N means "the Nth identical call is the one we block".
        // Both streak helpers return raw history counts and every comparison
        // here adds the upcoming call — previously `countUnknownStreakFromTail`
        // baked the +1 in while `getNoProgressStreak` did not, so the same
        // configured number meant "block the 10th" for one strategy and "block
        // the 21st" for another.

        // Strategy 1: unknown_tool_repeat — highest priority.
        let upcomingUnknown = countUnknownStreakFromTail(toolName: toolName) + 1
        if upcomingUnknown >= config.unknownToolThreshold {
            let msg = "[LOOP BLOCKED] CRITICAL: attempted unavailable tool '\(toolName)' \(upcomingUnknown) times. Stop retrying that missing tool and answer without it."
            logger.error("loop-detector: unknown_tool_repeat critical tool=\(toolName) streak=\(upcomingUnknown)")
            return LoopCheckResult(level: .critical, message: msg, warningKey: nil)
        }

        // Strategy 2: global_circuit_breaker — backstop, runs before poll-specific check.
        let upcomingNoProgress = getNoProgressStreak(toolName: toolName, argsHash: argsHash) + 1
        if upcomingNoProgress >= config.globalCircuitBreakerThreshold {
            let msg = "[LOOP BLOCKED] CRITICAL: \(toolName) has repeated identical no-progress outcomes \(upcomingNoProgress) times. Session execution blocked by global circuit breaker."
            logger.error("loop-detector: global_circuit_breaker critical tool=\(toolName) streak=\(upcomingNoProgress)")
            return LoopCheckResult(level: .critical, message: msg, warningKey: nil)
        }

        // Strategy 3: known_poll_no_progress.
        if isPollTool(toolName, params), upcomingNoProgress >= config.criticalThreshold {
            let msg = "[LOOP BLOCKED] CRITICAL: Called \(toolName) \(upcomingNoProgress) times with identical no-progress results. Session execution blocked."
            logger.error("loop-detector: poll_no_progress critical tool=\(toolName) streak=\(upcomingNoProgress)")
            return LoopCheckResult(level: .critical, message: msg, warningKey: nil)
        }

        // No warning is raised here, by design. `check` decides whether to BLOCK;
        // warnings are advisory text that has to reach the model, and the only
        // way it does that is `record`, which appends the message to the tool
        // result. A warning returned from here was dead — the sole caller acts
        // on `.critical` alone — and worse, it consumed that warning's throttle
        // bucket (`shouldEmitWarning` fires once per bucket of
        // `warningThreshold`), silencing the `record` call that would actually
        // have shown it. That is why a model could loop past the threshold and
        // never see a single warning.
        return .pass
    }

    /// Called AFTER tool execution. Records the call and back-fills resultHash.
    /// Returns a warning result when post-hoc state crossed a warning threshold —
    /// caller should append `result.message` to the tool output for the model to see.
    @discardableResult
    func record(
        toolName: String,
        params: [String: Any],
        result: String?,
        errorMessage: String? = nil,
        toolCallId: String? = nil
    ) -> LoopCheckResult {
        lock.lock()
        defer { lock.unlock() }

        let argsHash = argsHashFor(toolName, params)
        let resultHash = resultHashFor(result: result, errorMessage: errorMessage)
        let unknown = extractUnknownToolName(errorMessage: errorMessage)

        let record = ToolCallRecord(
            toolName: toolName,
            argsHash: argsHash,
            resultHash: resultHash,
            unknownToolName: unknown,
            toolCallId: toolCallId,
            timestamp: Date().timeIntervalSince1970
        )
        appendHistory(record)

        // Re-evaluate post-hoc: if generic_repeat / poll_no_progress threshold is now hit,
        // surface a warning so the caller can append it to this tool's result.
        if isPollTool(toolName, params) {
            let streak = getNoProgressStreak(toolName: toolName, argsHash: argsHash)
            if streak >= config.warningThreshold && streak < config.criticalThreshold {
                let key = "poll:\(toolName):\(argsHash)"
                if shouldEmitWarning(warningKey: key, currentCount: streak) {
                    let msg = "[LOOP WARNING] You have called \(toolName) \(streak) times with no progress. Stop polling and either (1) increase wait time, or (2) report the task as failed."
                    return LoopCheckResult(level: .warning, message: msg, warningKey: key)
                }
            }
        } else {
            let totalCount = history.reduce(0) { acc, r in
                (r.toolName == toolName && r.argsHash == argsHash) ? acc + 1 : acc
            }
            if totalCount >= config.warningThreshold {
                let key = "repeat:\(toolName):\(argsHash)"
                if shouldEmitWarning(warningKey: key, currentCount: totalCount) {
                    let msg = "[LOOP WARNING] You have called \(toolName) \(totalCount) times with identical arguments. If this is not making progress, stop retrying and report the task as failed."
                    return LoopCheckResult(level: .warning, message: msg, warningKey: key)
                }
            }
        }

        return .pass
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        history.removeAll()
        warningBuckets.removeAll()
    }

    /// Test-only inspection. Not part of production callers.
    func _historySnapshot() -> [ToolCallRecord] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }

    // MARK: - Private helpers

    private func appendHistory(_ r: ToolCallRecord) {
        history.append(r)
        if history.count > config.historySize {
            history.removeFirst(history.count - config.historySize)
        }
    }

    /// Throttle: emit a warning once per `warningThreshold` increments of currentCount.
    /// Returns true if this call should emit; updates the bucket pointer.
    private func shouldEmitWarning(warningKey: String, currentCount: Int) -> Bool {
        let bucket = currentCount / config.warningThreshold
        if let last = warningBuckets[warningKey], last >= bucket { return false }
        warningBuckets[warningKey] = bucket
        return true
    }

    /// Stable JSON serialization with sorted keys (recursively).
    private func stableJson(_ value: Any) -> String {
        let normalized = normalizeForStableJson(value)
        guard let data = try? JSONSerialization.data(
            withJSONObject: normalized,
            options: [.sortedKeys, .fragmentsAllowed]
        ),
        let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    /// Recursively normalize so we never feed un-serializable types to JSONSerialization.
    private func normalizeForStableJson(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = normalizeForStableJson(v) }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { normalizeForStableJson($0) }
        }
        if value is NSNull { return NSNull() }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n }
        if let b = value as? Bool { return b }
        // Fallback: stringify unknown types so we still get a stable representation.
        return String(describing: value)
    }

    private func sha256(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// UI/telemetry-only fields that the model freely varies (e.g. counter-suffixed
    /// titles like "Read /etc/hostname #1") and which must NOT contribute to the
    /// args hash — otherwise identical logical calls look unique to the detector.
    private static let argsHashIgnoredKeys: Set<String> = [
        "tool_title",
    ]

    private func argsHashFor(_ toolName: String, _ params: [String: Any]) -> String {
        var filtered = params
        for k in Self.argsHashIgnoredKeys { filtered.removeValue(forKey: k) }
        return sha256("\(toolName):\(stableJson(filtered))")
    }

    /// Hash only the "did the world change" facets of a tool's outcome.
    /// We strip volatile fields (timestamps, request IDs, elapsed, durations)
    /// before hashing so that genuinely identical outcomes collapse to one hash.
    private func resultHashFor(result: String?, errorMessage: String?) -> String {
        if let err = errorMessage, !err.isEmpty {
            return sha256("ERR:\(stripVolatile(err))")
        }
        let payload = result ?? ""
        return sha256("OK:\(stripVolatile(payload))")
    }

    private func stripVolatile(_ s: String) -> String {
        var out = s
        // Drop ISO 8601 timestamps: 2025-01-02T03:04:05(.123)?(Z|±HH:MM)?
        out = out.replacingOccurrences(
            of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?"#,
            with: "<TS>",
            options: .regularExpression
        )
        // Drop "elapsed: 1.234s" / "duration=1.2s" / "took 12ms" patterns.
        out = out.replacingOccurrences(
            of: #"(?i)\b(elapsed|duration|took)\b[^\d]{0,4}\d+(\.\d+)?\s?(ms|s)\b"#,
            with: "<DUR>",
            options: .regularExpression
        )
        // Drop request id / call id style noise.
        out = out.replacingOccurrences(
            of: #"(?i)\b(request[_-]?id|call[_-]?id|trace[_-]?id)["']?\s*[:=]\s*["']?[A-Za-z0-9_-]+["']?"#,
            with: "<ID>",
            options: .regularExpression
        )
        // Collapse whitespace runs so cosmetic re-flows don't change the hash.
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractUnknownToolName(errorMessage: String?) -> String? {
        guard let msg = errorMessage, !msg.isEmpty else { return nil }
        let patterns = [
            #"unknown tool[:\s]+["']?([a-zA-Z0-9_.-]+)["']?"#,
            #"tool\s+["']?([a-zA-Z0-9_.-]+)["']?\s+(?:not found|is not available)"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(msg.startIndex..., in: msg)
                if let m = regex.firstMatch(in: msg, options: [], range: range),
                   m.numberOfRanges >= 2,
                   let r = Range(m.range(at: 1), in: msg) {
                    return String(msg[r])
                }
            }
        }
        return nil
    }

    private func isPollTool(_ toolName: String, _ params: [String: Any]) -> Bool {
        if toolName == "command_status" { return true }
        if toolName == "process" {
            if let action = params["action"] as? String,
               action == "poll" || action == "log" {
                return true
            }
        }
        return false
    }

    /// Walk the history backwards. For records that match (toolName, argsHash),
    /// require `resultHash` to be identical and non-nil — once it changes, stop.
    /// Records of unrelated tools are skipped (they neither contribute nor reset).
    private func getNoProgressStreak(toolName: String, argsHash: String) -> Int {
        var streak = 0
        var pinnedHash: String?
        for rec in history.reversed() {
            guard rec.toolName == toolName, rec.argsHash == argsHash else { continue }
            guard let rh = rec.resultHash else {
                // Missing resultHash means we cannot prove no-progress; stop here.
                break
            }
            if let pinned = pinnedHash {
                if rh != pinned { break }
            } else {
                pinnedHash = rh
            }
            streak += 1
        }
        // Raw history count: how many identical no-progress outcomes are ALREADY
        // recorded. `record` wants exactly this (it counts what has happened);
        // `check` adds one for the call it is about to admit.
        return streak
    }

    /// Walk history backwards; count contiguous unknown-tool errors for `toolName`.
    /// We rely on the historical record's `unknownToolName` matching `toolName`.
    ///
    /// Raw history count, like `getNoProgressStreak` — the "+1 for the call about
    /// to fire" belongs to `check`, which is the only thing that models an
    /// upcoming call. It used to be added here instead, which is what made the
    /// two counters disagree about what a configured threshold meant.
    private func countUnknownStreakFromTail(toolName: String) -> Int {
        var streak = 0
        for rec in history.reversed() {
            guard let unknown = rec.unknownToolName, unknown == toolName,
                  rec.toolName == toolName else { break }
            streak += 1
        }
        return streak
    }
}
