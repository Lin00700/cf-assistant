import Foundation

/// Persists only a sanitized startup summary for the containing app and VPN extension.
enum TunnelStartupFailureStore {
    static let appGroupIdentifier = "group.com.cfassistant.ios"
    private static let fileName = "last-tunnel-startup-failure.json"

    private struct Record: Codable {
        let createdAt: Date
        let message: String
    }

    static var sharedContainerAvailable: Bool {
        storageURL() != nil
    }

    static func safeSummary(for error: Error) -> String {
        let nsError = error as NSError
        return sanitize("\(nsError.domain) (code \(nsError.code)): \(error.localizedDescription)")
    }

    static func save(_ message: String) {
        let safeMessage = sanitize(message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeMessage.isEmpty, let url = storageURL() else { return }
        guard let data = try? JSONEncoder().encode(Record(createdAt: Date(), message: safeMessage)) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    static func lastMessage() -> String? {
        guard let url = storageURL(),
              let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return nil
        }
        let safeMessage = sanitize(record.message).trimmingCharacters(in: .whitespacesAndNewlines)
        return safeMessage.isEmpty ? nil : safeMessage
    }

    static func clear() {
        guard let url = storageURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func sanitize(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        // Hide complete links first; they may contain UUIDs, passwords, query tokens, and endpoints.
        value = replacing(
            #"(?i)\b[a-z][a-z0-9+.-]*://[^\s\"'<>]+"#,
            in: value,
            with: "[地址已隐藏]"
        )
        value = replacing(
            #"(?i)\b[^/\s:@]+:[^/\s@]+@"#,
            in: value,
            with: "[凭据已隐藏]@"
        )
        value = replacing(
            #"(?i)((?:proxy-)?authorization\s*:\s*)(?:(?:bearer|basic)\s+)?[^\s,;]+"#,
            in: value,
            with: "$1[凭据已隐藏]"
        )
        value = replacing(
            #"(?i)(\"?(?:uuid|user(?:name)?|password|passwd|secret|token|authorization|proxy-authorization|auth|credential|key|private[_-]?key|public[_-]?key|api[_-]?key|access[_-]?key|client[_-]?secret)\"?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}\]]+)"#,
            in: value,
            with: "$1[凭据已隐藏]"
        )
        value = replacing(
            #"(?i)(\b(?:dial(?:ing)?\s+(?:tcp|udp)\s+|connect(?:ing)?\s+to\s+|connection\s+to\s+))([a-z][a-z0-9-]{0,62})(?::[0-9]{1,5})?(?![a-z0-9.-])"#,
            in: value,
            with: "$1[端点已隐藏]"
        )
        value = replacing(
            #"(?i)(\"?(?:server[_-]?port|remote[_-]?port)\"?\s*[:=]\s*)[0-9]{1,5}"#,
            in: value,
            with: "$1[端口已隐藏]"
        )
        value = replacing(
            #"(?i)(\"?(?:server|host|address|endpoint|remote(?:[_-]addr(?:ess)?)?)\"?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;}\]]+)"#,
            in: value,
            with: "$1[端点已隐藏]"
        )
        value = replacing(
            #"(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b"#,
            in: value,
            with: "[UUID已隐藏]"
        )
        value = replacing(
            #"(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?::[0-9]{1,5})?(?![0-9])"#,
            in: value,
            with: "[端点已隐藏]"
        )
        value = replacing(
            #"(?i)\[[0-9a-f:.%]{2,}\](?::[0-9]{1,5})?"#,
            in: value,
            with: "[端点已隐藏]"
        )
        value = replacing(
            #"(?i)(?<![a-z0-9_-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}(?::[0-9]{1,5})?(?![a-z0-9_-])"#,
            in: value,
            with: "[端点已隐藏]"
        )
        value = redactUnbracketedIPv6(in: value)

        return String(value.prefix(600))
    }

    private static func storageURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }

    private static func redactUnbracketedIPv6(in value: String) -> String {
        let pattern = #"(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![0-9a-f:])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: range)
        var output = value
        for match in matches.reversed() {
            guard let matchRange = Range(match.range, in: output) else { continue }
            let candidate = String(output[matchRange])
            // Keep clock-like diagnostics readable; they are not IPv6 endpoints.
            if candidate.range(of: #"^\d{1,2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
                continue
            }
            output.replaceSubrange(matchRange, with: "[端点已隐藏]")
        }
        return output
    }
}
