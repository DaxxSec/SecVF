//
//  PacketFilterTests.swift
//  SecVFTests
//
//  Tests for the new filter-expression parser that replaces the flat
//  substring-split engine in PacketAnalysisWindowController. Coverage
//  is focused on the failure modes from review-of-PR-10 (issue #11):
//    - Parens are respected (the "Suspicious TLDs" bug)
//    - Numeric port comparisons don't substring-match (the
//      "Non-Standard Ports" bug: 8080 should NOT match "not 80")
//    - and / or / not precedence is correct under nesting
//

import XCTest
@testable import SecVF

final class PacketFilterTests: XCTestCase {

    // MARK: - Test fixtures

    /// Stub packet implementing `PacketLike`. Lets us evaluate the
    /// parser without depending on the live capture pipeline.
    struct TestPacket: PacketLike {
        var `protocol`: String
        var info: String
        var sourceIP: String?
        var destIP: String?
        var length: Int
    }

    private func tcp(_ info: String, length: Int = 100,
                     sourceIP: String? = "10.0.0.1",
                     destIP: String? = "10.0.0.2") -> TestPacket {
        TestPacket(protocol: "TCP", info: info, sourceIP: sourceIP,
                   destIP: destIP, length: length)
    }

    private func dns(_ info: String, length: Int = 80) -> TestPacket {
        TestPacket(protocol: "DNS", info: info, sourceIP: "10.0.0.1",
                   destIP: "8.8.8.8", length: length)
    }

    private func arp() -> TestPacket {
        TestPacket(protocol: "ARP", info: "Who has 10.0.0.5?", sourceIP: nil,
                   destIP: nil, length: 42)
    }

    private func icmp(length: Int = 64) -> TestPacket {
        TestPacket(protocol: "ICMP", info: "Echo request",
                   sourceIP: "10.0.0.1", destIP: "8.8.8.8", length: length)
    }

    // Tiny eval helper — compile, then run against the packet
    private func matches(_ filter: String, _ packet: TestPacket,
                         file: StaticString = #file, line: UInt = #line) -> Bool {
        guard let compiled = PacketFilter.compileOrNil(filter) else {
            XCTFail("Filter failed to compile: \(filter)", file: file, line: line)
            return false
        }
        return compiled.matches(packet)
    }

    // MARK: - Issue #11 regressions (the three failure modes)

    func testSuspiciousTLDsFilterRespectsParens() {
        // Previously: `dns and (tk or ml or ga or cf or gq)` was split
        // on " or " first and fell into substring-matching "ml" against
        // every packet's info (matching "html", "xml", "smtp"). With
        // a real parser the parens take precedence and the substring
        // match is scoped to the DNS-only side.
        let suspicious  = dns("Query .tk")
        let benignDNS   = dns("Query apple.com")
        let httpWithMl  = tcp("GET /index.html HTTP/1.1")

        // Use leading "." patterns to make the substring match honest
        // (the rewritten preset uses this form).
        let filter = #"dns and (info contains ".tk" or info contains ".ml")"#
        XCTAssertTrue(matches(filter, suspicious))
        XCTAssertFalse(matches(filter, benignDNS))
        XCTAssertFalse(matches(filter, httpWithMl),
                       "HTTP traffic with 'html' must NOT match the DNS-suspicious-TLD filter")
    }

    func testNonStandardPortsExcludesByNumericComparisonNotSubstring() {
        // Previously: `tcp and not 80 and not 443` substring-matched
        // "80" against the info field, so packets on port 8080 (which
        // contains "80") were also excluded. With a real parser
        // `port != 80` is a numeric comparison and 8080 passes.
        let p80   = tcp(":80 →12345")
        let p8080 = tcp(":8080 →12345")
        let p5300 = tcp(":5300 →12345")
        let p443  = tcp(":443 →12345")

        let filter = "tcp and port != 80 and port != 443 and port != 22 and port != 53"
        XCTAssertFalse(matches(filter, p80),  "port 80 must be excluded")
        XCTAssertTrue(matches(filter, p8080), "port 8080 must NOT be excluded by `not 80` substring match")
        XCTAssertTrue(matches(filter, p5300), "port 5300 must NOT be excluded by `not 53` substring match")
        XCTAssertFalse(matches(filter, p443), "port 443 must be excluded")
    }

    func testParenthesizedNotGroupsCorrectly() {
        // a and not (b or c) — exclude ANY packet matching b OR c
        let dnsApple    = dns("Query apple.com")
        let dnsExample  = dns("Query example.com")
        let dnsIcloud   = dns("Query icloud.com")

        let filter = "dns and not (apple or icloud)"
        XCTAssertFalse(matches(filter, dnsApple))
        XCTAssertFalse(matches(filter, dnsIcloud))
        XCTAssertTrue(matches(filter, dnsExample))
    }

    // MARK: - Boolean precedence

    func testAndHasHigherPrecedenceThanOr() {
        // a and b or c  ≡  (a and b) or c
        let p = tcp(":80")
        // tcp and tls or arp — TCP packet without TLS, but should match
        // via the "or arp" branch if precedence is wrong.
        XCTAssertFalse(matches("tcp and tls or arp", p),
                       "TCP packet must NOT match `tcp and tls or arp` — only ARP or TLS-tagged TCP should")
        XCTAssertTrue(matches("tcp and tls or arp", arp()),
                      "ARP must match the `or arp` branch")
    }

    func testNotBindsTighterThanAnd() {
        // not a and b  ≡  (not a) and b
        let p = tcp(":80")
        XCTAssertFalse(matches("not tcp and tcp", p),
                       "NOT must apply to the immediately-following term, not the whole AND")
    }

    // MARK: - Atoms

    func testProtocolBareIdentifier() {
        XCTAssertTrue(matches("tcp", tcp(":80")))
        XCTAssertFalse(matches("udp", tcp(":80")))
        XCTAssertTrue(matches("arp", arp()))
        XCTAssertTrue(matches("dns", dns("Query example.com")))
    }

    func testPortComparisons() {
        let p80 = tcp(":80")
        XCTAssertTrue(matches("port == 80", p80))
        XCTAssertFalse(matches("port == 81", p80))
        XCTAssertTrue(matches("port != 81", p80))
        XCTAssertFalse(matches("port != 80", p80))
        XCTAssertTrue(matches("port > 79", p80))
        XCTAssertFalse(matches("port > 80", p80))
        XCTAssertTrue(matches("port >= 80", p80))
        XCTAssertTrue(matches("port < 81", p80))
        XCTAssertTrue(matches("port <= 80", p80))
    }

    func testTcpPortSugar() {
        // `tcp 80` should desugar to `tcp and port == 80`
        let p80  = tcp(":80")
        let p443 = tcp(":443")
        XCTAssertTrue(matches("tcp 80", p80))
        XCTAssertFalse(matches("tcp 80", p443))
        XCTAssertFalse(matches("tcp 80", dns(":80")),
                       "`tcp 80` must require BOTH the tcp protocol AND port 80")
    }

    func testLengthComparison() {
        XCTAssertTrue(matches("length > 50", icmp(length: 200)))
        XCTAssertFalse(matches("length > 50", icmp(length: 20)))
        XCTAssertTrue(matches("icmp and length > 100", icmp(length: 200)))
        XCTAssertFalse(matches("icmp and length > 100", icmp(length: 50)))
    }

    func testIPMatch() {
        let p = tcp(":80", sourceIP: "10.0.0.1", destIP: "8.8.8.8")
        XCTAssertTrue(matches(#"ip.addr == "10.0.0.1""#, p))
        XCTAssertTrue(matches(#"ip.addr == "8.8.8.8""#, p))
        XCTAssertFalse(matches(#"ip.addr == "1.1.1.1""#, p))
        XCTAssertTrue(matches(#"ip.src == "10.0.0.1""#, p))
        XCTAssertFalse(matches(#"ip.src == "8.8.8.8""#, p))
        XCTAssertTrue(matches(#"ip.dst == "8.8.8.8""#, p))
    }

    func testQuotedStringSubstringMatch() {
        let p = tcp("GET /index.html HTTP/1.1")
        XCTAssertTrue(matches(#""html""#, p))
        XCTAssertFalse(matches(#""WebSocket""#, p))
    }

    func testBareIdentifierFallsThroughToSubstring() {
        // Unknown identifiers fall through to info substring matching
        let p = dns("Query apple.com")
        XCTAssertTrue(matches("apple", p))
        XCTAssertFalse(matches("microsoft", p))
    }

    // MARK: - Whitespace + edge cases

    func testEmptyFilterIsNoFilter() {
        XCTAssertNil(try? PacketFilter.compile(""))
        XCTAssertNil(try? PacketFilter.compile("   "))
    }

    func testWhitespaceInsensitive() {
        XCTAssertTrue(matches("  tcp    and    port == 80  ", tcp(":80")))
    }

    func testCaseInsensitiveIdentifiers() {
        XCTAssertTrue(matches("TCP AND PORT == 80", tcp(":80")))
    }

    // MARK: - Error surfacing

    func testMalformedFilterThrows() {
        XCTAssertThrowsError(try PacketFilter.compile("tcp and"))
        XCTAssertThrowsError(try PacketFilter.compile("(tcp"))
        XCTAssertThrowsError(try PacketFilter.compile("port =="))
        XCTAssertThrowsError(try PacketFilter.compile(#""unterminated"#))
    }

    func testCompileOrNilReturnsNilOnError() {
        XCTAssertNil(PacketFilter.compileOrNil("(tcp"))
        XCTAssertNil(PacketFilter.compileOrNil("port =="))
    }
}
