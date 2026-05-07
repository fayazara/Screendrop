//
//  CloudUploader.swift
//  OpenShot
//
//  Uploads screenshots to R2 directly via S3 API, then registers metadata
//  with the OpenShot Cloud worker for shareable URLs.
//
//  Flow:
//  1. PUT file to R2 using S3CloudService (AWS Sig V4, no size limit)
//  2. POST /api/register to the Hono worker with the R2 key + metadata
//  3. Worker inserts into D1, returns the shareable short URL
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

struct CloudUploadResult: Sendable {
    let id: String
    let url: String
    let filename: String
    let size: Int
}

@MainActor
@Observable
final class CloudUploader: NSObject {
    static let shared = CloudUploader()

    /// Upload progress keyed by preview item ID.
    private(set) var uploadProgress: [UUID: Double] = [:]

    /// Set of item IDs currently uploading.
    private(set) var uploadingItems: Set<UUID> = []

    /// Completed upload URLs keyed by preview item ID.
    private(set) var uploadedURLs: [UUID: String] = [:]

    /// Set of item IDs whose upload failed (cleared after shake animation).
    private(set) var failedItemIDs: Set<UUID> = []

    /// Active upload tasks keyed by item ID (for cancellation).
    private var activeTasks: [UUID: Task<CloudUploadResult, any Error>] = [:]

    private override init() {
        super.init()
    }

    var isConfigured: Bool {
        CloudCredentialStore.shared.isFullyConfigured
    }

    func upload(itemID: UUID, fileURL: URL) async throws -> CloudUploadResult {
        guard isConfigured else {
            throw CloudUploadError.notConfigured
        }

        let creds = CloudCredentialStore.shared.snapshot()
        let fileName = fileURL.lastPathComponent
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let dimensions = imageDimensions(at: fileURL)
        let mimeType = mimeTypeForFile(fileURL)

        // Generate the R2 key in the same format the worker uses
        let shortID = UUID().uuidString.split(separator: "-").first.map(String.init) ?? UUID().uuidString.prefix(8).description
        let r2Key = "uploads/\(shortID)/\(fileName)"

        uploadingItems.insert(itemID)
        uploadProgress[itemID] = 0

        let uploadTask = Task { [weak self] () throws -> CloudUploadResult in
            // Phase 1: Upload directly to R2 via S3 API (0% → 80%)
            let _ = try await S3CloudService.shared.upload(
                fileURL: fileURL,
                r2Key: r2Key,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.uploadProgress[itemID] = fraction * 0.8
                    }
                }
            )

            try Task.checkCancellation()

            await MainActor.run { [weak self] in
                self?.uploadProgress[itemID] = 0.85
            }

            // Phase 2: Register metadata with the worker (80% → 100%)
            guard let self else { throw CloudUploadError.invalidResponse }

            let result = try await self.registerWithWorker(
                r2Key: r2Key,
                filename: fileName,
                contentType: mimeType,
                size: fileData.count,
                width: dimensions?.width,
                height: dimensions?.height,
                creds: creds
            )

            return result
        }

        activeTasks[itemID] = uploadTask

        do {
            let result = try await uploadTask.value
            activeTasks.removeValue(forKey: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            uploadedURLs[itemID] = result.url
            return result
        } catch is CancellationError {
            activeTasks.removeValue(forKey: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            throw CancellationError()
        } catch {
            activeTasks.removeValue(forKey: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            failedItemIDs.insert(itemID)
            throw error
        }
    }

    func cancelUpload(for itemID: UUID) {
        activeTasks[itemID]?.cancel()
        activeTasks.removeValue(forKey: itemID)
        uploadingItems.remove(itemID)
        uploadProgress.removeValue(forKey: itemID)
    }

    func clearUploadState(for itemID: UUID) {
        uploadingItems.remove(itemID)
        uploadProgress.removeValue(forKey: itemID)
        uploadedURLs.removeValue(forKey: itemID)
        failedItemIDs.remove(itemID)
    }

    func clearFailed(for itemID: UUID) {
        failedItemIDs.remove(itemID)
    }

    // MARK: - Worker Registration

    /// Calls POST /api/register on the worker to create the D1 metadata row.
    nonisolated private func registerWithWorker(
        r2Key: String,
        filename: String,
        contentType: String,
        size: Int,
        width: Int?,
        height: Int?,
        creds: CloudCredentials
    ) async throws -> CloudUploadResult {
        let rawURL = creds.workerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let workerBase = rawURL.lowercased().hasPrefix("http") ? rawURL : "https://\(rawURL)"
        let token = creds.uploadToken
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let registerURL = URL(string: "\(workerBase)/api/register") else {
            throw CloudUploadError.invalidURL
        }

        var body: [String: Any] = [
            "r2_key": r2Key,
            "filename": filename,
            "content_type": contentType,
            "size": size,
        ]
        if let width { body["width"] = width }
        if let height { body["height"] = height }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: registerURL)
        request.httpMethod = "POST"
        request.httpBody = jsonData
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CloudUploadError.invalidResponse
        }

        guard http.statusCode == 201 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw CloudUploadError.serverError(http.statusCode, responseBody)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String,
              let url = json?["url"] as? String,
              let name = json?["filename"] as? String,
              let fileSize = json?["size"] as? Int else {
            throw CloudUploadError.invalidResponse
        }

        return CloudUploadResult(id: id, url: url, filename: name, size: fileSize)
    }

    // MARK: - Helpers

    private func mimeTypeForFile(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    private func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }
}

// MARK: - Errors

enum CloudUploadError: LocalizedError {
    case notConfigured
    case invalidURL
    case networkError(Error)
    case serverError(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Cloud upload is not configured. Set R2 credentials and worker URL in Settings."
        case .invalidURL:
            "Invalid worker URL."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .serverError(let code, let body):
            "Server error (\(code)): \(body)"
        case .invalidResponse:
            "Invalid response from server."
        }
    }
}
