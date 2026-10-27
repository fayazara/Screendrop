import Foundation
import OSLog
import Synchronization

nonisolated struct CloudUploadHTTPError: LocalizedError {
    let statusCode: Int

    var errorDescription: String? {
        switch statusCode {
        case 413:
            "The cloud server rejected this upload because it is too large (HTTP 413). Compress or shorten the recording, or update the app and Worker to support multipart uploads."
        case 401, 403:
            "The cloud server rejected the upload credentials (HTTP \(statusCode)). Verify the connection in Settings → Cloud."
        default:
            "Cloud upload failed (HTTP \(statusCode))."
        }
    }
}

/// Keeps early HTTP rejections that URLSession's async API can otherwise
/// hide behind a connection error or timeout while the body is still sending.
nonisolated enum CloudUploadRequest {
    private static let logger = Logger(subsystem: "com.fayazahmed.Screendrop", category: "CloudUpload")

    static func uploadFile(
        at fileURL: URL,
        request: URLRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> MultipartCloudUpload.Result {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        // Stay below Cloudflare's 100 MB Free/Pro request limit while
        // preserving the existing upload path for smaller files/older Workers.
        if size >= 90 * 1024 * 1024 {
            return try await MultipartCloudUpload.upload(fileURL: fileURL, request: request, progress: progress)
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let (responseData, response) = try await send(request, body: data, progress: progress)
        guard response.statusCode == 201 else { throw URLError(.badServerResponse) }
        let result = try JSONDecoder().decode(MultipartCloudUpload.Result.self, from: responseData)
        progress?(1)
        return result
    }

    static func send(
        _ request: URLRequest,
        body: Data?,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let delegate = UploadDelegate(progress: progress)
        do {
            let result: (Data, URLResponse)
            if let body {
                result = try await URLSession.shared.upload(for: request, from: body, delegate: delegate)
            } else {
                result = try await URLSession.shared.data(for: request, delegate: delegate)
            }
            try Task.checkCancellation()
            guard let response = result.1 as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw CloudUploadHTTPError(statusCode: response.statusCode)
            }
            return (result.0, response)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let status = (error as? CloudUploadHTTPError)?.statusCode ?? delegate.responseStatus
            // Never log credentials, URLs, filenames, or server response bodies.
            logger.error("Upload failed: HTTP=\(status ?? 0) errorCode=\((error as NSError).code) requestBytes=\(body?.count ?? 0)")
            if let status, status >= 400 {
                throw CloudUploadHTTPError(statusCode: status)
            }
            throw error
        }
    }

    private final class UploadDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        private let status = Mutex<Int?>(nil)
        private let progress: (@Sendable (Double) -> Void)?

        init(progress: (@Sendable (Double) -> Void)?) {
            self.progress = progress
        }

        var responseStatus: Int? { status.withLock { $0 } }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let response = metrics.transactionMetrics.last?.response as? HTTPURLResponse
            status.withLock { $0 = response?.statusCode }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            guard totalBytesExpectedToSend > 0 else { return }
            progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }
}
