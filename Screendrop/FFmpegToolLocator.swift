//
//  FFmpegToolLocator.swift
//  Screendrop
//

import Foundation

enum FFmpegToolLocator {
    static func findFFmpeg() async -> String? {
        await Task.detached(priority: .utility) {
            findBinary(named: "ffmpeg")
        }.value
    }

    private static func findBinary(named name: String) -> String? {
        for directory in searchDirectories {
            let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) else {
            return nil
        }

        return output
    }

    private static var searchDirectories: [String] {
        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "/bin"
        ]

        var result: [String] = []
        for directory in pathDirectories + commonDirectories where !directory.isEmpty && !result.contains(directory) {
            result.append(directory)
        }
        return result
    }
}
