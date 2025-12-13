import ArgumentParser
import Foundation

struct TUICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Launch the Terminal User Interface"
    )

    @Flag(name: .long, help: "Show the path to the TUI without launching it")
    var showPath = false

    mutating func run() throws {
        // Find Python executable
        guard let pythonPath = findPython() else {
            print("Error: Python 3.10+ not found. Install it with: brew install python@3.12")
            throw ExitCode.failure
        }

        // Find the TUI module
        guard let tuiPath = findTUIModule() else {
            print("Error: TUI module not found.")
            print("")
            print("Install it with:")
            print("  cd secvf-cli/tui && pip install -e .")
            print("")
            print("Or run directly:")
            print("  cd secvf-cli/tui && python -m secvf_tui.app")
            throw ExitCode.failure
        }

        if showPath {
            print("Python: \(pythonPath)")
            print("TUI:    \(tuiPath)")
            return
        }

        // Get the CLI path to pass to the TUI
        let cliPath = CommandLine.arguments[0]

        // Launch the TUI
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-m", "secvf_tui.app", "--cli-path", cliPath]

        // Set PYTHONPATH to include the TUI directory
        var env = ProcessInfo.processInfo.environment
        if let existingPath = env["PYTHONPATH"] {
            env["PYTHONPATH"] = "\(tuiPath):\(existingPath)"
        } else {
            env["PYTHONPATH"] = tuiPath
        }
        process.environment = env

        // Run interactively
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                throw ExitCode(rawValue: process.terminationStatus)
            }
        } catch let error as ExitCode {
            throw error
        } catch {
            print("Error launching TUI: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }

    private func findPython() -> String? {
        // Check common Python 3 locations
        let pythonPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        for path in pythonPaths {
            if FileManager.default.fileExists(atPath: path) {
                // Verify it's Python 3.10+
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["--version"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let version = String(data: data, encoding: .utf8) ?? ""

                    // Parse version (e.g., "Python 3.12.0")
                    if let match = version.range(of: #"Python 3\.(\d+)"#, options: .regularExpression) {
                        let minorStr = String(version[match]).replacingOccurrences(of: "Python 3.", with: "")
                        if let minor = Int(minorStr), minor >= 10 {
                            return path
                        }
                    }
                } catch {
                    continue
                }
            }
        }

        // Try PATH
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["python3"]

        let pipe = Pipe()
        whichProcess.standardOutput = pipe

        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let path = path, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
                return path
            }
        } catch {
            // Ignore
        }

        return nil
    }

    private func findTUIModule() -> String? {
        let fm = FileManager.default

        // Get CLI executable location
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let executableDir = executableURL.deletingLastPathComponent()

        // Search paths relative to CLI binary
        var searchPaths: [URL] = []

        // Development: CLI at SecVF/cli/.build/debug/secvf-cli
        // TUI at SecVF/cli/tui/
        let buildDir = executableDir  // .build/debug/
        let cliRoot = buildDir.deletingLastPathComponent().deletingLastPathComponent()  // SecVF/cli/
        searchPaths.append(cliRoot.appendingPathComponent("tui"))

        // Installed alongside CLI
        searchPaths.append(executableDir.appendingPathComponent("tui"))

        // Common development locations
        searchPaths.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Code/Sandboxes/SecVF/SecVF/cli/tui"))
        searchPaths.append(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Developer/SecVF/SecVF/cli/tui"))

        for path in searchPaths {
            let tuiApp = path.appendingPathComponent("secvf_tui/app.py")
            if fm.fileExists(atPath: tuiApp.path) {
                return path.path
            }
        }

        return nil
    }
}
