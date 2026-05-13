//
//  PacketFilter.swift
//  SecVF
//
//  Filter expression parser for the Packet Analysis window. Replaces the
//  previous flat substring-split engine in PacketAnalysisWindowController
//  (which mis-handled parens and was tripped by numeric-substring matches
//  like "not 80" excluding port 8080).
//
//  Grammar (informal, calibrated to the malware-analysis preset catalog):
//
//      expr      ::= orExpr
//      orExpr    ::= andExpr ( "or" andExpr )*
//      andExpr   ::= notExpr ( "and" notExpr )*
//      notExpr   ::= "not" notExpr | atom
//      atom      ::= "(" expr ")" | predicate
//
//      predicate ::= protoTerm
//                  | portTerm
//                  | lengthTerm
//                  | ipTerm
//                  | substringTerm
//
//      protoTerm     ::= identifier               # tcp, udp, dns, http, …
//      portTerm      ::= "port" compOp number     # port != 80
//                      | identifier number        # legacy: tcp 80 / udp 53 (sugar)
//      lengthTerm    ::= "length" compOp number
//      ipTerm        ::= ipField "==" ipLiteral
//                      | ipField "!=" ipLiteral
//      ipField       ::= "ip.addr" | "ip.src" | "ip.dst"
//      substringTerm ::= "info" "contains" string  # explicit
//                      | identifier                # implicit fallback
//                      | string                    # quoted substring
//
//      compOp ::= "==" | "!=" | "<" | ">" | "<=" | ">="
//
//  Identifier matching is case-insensitive. Operator keywords (and / or /
//  not / port / length / contains) are reserved — to match a packet whose
//  info field literally contains those words, quote them ("\"port\"" etc.).
//
//  Unknown bare identifiers fall through to "info contains <ident>" so
//  legacy strings like `apple`, `icloud`, `ssh`, `smb` keep working as
//  best-effort substring matches against the per-packet info field.
//

import Foundation

// MARK: - Public entry point

/// Parsed, evaluable filter expression. Build once via
/// `PacketFilter.compile(_:)`, then call `matches(_:)` per packet.
struct PacketFilter {
    let expression: Expression
    let source: String

    /// Compile a filter string into an evaluable expression. Returns nil
    /// for empty input (caller treats that as "no filter"); throws
    /// `PacketFilterError` for malformed expressions.
    static func compile(_ filter: String) throws -> PacketFilter? {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let tokens = try PacketFilterTokenizer.tokenize(trimmed)
        var parser = PacketFilterParser(tokens: tokens)
        let expr = try parser.parseExpression()
        if !parser.isAtEnd {
            throw PacketFilterError.trailingTokens(parser.remainingDescription)
        }
        return PacketFilter(expression: expr, source: trimmed)
    }

    /// Compile permissively — returns nil on parse failure so callers
    /// that don't need to surface the error (live-typed filter field)
    /// can simply show all packets.
    static func compileOrNil(_ filter: String) -> PacketFilter? {
        return (try? compile(filter)) ?? nil
    }

    /// Evaluate against a packet. Pure — no side effects, safe to call
    /// from any thread.
    func matches(_ packet: PacketLike) -> Bool {
        return expression.evaluate(packet)
    }
}

/// Thin protocol so the engine can evaluate against the real
/// `CapturedPacket` (defined in PacketCaptureManager.swift) without
/// importing it directly — useful when unit-testing with fixtures.
protocol PacketLike {
    var `protocol`: String { get }
    var info: String { get }
    var sourceIP: String? { get }
    var destIP: String? { get }
    var length: Int { get }
}

/// Compiler / evaluator errors. Surfaced to the user in the filter
/// validation UI; never silently swallowed.
enum PacketFilterError: Error, Equatable {
    case unexpectedCharacter(Character)
    case unterminatedString
    case unexpectedToken(String)
    case expectedToken(String, found: String)
    case expectedComparator(found: String)
    case expectedNumber(found: String)
    case trailingTokens(String)
}

// MARK: - AST

indirect enum Expression {
    case and(Expression, Expression)
    case or(Expression, Expression)
    case not(Expression)
    case proto(String)                       // e.g. "tcp"
    case portCompare(ComparisonOp, Int)      // e.g. port != 80
    case lengthCompare(ComparisonOp, Int)    // e.g. length > 100
    case ipMatch(IPField, ComparisonOp, String)
    case substring(String)                   // case-insensitive info substring

    func evaluate(_ p: PacketLike) -> Bool {
        switch self {
        case .and(let l, let r):
            return l.evaluate(p) && r.evaluate(p)
        case .or(let l, let r):
            return l.evaluate(p) || r.evaluate(p)
        case .not(let inner):
            return !inner.evaluate(p)
        case .proto(let name):
            return Self.matchProtocol(name, packet: p)
        case .portCompare(let op, let port):
            return Self.matchPort(op: op, port: port, packet: p)
        case .lengthCompare(let op, let n):
            return op.apply(p.length, n)
        case .ipMatch(let field, let op, let value):
            return Self.matchIP(field: field, op: op, value: value, packet: p)
        case .substring(let s):
            return p.info.range(of: s, options: .caseInsensitive) != nil
        }
    }

    // MARK: - Predicate helpers (static so they're directly testable)

    /// Match a protocol identifier against a packet. Most are exact
    /// equality on `packet.protocol`; a few (http, https, ssh, smb,
    /// afp, tls, ssl) ALSO match if the info field carries the hint,
    /// matching the legacy engine's special-cases so existing presets
    /// keep working.
    static func matchProtocol(_ name: String, packet p: PacketLike) -> Bool {
        let proto = p.protocol.lowercased()
        let info = p.info.lowercased()
        let target = name.lowercased()

        switch target {
        case "tcp", "udp", "icmp", "arp", "dns", "ipv6":
            return proto == target
        case "http":
            return proto == "http" || info.contains("http")
        case "https":
            return proto == "https" || info.contains("https") || info.contains(":443")
        case "tls", "ssl":
            // Coalesced — the underlying packet protocol could be tagged
            // either way depending on the capture source.
            return proto == "tls" || proto == "ssl" || info.contains("tls") || info.contains("ssl")
        case "ssh":
            return Self.matchPort(op: .eq, port: 22, packet: p) || info.contains("ssh")
        case "smb":
            return Self.matchPort(op: .eq, port: 445, packet: p)
                || Self.matchPort(op: .eq, port: 139, packet: p)
                || info.contains("smb")
        case "afp":
            return Self.matchPort(op: .eq, port: 548, packet: p) || info.contains("afp")
        default:
            // Unknown identifier — fall through to substring match. Keeps
            // legacy presets like `apple` / `icloud` working as
            // "info contains 'apple'".
            return info.contains(target)
        }
    }

    /// Match `port <op> N`. Extracts the port number from the
    /// packet.info field via regex on the well-known port markers the
    /// capture pipeline emits: `:N`, `→N`, `->N`. Falls back to false
    /// when no port is parsed (e.g. ARP, ICMP) for any `op` other
    /// than `!=`, which conservatively returns true for those rows
    /// (a non-port packet doesn't equal any port, but also doesn't
    /// equal *not* this port — judgement call: treat "port != N" as
    /// "any port-bearing packet whose port ≠ N", so ARP rows DON'T
    /// pass the filter. This matches the user's mental model: "I want
    /// TCP packets that aren't on port 80" — ARP isn't TCP, so it
    /// shouldn't make it through anyway when AND'd with a `tcp` term).
    static func matchPort(op: ComparisonOp, port: Int, packet p: PacketLike) -> Bool {
        guard let extracted = extractPortFromInfo(p.info) else {
            return false
        }
        return op.apply(extracted, port)
    }

    /// Pull a port number out of common info-field formats. Returns
    /// the first matched port for evaluation. Patterns matched:
    /// `:80`, `→443`, `->22`, `port 53`.
    static func extractPortFromInfo(_ info: String) -> Int? {
        // Capture groups: anything that looks like a port marker
        // followed by 1–5 digits. Stable left-to-right scan.
        let lower = info.lowercased()
        let markers = [":", "→", "->", "port "]
        for marker in markers {
            if let range = lower.range(of: marker) {
                let after = lower[range.upperBound...]
                // Read leading digits
                let digits = after.prefix { $0.isASCII && $0.isNumber }
                if !digits.isEmpty, let n = Int(digits) {
                    return n
                }
            }
        }
        return nil
    }

    static func matchIP(field: IPField, op: ComparisonOp,
                        value: String, packet p: PacketLike) -> Bool {
        let candidates: [String?]
        switch field {
        case .addr: candidates = [p.sourceIP, p.destIP]
        case .src:  candidates = [p.sourceIP]
        case .dst:  candidates = [p.destIP]
        }
        switch op {
        case .eq:
            return candidates.contains { $0 == value }
        case .neq:
            return candidates.allSatisfy { $0 != nil && $0 != value }
        default:
            // <, >, <=, >= on IP literals isn't meaningful; treat as false.
            return false
        }
    }
}

enum IPField {
    case addr   // src or dst
    case src
    case dst
}

enum ComparisonOp {
    case eq, neq, lt, gt, lte, gte

    func apply(_ a: Int, _ b: Int) -> Bool {
        switch self {
        case .eq:  return a == b
        case .neq: return a != b
        case .lt:  return a <  b
        case .gt:  return a >  b
        case .lte: return a <= b
        case .gte: return a >= b
        }
    }
}

// MARK: - Tokens

enum Token: Equatable {
    case lparen
    case rparen
    case and
    case or
    case not
    case contains
    case keyword(String)        // port, length, info, ip.addr, ip.src, ip.dst
    case identifier(String)     // tcp, udp, http, apple, foo
    case stringLit(String)      // "quoted"
    case number(Int)
    case compOp(ComparisonOp)
}

// MARK: - Tokenizer

enum PacketFilterTokenizer {
    static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            // Whitespace
            if c.isWhitespace {
                i = source.index(after: i)
                continue
            }
            // Parens
            if c == "(" { tokens.append(.lparen);  i = source.index(after: i); continue }
            if c == ")" { tokens.append(.rparen);  i = source.index(after: i); continue }
            // Quoted string
            if c == "\"" {
                let (lit, next) = try readQuotedString(source, from: source.index(after: i))
                tokens.append(.stringLit(lit))
                i = next
                continue
            }
            // Comparison operators
            if c == "=" || c == "!" || c == "<" || c == ">" {
                let (op, next) = try readCompOp(source, from: i)
                tokens.append(.compOp(op))
                i = next
                continue
            }
            // Number
            if c.isNumber {
                let (n, next) = readNumber(source, from: i)
                tokens.append(.number(n))
                i = next
                continue
            }
            // Identifier or keyword
            if c.isLetter || c == "_" || c == "." {
                let (raw, next) = readIdentifier(source, from: i)
                tokens.append(classifyIdentifier(raw))
                i = next
                continue
            }
            throw PacketFilterError.unexpectedCharacter(c)
        }
        return tokens
    }

    private static func classifyIdentifier(_ raw: String) -> Token {
        let lower = raw.lowercased()
        switch lower {
        case "and":      return .and
        case "or":       return .or
        case "not":      return .not
        case "contains": return .contains
        case "port", "length", "info",
             "ip.addr", "ip.src", "ip.dst":
            return .keyword(lower)
        default:
            return .identifier(lower)
        }
    }

    private static func readIdentifier(_ s: String, from start: String.Index)
        -> (String, String.Index)
    {
        var i = start
        while i < s.endIndex {
            let c = s[i]
            // Identifiers may include letters, digits (after first), underscore, dot
            if c.isLetter || c.isNumber || c == "_" || c == "." {
                i = s.index(after: i)
            } else {
                break
            }
        }
        return (String(s[start..<i]), i)
    }

    private static func readNumber(_ s: String, from start: String.Index)
        -> (Int, String.Index)
    {
        var i = start
        while i < s.endIndex, s[i].isNumber {
            i = s.index(after: i)
        }
        return (Int(s[start..<i]) ?? 0, i)
    }

    private static func readQuotedString(_ s: String, from start: String.Index)
        throws -> (String, String.Index)
    {
        var i = start
        while i < s.endIndex {
            if s[i] == "\"" {
                return (String(s[start..<i]), s.index(after: i))
            }
            i = s.index(after: i)
        }
        throw PacketFilterError.unterminatedString
    }

    private static func readCompOp(_ s: String, from start: String.Index)
        throws -> (ComparisonOp, String.Index)
    {
        let c = s[start]
        let next = s.index(after: start)
        let nextCh = next < s.endIndex ? s[next] : nil
        switch c {
        case "=":
            if nextCh == "=" { return (.eq, s.index(after: next)) }
            return (.eq, next)   // "key = val" sugar
        case "!":
            if nextCh == "=" { return (.neq, s.index(after: next)) }
            throw PacketFilterError.expectedToken("=", found: "!")
        case "<":
            if nextCh == "=" { return (.lte, s.index(after: next)) }
            return (.lt, next)
        case ">":
            if nextCh == "=" { return (.gte, s.index(after: next)) }
            return (.gt, next)
        default:
            throw PacketFilterError.unexpectedCharacter(c)
        }
    }
}

// MARK: - Parser (recursive descent)

struct PacketFilterParser {
    private let tokens: [Token]
    private var pos: Int = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    var isAtEnd: Bool { pos >= tokens.count }
    var remainingDescription: String {
        let rest = tokens.dropFirst(pos)
        return rest.map { "\($0)" }.joined(separator: " ")
    }

    private func peek() -> Token? {
        pos < tokens.count ? tokens[pos] : nil
    }

    private mutating func advance() -> Token? {
        guard pos < tokens.count else { return nil }
        defer { pos += 1 }
        return tokens[pos]
    }

    private mutating func consume(_ expected: Token) throws {
        guard let t = peek(), t == expected else {
            throw PacketFilterError.expectedToken("\(expected)",
                                                  found: peek().map { "\($0)" } ?? "<end>")
        }
        pos += 1
    }

    mutating func parseExpression() throws -> Expression {
        return try parseOr()
    }

    private mutating func parseOr() throws -> Expression {
        var left = try parseAnd()
        while case .or = peek() {
            _ = advance()
            let right = try parseAnd()
            left = .or(left, right)
        }
        return left
    }

    private mutating func parseAnd() throws -> Expression {
        var left = try parseNot()
        while case .and = peek() {
            _ = advance()
            let right = try parseNot()
            left = .and(left, right)
        }
        return left
    }

    private mutating func parseNot() throws -> Expression {
        if case .not = peek() {
            _ = advance()
            return .not(try parseNot())
        }
        return try parseAtom()
    }

    private mutating func parseAtom() throws -> Expression {
        guard let t = peek() else {
            throw PacketFilterError.unexpectedToken("<end>")
        }
        switch t {
        case .lparen:
            _ = advance()
            let inner = try parseExpression()
            try consume(.rparen)
            return inner
        case .stringLit(let s):
            _ = advance()
            return .substring(s)
        case .keyword(let kw):
            _ = advance()
            return try parsePredicate(keyword: kw)
        case .identifier(let id):
            _ = advance()
            // Sugar: "tcp 80" / "udp 53" → tcp AND port == 80
            if case .number(let n)? = peek() {
                _ = advance()
                return .and(.proto(id), .portCompare(.eq, n))
            }
            // Plain protocol or substring fallback (proto() handles both)
            return .proto(id)
        case .number:
            // Bare number outside a comparison isn't meaningful — but
            // we don't want to be hostile to legacy filters like
            // "tcp and not 80 and not 443" where 80 was a bare token.
            // Treat as a substring search on the digits.
            if case .number(let n) = (advance() ?? .lparen) {
                return .substring(String(n))
            }
            return .substring("")
        default:
            throw PacketFilterError.unexpectedToken("\(t)")
        }
    }

    private mutating func parsePredicate(keyword: String) throws -> Expression {
        switch keyword {
        case "port":
            let op = try expectCompOp()
            let n = try expectNumber()
            return .portCompare(op, n)
        case "length":
            let op = try expectCompOp()
            let n = try expectNumber()
            return .lengthCompare(op, n)
        case "info":
            // "info contains <string>"
            guard let next = peek(), next == .contains else {
                throw PacketFilterError.expectedToken("contains",
                                                      found: peek().map { "\($0)" } ?? "<end>")
            }
            _ = advance()
            guard case .stringLit(let s)? = peek() else {
                throw PacketFilterError.expectedToken("\"string\"",
                                                      found: peek().map { "\($0)" } ?? "<end>")
            }
            _ = advance()
            return .substring(s)
        case "ip.addr", "ip.src", "ip.dst":
            let field: IPField
            switch keyword {
            case "ip.src": field = .src
            case "ip.dst": field = .dst
            default:       field = .addr
            }
            let op = try expectCompOp()
            // IP literal could be a string or a dotted identifier
            guard let next = advance() else {
                throw PacketFilterError.expectedToken("IP", found: "<end>")
            }
            let value: String
            switch next {
            case .stringLit(let s): value = s
            case .identifier(let s): value = s
            case .number(let n): value = String(n)
            default:
                throw PacketFilterError.expectedToken("IP literal",
                                                      found: "\(next)")
            }
            return .ipMatch(field, op, value)
        default:
            throw PacketFilterError.unexpectedToken(keyword)
        }
    }

    private mutating func expectCompOp() throws -> ComparisonOp {
        guard case .compOp(let op)? = peek() else {
            throw PacketFilterError.expectedComparator(found: peek().map { "\($0)" } ?? "<end>")
        }
        _ = advance()
        return op
    }

    private mutating func expectNumber() throws -> Int {
        guard case .number(let n)? = peek() else {
            throw PacketFilterError.expectedNumber(found: peek().map { "\($0)" } ?? "<end>")
        }
        _ = advance()
        return n
    }
}
