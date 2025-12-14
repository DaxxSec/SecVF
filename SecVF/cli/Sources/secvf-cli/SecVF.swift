import ArgumentParser
import Foundation

@main
struct SecVF: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secvf",
        abstract: "SecVF - Security Virtualization Framework CLI",
        version: "1.0.0",
        subcommands: [
            VMCommand.self,
            USBCommand.self,
            SwitchCommand.self,
            CaptureCommand.self,
            TUICommand.self,
        ],
        defaultSubcommand: nil
    )
}

// MARK: - Common Options

struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Output in JSON format")
    var json = false

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose = false
}

// MARK: - JSON Output Helpers

struct JSONOutput: Encodable {
    let success: Bool
    let message: String?
    let data: AnyCodable?

    init(success: Bool, message: String? = nil, data: Any? = nil) {
        self.success = success
        self.message = message
        self.data = data.map { AnyCodable($0) }
    }

    func print() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self),
           let string = String(data: data, encoding: .utf8) {
            Swift.print(string)
        }
    }
}

// Type-erased Codable wrapper
struct AnyCodable: Encodable {
    private let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let v as String:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Int32:
            try container.encode(v)
        case let v as UInt64:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as Bool:
            try container.encode(v)
        case let v as [String: Any]:
            try container.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]:
            try container.encode(v.map { AnyCodable($0) })
        case is NSNull:
            try container.encodeNil()
        default:
            try container.encodeNil()
        }
    }
}
