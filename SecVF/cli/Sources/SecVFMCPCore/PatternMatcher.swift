//
//  PatternMatcher.swift
//  SecVFMCPCore
//
//  Server-side regex/heuristic matcher for dangerous patterns in
//  `secvf_exec_in_vm` commands. When a command matches one or more
//  patterns, the dispatcher invokes the confirmation hook BEFORE
//  executing — so the user (or a configured policy script) gets
//  a chance to deny.
//
//  Layer 3 of the layered defense model (see MCP-WRAPPER-DESIGN.md):
//  catches obvious dangerous commands. Doesn't catch paraphrased /
//  obfuscated variants — those are bounded by capability tier + audit
//  log + the prompt-level trust model.
//

import Foundation

public enum DangerCategory: String, Sendable {
    case networkEgress       // curl/wget/nc reverse shells, suspicious outbound
    case fileExfiltration    // base64 + curl, tar | curl
    case persistence         // authorized_keys, crontab, launchd plists
    case privilegeEscalation // sudo, setuid bits, su -
    case selfModification    // rc files, .profile, autoload mods
    case destructive         // rm -rf /, dd if=/dev/zero, mkfs
}

public struct DangerPattern: Sendable {
    public let id: String
    public let category: DangerCategory
    public let description: String
    let regex: NSRegularExpression

    init(id: String, category: DangerCategory, description: String, pattern: String) {
        self.id = id
        self.category = category
        self.description = description
        self.regex = try! NSRegularExpression(  // patterns are static, force-try OK
            pattern: pattern,
            options: [.caseInsensitive]
        )
    }
}

public struct CommandPatternMatcher: Sendable {
    public let patterns: [DangerPattern]

    public init(patterns: [DangerPattern]) {
        self.patterns = patterns
    }

    /// Returns every pattern that matches. Empty array = benign command.
    public func match(command: String) -> [DangerPattern] {
        let range = NSRange(command.startIndex..., in: command)
        return patterns.filter { pattern in
            pattern.regex.firstMatch(in: command, range: range) != nil
        }
    }

    /// Default ruleset shipped with secvf-mcp. Patterns are deliberately
    /// broad (catch obvious cases) rather than narrow (be uncatchable).
    /// Users can extend via configuration in a later iteration.
    public static func defaultMatcher() -> CommandPatternMatcher {
        let patterns: [DangerPattern] = [
            // === Network egress ===
            DangerPattern(
                id: "egress-curl-http",
                category: .networkEgress,
                description: "curl/wget to an HTTP(S) URL — possible outbound exfil",
                pattern: #"\b(curl|wget)\b\s+[^|\n]*https?://"#
            ),
            DangerPattern(
                id: "egress-nc",
                category: .networkEgress,
                description: "netcat — common reverse-shell + portscan tool",
                pattern: #"\bnc\b\s+(-[a-zA-Z]+\s+)*[\w\.]+\s+\d+"#
            ),
            DangerPattern(
                id: "egress-bash-reverse-shell",
                category: .networkEgress,
                description: "Bash /dev/tcp reverse-shell idiom",
                pattern: #"/dev/tcp/[\d\.]+/\d+"#
            ),
            DangerPattern(
                id: "egress-pipe-to-shell",
                category: .networkEgress,
                description: "curl | sh — direct execution of remote content",
                pattern: #"\b(curl|wget)\b[^|\n]*\|\s*(sh|bash|zsh|fish)\b"#
            ),

            // === File exfiltration ===
            DangerPattern(
                id: "exfil-base64-curl",
                category: .fileExfiltration,
                description: "base64 → curl — likely exfiltration pipeline",
                pattern: #"\bbase64\b[^|\n]*\|[^|\n]*\bcurl\b"#
            ),
            DangerPattern(
                id: "exfil-tar-curl",
                category: .fileExfiltration,
                description: "tar → curl — likely bulk-file exfiltration",
                pattern: #"\btar\b[^|\n]*\|[^|\n]*\bcurl\b"#
            ),

            // === Persistence ===
            DangerPattern(
                id: "persist-authorized-keys",
                category: .persistence,
                description: "Writing to ~/.ssh/authorized_keys",
                pattern: #"\.ssh/authorized_keys"#
            ),
            DangerPattern(
                id: "persist-crontab",
                category: .persistence,
                description: "Modifying crontab",
                pattern: #"\bcrontab\b\s+-(e|l|r)\b"#
            ),
            DangerPattern(
                id: "persist-launchctl",
                category: .persistence,
                description: "Loading a launchd plist",
                pattern: #"\blaunchctl\s+(load|bootstrap)\b"#
            ),

            // === Privilege escalation ===
            DangerPattern(
                id: "privesc-sudo",
                category: .privilegeEscalation,
                description: "sudo invocation",
                pattern: #"\bsudo\b"#
            ),
            DangerPattern(
                id: "privesc-su",
                category: .privilegeEscalation,
                description: "su to another user",
                pattern: #"\bsu\s+-\b"#
            ),
            DangerPattern(
                id: "privesc-setuid",
                category: .privilegeEscalation,
                description: "Setting setuid bit (chmod 4xxx or +s)",
                pattern: #"\bchmod\b\s+(\+s\b|[0-7]?4\d{3}\b)"#
            ),

            // === Self / shell modification ===
            DangerPattern(
                id: "rc-file-write",
                category: .selfModification,
                description: "Writing to shell rc files (.zshrc, .bashrc, etc.)",
                pattern: #"\.(zshrc|bashrc|profile|bash_profile|zprofile)\b"#
            ),

            // === Destructive ===
            DangerPattern(
                id: "destructive-rm-root",
                category: .destructive,
                description: "rm -rf on a system path",
                pattern: #"\brm\b\s+-[a-zA-Z]*r[a-zA-Z]*\b\s+(/|/etc|/usr|/var|/home|~)"#
            ),
            DangerPattern(
                id: "destructive-dd-zero",
                category: .destructive,
                description: "dd if=/dev/zero — disk wipe pattern",
                pattern: #"\bdd\b\s+if=/dev/(zero|urandom)\b"#
            ),
            DangerPattern(
                id: "destructive-mkfs",
                category: .destructive,
                description: "mkfs — filesystem format",
                pattern: #"\bmkfs\."#
            ),
        ]
        return CommandPatternMatcher(patterns: patterns)
    }
}
