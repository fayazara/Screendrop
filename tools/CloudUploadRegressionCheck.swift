import Foundation

/// Invoked by check-cloud-uploads.py against its local fault-injection server.
@main struct CloudUploadRegressionCheck {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let small = URL(fileURLWithPath: CommandLine.arguments[2])
        let large = URL(fileURLWithPath: CommandLine.arguments[3])
        func request(_ scenario: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "\(base)/\(scenario)/api/upload")!)
            request.httpMethod = "PUT"
            request.timeoutInterval = 2
            request.setValue("Bearer local-test-token", forHTTPHeaderField: "Authorization")
            request.setValue("recording.mov", forHTTPHeaderField: "X-Filename")
            request.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
            return request
        }

        for (scenario, file) in [("single", small), ("multipart", large)] {
            let result = try await CloudUploadRequest.uploadFile(at: file, request: request(scenario), progress: nil)
            let expected = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            precondition(result.size == expected)
            print("PASS \(scenario)")
        }

        for status in [404, 405] {
            do {
                _ = try await CloudUploadRequest.uploadFile(at: large, request: request("unsupported\(status)"), progress: nil)
                fatalError("Expected an unsupported Worker error")
            } catch {
                precondition(error.localizedDescription.contains("Update your Screendrop Cloud Worker"))
            }
        }
        print("PASS older Worker guidance")

        for (scenario, code) in [("early413", 413), ("unauthorized", 401)] {
            do {
                _ = try await CloudUploadRequest.send(request(scenario), body: Data(count: 4 * 1024 * 1024))
                fatalError("Expected HTTP \(code)")
            } catch let error as CloudUploadHTTPError {
                precondition(error.statusCode == code)
            }
        }
        print("PASS HTTP rejection preservation")

        do {
            _ = try await CloudUploadRequest.send(request("timeout"), body: nil)
            fatalError("Expected a timeout")
        } catch let error as URLError {
            precondition(error.code == .timedOut)
        }
        print("PASS timeout without HTTP remains a timeout")

        for (scenario, code) in [("part404", 404), ("complete503", 503)] {
            do {
                _ = try await CloudUploadRequest.uploadFile(at: large, request: request(scenario), progress: nil)
                fatalError("Expected HTTP \(code)")
            } catch let error as CloudUploadHTTPError {
                precondition(error.statusCode == code)
                precondition(!error.localizedDescription.contains("Update your Screendrop Cloud Worker"))
            }
        }
        print("PASS part failure and ambiguous completion")

        let cancellationRequest = request("cancel")
        let progress = AsyncStream<Double>.makeStream()
        let task = Task {
            try await CloudUploadRequest.uploadFile(at: large, request: cancellationRequest) {
                progress.continuation.yield($0)
            }
        }
        var iterator = progress.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do {
            _ = try await task.value
            fatalError("Expected cancellation")
        } catch is CancellationError {}
        progress.continuation.finish()
        print("PASS cancellation")
    }
}
