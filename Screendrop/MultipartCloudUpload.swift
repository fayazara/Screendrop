import Foundation

/// Matches fayazara/screendrop-worker#6. Reads one bounded part at a time.
nonisolated enum MultipartCloudUpload {
    struct Result: Decodable, Sendable {
        let id: String
        let url: String
        let filename: String
        let size: Int
    }
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
    private struct ServerError: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    static func upload(
        fileURL: URL,
        request template: URLRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Result {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard size > 0 else { throw URLError(.zeroByteResource) }
        let partSize = 16 * 1024 * 1024
        guard size <= UInt64(partSize) * 10_000 else { throw URLError(.dataLengthExceedsMaximum) }
        guard let uploadURL = template.url else { throw URLError(.badURL) }
        var start = template
        start.url = uploadURL.appendingPathComponent("multipart")
        start.httpMethod = "POST"
        start.httpBody = nil
        let session = try JSONDecoder().decode(Session.self, from: await send(start, body: nil, retry: false))
        let sessionURL = start.url!.appendingPathComponent(session.id)
        var parts: [Part] = []
        var offset: UInt64 = 0
        var completing = false
        do {
            while offset < size {
                try Task.checkCancellation()
                let count = Int(min(UInt64(partSize), size - offset))
                guard let data = try handle.read(upToCount: count), data.count == count else {
                    throw CocoaError(.fileReadUnknown)
                }
                var components = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false)!
                components.queryItems = [
                    URLQueryItem(name: "key", value: session.key),
                    URLQueryItem(name: "uploadId", value: session.uploadId),
                    URLQueryItem(name: "partNumber", value: String(parts.count + 1)),
                ]
                var partRequest = template
                partRequest.url = components.url
                partRequest.httpMethod = "PUT"
                partRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let part = try JSONDecoder().decode(Part.self, from: await send(partRequest, body: data, retry: true))
                guard part.partNumber == parts.count + 1 else { throw URLError(.badServerResponse) }
                parts.append(part)
                offset += UInt64(data.count)
                progress?(Double(offset) / Double(size) * 0.99)
            }
            var complete = template
            complete.url = sessionURL
            complete.httpMethod = "POST"
            complete.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = try JSONEncoder().encode(Completion(key: session.key, uploadId: session.uploadId, parts: parts))
            completing = true
            let result = try JSONDecoder().decode(Result.self, from: await send(complete, body: body, retry: true))
            guard result.size == Int(size) else { throw URLError(.badServerResponse) }
            progress?(1)
            return result
        } catch {
            // Never abort after completion starts: a lost response can hide a
            // successful commit. A fresh task also permits cleanup on cancel.
            if !completing {
                var components = URLComponents(url: sessionURL, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "key", value: session.key), URLQueryItem(name: "uploadId", value: session.uploadId)]
                var abort = template
                abort.url = components.url
                abort.httpMethod = "DELETE"
                let abortRequest = abort
                _ = await Task.detached { try? await send(abortRequest, body: nil, retry: true) }.value
            }
            throw error
        }
    }

    private static func send(_ request: URLRequest, body: Data?, retry: Bool) async throws -> Data {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                let response: (Data, URLResponse)
                if let body {
                    response = try await URLSession.shared.upload(for: request, from: body)
                } else {
                    response = try await URLSession.shared.data(for: request)
                }
                guard let http = response.1 as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard (200..<300).contains(http.statusCode) else {
                    let message: String
                    if http.statusCode == 404 {
                        message = "The cloud server needs the multipart upload update."
                    } else if http.statusCode == 413 {
                        message = "The cloud server rejected the upload size."
                    } else {
                        message = "Cloud upload failed (HTTP \(http.statusCode))."
                    }
                    throw ServerError(status: http.statusCode, message: message)
                }
                return response.0
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let transient: Bool
                if let server = error as? ServerError {
                    transient = server.status == 429 || server.status >= 500
                } else {
                    transient = error is URLError
                }
                guard retry, transient, attempt < 3 else { throw error }
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw URLError(.unknown)
    }
}
