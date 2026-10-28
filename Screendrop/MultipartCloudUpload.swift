import Foundation

/// Keeps each request below Cloudflare's body limit without changing the file.
nonisolated enum MultipartCloudUpload {
    private struct Session: Decodable {
        let id: String
        let key: String
        let uploadId: String
    }
    private struct Part: Codable {
        let partNumber: Int
        let etag: String
    }
    private struct Completion: Encodable {
        let key: String
        let uploadId: String
        let parts: [Part]
    }
    private enum UploadError: LocalizedError {
        case workerNeedsUpdate, rejected(Int)

        var errorDescription: String? {
            switch self {
            case .workerNeedsUpdate:
                "Update your Screendrop Cloud Worker to upload large recordings."
            case .rejected(let status):
                "Cloud upload failed (HTTP \(status))."
            }
        }
    }

    static func upload(
        fileURL: URL,
        request template: URLRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (Data, URLResponse) {
        let file = try FileHandle(forReadingFrom: fileURL)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        let partSize = 16 * 1024 * 1024
        guard size > 0, size <= UInt64(partSize) * 10_000 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let uploadURL = template.url else { throw URLError(.badURL) }
        var start = template
        start.url = uploadURL.appendingPathComponent("multipart")
        start.httpMethod = "POST"
        let session: Session
        do {
            session = try JSONDecoder().decode(Session.self, from: await send(start).0)
        } catch UploadError.rejected(let status) where status == 404 || status == 405 {
            throw UploadError.workerNeedsUpdate
        }
        var request = template
        request.url = start.url!.appendingPathComponent(session.id)
        var query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        query.queryItems = [
            URLQueryItem(name: "key", value: session.key),
            URLQueryItem(name: "uploadId", value: session.uploadId),
        ]
        var parts: [Part] = []
        var sent: UInt64 = 0
        var completing = false
        do {
            while sent < size {
                try Task.checkCancellation()
                let count = Int(min(UInt64(partSize), size - sent))
                guard let data = try file.read(upToCount: count), data.count == count else {
                    throw CocoaError(.fileReadUnknown)
                }
                var partQuery = query
                partQuery.queryItems!.append(URLQueryItem(name: "partNumber", value: String(parts.count + 1)))
                var partRequest = request
                partRequest.url = partQuery.url
                partRequest.httpMethod = "PUT"
                let part = try JSONDecoder().decode(Part.self, from: await send(partRequest, body: data).0)
                guard part.partNumber == parts.count + 1 else { throw URLError(.badServerResponse) }
                parts.append(part)
                sent += UInt64(data.count)
                progress?(Double(sent) / Double(size) * 0.99)
            }
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = try JSONEncoder().encode(Completion(key: session.key, uploadId: session.uploadId, parts: parts))
            try Task.checkCancellation()
            completing = true
            return try await send(request, body: body)
        } catch {
            // A lost completion response may hide success; never abort then.
            if !completing {
                var abort = request
                abort.url = query.url
                abort.httpMethod = "DELETE"
                abort.timeoutInterval = 10
                let abortRequest = abort
                _ = await Task.detached { try? await send(abortRequest) }.value
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let result: (Data, URLResponse)
        if let body {
            result = try await URLSession.shared.upload(for: request, from: body)
        } else {
            result = try await URLSession.shared.data(for: request)
        }
        guard let response = result.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else { throw UploadError.rejected(response.statusCode) }
        return result
    }
}
