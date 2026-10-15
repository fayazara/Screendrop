import Foundation

/// Builds with the exact uploader used by the app, without AppKit or the UI.
@main struct MultipartUploadCheck {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, let token = ProcessInfo.processInfo.environment["UPLOAD_TOKEN"] else {
            fatalError("Usage: UPLOAD_TOKEN=... multipart-check <worker-url> <file>")
        }
        let file = URL(fileURLWithPath: args[2])
        var request = URLRequest(url: URL(string: args[1])!.appendingPathComponent("api/upload"))
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(file.lastPathComponent, forHTTPHeaderField: "X-Filename")
        request.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
        request.setValue("video", forHTTPHeaderField: "X-Media-Type")
        request.setValue("false", forHTTPHeaderField: "X-Social-Enabled")
        let result = try await MultipartCloudUpload.upload(fileURL: file, request: request) { fraction in
            print("Progress: \(Int(fraction * 100))%")
            fflush(stdout)
        }
        print("Uploaded \(result.size) bytes: \(result.url)")
    }
}
