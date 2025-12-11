//
//  ProcessExecutor.swift
//  SecVF
//
//  Centralized helper for executing external processes
//

import Foundation

/// Centralized utility for executing external processes
struct ProcessExecutor {

    // MARK: - Types

    /// Errors that can occur during process execution
    enum ExecutionError: LocalizedError {
        case executableNotFound(path: String)
        case executionFailed(exitCode: Int32, output: String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let path):
                return "Executable not found at: \(path)"
            case .executionFailed(let exitCode, let output):
                return "Process failed with exit code \(exitCode): \(output)"
            case .timeout:
                return "Process execution timed out"
            }
        }
    }

    /// Result of a successful process execution
    struct ExecutionResult {
        let exitCode: Int32
        let output: String
        let errorOutput: String

        var succeeded: Bool {
            return exitCode == 0
        }
    }

    // MARK: - Execution

    /// Run an external process and wait for completion
    /// - Parameters:
    ///   - executable: Path to the executable
    ///   - arguments: Command-line arguments
    ///   - currentDirectory: Working directory for the process (optional)
    ///   - environment: Environment variables to set (optional)
    /// - Returns: Result containing exit code and output, or an error
    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil,
        environment: [String: String]? = nil
    ) -> Result<ExecutionResult, ExecutionError> {

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let currentDirectory = currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        if let environment = environment {
            var processEnv = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                processEnv[key] = value
            }
            process.environment = processEnv
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            return .success(ExecutionResult(
                exitCode: process.terminationStatus,
                output: output,
                errorOutput: errorOutput
            ))
        } catch {
            return .failure(.executableNotFound(path: executable))
        }
    }

    /// Run hdiutil command (commonly used in SecVF)
    /// - Parameters:
    ///   - arguments: Arguments to pass to hdiutil
    /// - Returns: Result containing exit code and output
    static func runHdiutil(arguments: [String]) -> Result<ExecutionResult, ExecutionError> {
        return run(executable: "/usr/bin/hdiutil", arguments: arguments)
    }

    /// Run a shell command via /bin/sh
    /// - Parameter command: The shell command to execute
    /// - Returns: Result containing exit code and output
    static func runShell(_ command: String) -> Result<ExecutionResult, ExecutionError> {
        return run(executable: "/bin/sh", arguments: ["-c", command])
    }
}
