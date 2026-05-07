//
//  S3CloudService.swift
//  OpenShot
//
//  Direct S3-compatible upload to Cloudflare R2.
//  Ported from BucketDrop's S3Service — uses AWS Signature V4 with CryptoKit.
//  No external dependencies.
//

import CryptoKit
import Foundation

/// Lightweight S3-compatible upload client for Cloudflare R2.
///
/// Uses `actor` isolation (not `@MainActor`) so upload work stays off the main thread.
/// All credential reads happen through `CloudCredentialStore.shared` which is `@MainActor`,
/// so we snapshot credentials at the start of each call.
actor S3CloudService {
    static let shared = S3CloudService()

    struct UploadResult: Sendable {
        let r2Key: String
        let publicURL: String
    }

    struct S3Error: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Upload

    /// Upload a file directly to R2 via S3 PUT.
    /// - Parameters:
    ///   - fileURL: Local file URL to upload.
    ///   - r2Key: The R2 object key (e.g. `uploads/{id}/{filename}`).
    ///   - progress: Optional progress callback (0.0 to 1.0), called on arbitrary queue.
    func upload(
        fileURL: URL,
        r2Key: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> UploadResult {
        let creds = await CloudCredentialStore.shared.snapshot()

        guard creds.isConfigured else {
            throw S3Error(message: "R2 credentials not configured. Set them in Settings → Cloud.")
        }

        let data = try Data(contentsOf: fileURL)
        let contentType = mimeType(for: fileURL.pathExtension)

        try await putObject(
            key: r2Key,
            data: data,
            contentType: contentType,
            creds: creds,
            progress: progress
        )

        let publicURL = buildPublicURL(key: r2Key, creds: creds)
        return UploadResult(r2Key: r2Key, publicURL: publicURL)
    }

    /// Test the R2 connection by listing objects (max 1).
    func testConnection() async throws {
        let creds = await CloudCredentialStore.shared.snapshot()

        guard creds.isConfigured else {
            throw S3Error(message: "R2 credentials not configured.")
        }

        let host = buildHost(creds: creds)
        let endpoint = buildEndpoint(creds: creds)
        let signingPath = buildSigningPath(objectKey: nil, creds: creds)

        let urlString = "\(endpoint)/?list-type=2&max-keys=1"
        guard let url = URL(string: urlString) else {
            throw S3Error(message: "Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let headers = try signRequest(
            method: "GET",
            path: signingPath,
            query: "list-type=2&max-keys=1",
            headers: ["host": host],
            payload: Data(),
            creds: creds
        )

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw S3Error(message: "Connection failed: HTTP \(http.statusCode) — \(body)")
        }
    }

    // MARK: - Private

    private func putObject(
        key: String,
        data: Data,
        contentType: String,
        creds: CloudCredentials,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let host = buildHost(creds: creds)
        let endpoint = buildEndpoint(creds: creds)
        let encodedKey = awsURLEncodePath(key)
        let signingPath = buildSigningPath(objectKey: key, creds: creds)

        guard let url = URL(string: "\(endpoint)/\(encodedKey)") else {
            throw S3Error(message: "Invalid URL for key: \(key)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        let headers = try signRequest(
            method: "PUT",
            path: signingPath,
            query: "",
            headers: [
                "host": host,
                "content-type": contentType,
            ],
            payload: data,
            creds: creds
        )

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let progressDelegate = S3UploadProgressDelegate { sent, expected in
            guard expected > 0 else { return }
            progress?(min(1, Double(sent) / Double(expected)))
        }

        let (responseData, response) = try await URLSession.shared.upload(
            for: request,
            from: data,
            delegate: progressDelegate
        )

        guard let http = response as? HTTPURLResponse else {
            throw S3Error(message: "Invalid response")
        }

        guard http.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw S3Error(message: "Upload failed: HTTP \(http.statusCode) — \(body)")
        }

        progress?(1)
    }

    // MARK: - URL Building

    private func isCustomEndpoint(_ creds: CloudCredentials) -> Bool {
        !creds.endpoint.isEmpty
    }

    private func buildHost(creds: CloudCredentials) -> String {
        if isCustomEndpoint(creds) {
            if let url = URL(string: creds.endpoint), let host = url.host {
                return host
            }
        }
        return "\(creds.bucket).s3.\(creds.region).amazonaws.com"
    }

    private func buildEndpoint(creds: CloudCredentials) -> String {
        if isCustomEndpoint(creds) {
            let base = creds.endpoint.hasSuffix("/") ? String(creds.endpoint.dropLast()) : creds.endpoint
            return "\(base)/\(creds.bucket)"
        }
        return "https://\(creds.bucket).s3.\(creds.region).amazonaws.com"
    }

    private func buildSigningPath(objectKey: String?, creds: CloudCredentials) -> String {
        if isCustomEndpoint(creds) {
            if let key = objectKey {
                return "/\(creds.bucket)/\(awsURLEncodePath(key))"
            }
            return "/\(creds.bucket)/"
        }
        if let key = objectKey {
            return "/\(awsURLEncodePath(key))"
        }
        return "/"
    }

    private func buildPublicURL(key: String, creds: CloudCredentials) -> String {
        let encodedKey = awsURLEncodePath(key)
        if !creds.publicURLBase.isEmpty {
            let base = creds.publicURLBase.hasSuffix("/") ? String(creds.publicURLBase.dropLast()) : creds.publicURLBase
            return "\(base)/\(encodedKey)"
        }
        return "\(buildEndpoint(creds: creds))/\(encodedKey)"
    }

    // MARK: - AWS Signature V4

    private func signRequest(
        method: String,
        path: String,
        query: String,
        headers: [String: String],
        payload: Data,
        creds: CloudCredentials
    ) throws -> [String: String] {
        let accessKey = creds.accessKeyId
        let secretKey = creds.secretAccessKey
        let region = creds.region
        let service = "s3"

        let now = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        dateFormatter.timeZone = TimeZone(identifier: "UTC")

        let amzDate = dateFormatter.string(from: now)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        let dateStamp = String(amzDate.prefix(8))

        let payloadHash = SHA256.hash(data: payload).s3HexString

        var allHeaders = headers
        allHeaders["x-amz-date"] = amzDate
        allHeaders["x-amz-content-sha256"] = payloadHash

        let sortedHeaders = allHeaders.sorted { $0.key.lowercased() < $1.key.lowercased() }
        let canonicalHeaders = sortedHeaders
            .map { "\($0.key.lowercased()):\($0.value.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n") + "\n"
        let signedHeaders = sortedHeaders.map { $0.key.lowercased() }.joined(separator: ";")

        let canonicalRequest = [
            method,
            path,
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let canonicalRequestHash = SHA256.hash(data: Data(canonicalRequest.utf8)).s3HexString

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            canonicalRequestHash,
        ].joined(separator: "\n")

        let kDate = hmacSHA256(key: Data("AWS4\(secretKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8)).s3HexString

        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var result = allHeaders
        result["authorization"] = authorization
        return result
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(signature)
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private func awsURLEncodePath(_ path: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return path
            .split(separator: "/")
            .map { segment in
                segment.addingPercentEncoding(withAllowedCharacters: unreserved) ?? String(segment)
            }
            .joined(separator: "/")
    }
}

// MARK: - Upload Progress Delegate

private final class S3UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}

// MARK: - Hex String Helpers (namespaced to avoid collisions with BucketDrop extensions)

private extension SHA256Digest {
    var s3HexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    var s3HexString: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}
