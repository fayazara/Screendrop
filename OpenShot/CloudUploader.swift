//
//  CloudUploader.swift
//  OpenShot
//
//  Uploads screenshots to the OpenShot Cloud worker.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

struct CloudUploadResult {
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
    
    /// Active URLSession delegate adapters keyed by task ID.
    private var delegates: [Int: UploadDelegate] = [:]
    
    /// Active upload tasks keyed by item ID (for cancellation).
    private var activeTasks: [UUID: URLSessionUploadTask] = [:]
    
    /// Timers for animating the "server processing" phase (80%→95%).
    private var processingTimers: [UUID: Timer] = [:]
    
    private var _session: URLSession?
    
    private var session: URLSession {
        if let existing = _session { return existing }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        let newSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        _session = newSession
        return newSession
    }
    
    private override init() {
        super.init()
    }
    
    var isConfigured: Bool {
        OpenShotPreferences.isCloudConfigured
    }
    
    func upload(itemID: UUID, fileURL: URL) async throws -> CloudUploadResult {
        guard isConfigured else {
            throw CloudUploadError.notConfigured
        }
        
        let rawURL = OpenShotPreferences.cloudWorkerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let workerBase = rawURL.lowercased().hasPrefix("http") ? rawURL : "https://\(rawURL)"
        let token = OpenShotPreferences.cloudUploadToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let uploadURL = URL(string: "\(workerBase)/api/upload") else {
            throw CloudUploadError.invalidURL
        }
        
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let fileName = fileURL.lastPathComponent
        let mimeType = mimeTypeForFile(fileURL)
        let dimensions = imageDimensions(at: fileURL)
        
        let boundary = UUID().uuidString
        var body = Data()
        
        // File part
        body.appendMultipart(boundary: boundary, name: "file", fileName: fileName, mimeType: mimeType, data: fileData)
        
        // Width
        if let width = dimensions?.width {
            body.appendMultipart(boundary: boundary, name: "width", value: "\(width)")
        }
        
        // Height
        if let height = dimensions?.height {
            body.appendMultipart(boundary: boundary, name: "height", value: "\(height)")
        }
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        uploadingItems.insert(itemID)
        uploadProgress[itemID] = 0
        
        do {
            let result = try await performUpload(request: request, body: body, itemID: itemID)
            activeTasks.removeValue(forKey: itemID)
            stopProcessingAnimation(for: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            uploadedURLs[itemID] = result.url
            return result
        } catch {
            activeTasks.removeValue(forKey: itemID)
            stopProcessingAnimation(for: itemID)
            uploadingItems.remove(itemID)
            uploadProgress.removeValue(forKey: itemID)
            failedItemIDs.insert(itemID)
            throw error
        }
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
    
    // MARK: - Private
    
    private func performUpload(request: URLRequest, body: Data, itemID: UUID) async throws -> CloudUploadResult {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, from: body) { [weak self] data, response, error in
                guard let self else { return }
                
                self.delegates.removeValue(forKey: 0) // Cleaned up below
                
                if let error {
                    continuation.resume(throwing: CloudUploadError.networkError(error))
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    continuation.resume(throwing: CloudUploadError.invalidResponse)
                    return
                }
                
                guard let data else {
                    continuation.resume(throwing: CloudUploadError.invalidResponse)
                    return
                }
                
                guard httpResponse.statusCode == 201 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: CloudUploadError.serverError(httpResponse.statusCode, body))
                    return
                }
                
                do {
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    guard let id = json?["id"] as? String,
                          let url = json?["url"] as? String,
                          let filename = json?["filename"] as? String,
                          let size = json?["size"] as? Int else {
                        continuation.resume(throwing: CloudUploadError.invalidResponse)
                        return
                    }
                    
                    continuation.resume(returning: CloudUploadResult(id: id, url: url, filename: filename, size: size))
                } catch {
                    continuation.resume(throwing: CloudUploadError.invalidResponse)
                }
            }
            
            let delegate = UploadDelegate(itemID: itemID)
            delegates[task.taskIdentifier] = delegate
            activeTasks[itemID] = task
            
            task.resume()
        }
    }
    
    func cancelUpload(for itemID: UUID) {
        activeTasks[itemID]?.cancel()
        activeTasks.removeValue(forKey: itemID)
        stopProcessingAnimation(for: itemID)
        uploadingItems.remove(itemID)
        uploadProgress.removeValue(forKey: itemID)
    }
    
    private func startProcessingAnimation(for itemID: UUID) {
        guard processingTimers[itemID] == nil else { return }
        // Animate from current (~80%) toward 95% in small increments
        processingTimers[itemID] = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let current = self.uploadProgress[itemID] ?? 0.8
            if current < 0.95 {
                self.uploadProgress[itemID] = current + 0.02
            } else {
                timer.invalidate()
                self.processingTimers.removeValue(forKey: itemID)
            }
        }
    }
    
    private func stopProcessingAnimation(for itemID: UUID) {
        processingTimers[itemID]?.invalidate()
        processingTimers.removeValue(forKey: itemID)
    }
    
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
    
    private final class UploadDelegate {
        let itemID: UUID
        init(itemID: UUID) { self.itemID = itemID }
    }
}

// MARK: - URLSessionTaskDelegate

extension CloudUploader: URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let taskID = task.taskIdentifier
        MainActor.assumeIsolated {
            guard let delegate = delegates[taskID] else { return }
            let rawProgress = totalBytesExpectedToSend > 0
                ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
                : 0
            // Bytes-sent drives 0–80%; server processing fills 80–100% via animation
            uploadProgress[delegate.itemID] = rawProgress * 0.8
            
            // When all bytes are sent, start animating toward 100%
            if rawProgress >= 1.0 {
                startProcessingAnimation(for: delegate.itemID)
            }
        }
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
            "Cloud upload is not configured. Set the worker URL and token in Settings."
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

// MARK: - Data Multipart Helpers

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, fileName: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }
    
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
    }
}
