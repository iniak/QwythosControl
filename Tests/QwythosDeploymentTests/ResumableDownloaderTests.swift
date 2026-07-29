import Darwin
import Foundation
import XCTest
@testable import QwythosDeployment

final class ResumableDownloaderTests: XCTestCase {
    func testCreatesNewRootAndDownloadsDirectoryWithoutFollowingAncestors() async throws {
        let base = URL(fileURLWithPath: "/private/tmp").appending(path: UUID().uuidString)
        let partial = base
            .appendingPathComponent("new-root", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent("fixture.partial")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let artifact = DeploymentArtifact(
            filename: "fixture.partial",
            sourceURL: URL(string: "https://fixture.invalid/file")!,
            size: 0,
            sha256: "fixed"
        )
        let downloader = ResumableDownloader(hasher: FixedHash())
        _ = try await downloader.download(
            artifact: artifact,
            partialURL: partial
        ) { _ in }

        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.deletingLastPathComponent().path))
    }

    func testRejectsSymlinkAncestorWhileCreatingNewRoot() async throws {
        let base = canonicalTemporaryDirectory()
            .appending(path: UUID().uuidString)
        let outside = base.appending(path: "outside")
        let linked = base.appending(path: "linked")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        do {
            _ = try await ResumableDownloader(hasher: FixedHash()).download(
                artifact: DeploymentArtifact(filename: "fixture.partial", sourceURL: URL(string: "https://fixture.invalid/file")!, size: 0, sha256: "fixed"),
                partialURL: linked.appending(path: "new-root/downloads/fixture.partial")
            ) { _ in }
            XCTFail("A symlink ancestor must be rejected")
        } catch {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appending(path: "new-root").path))
    }

    func testRejectsReplacedDownloadDirectoryWithoutWritingOutsideRoot() async throws {
        let base = canonicalTemporaryDirectory()
            .appending(path: UUID().uuidString)
        let root = base.appending(path: "root")
        let outside = base.appending(path: "outside")
        let downloads = root.appending(path: "downloads")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: downloads, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: base) }

        do {
            _ = try await ResumableDownloader().download(
                artifact: artifact(for: Data("a".utf8), sourceURL: URL(string: "https://fixture.invalid/file")!),
                partialURL: downloads.appending(path: "fixture.partial")
            ) { _ in }
            XCTFail("A symlinked downloads directory must be rejected")
        } catch {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appending(path: "fixture.partial").path))
    }

    func testResumesFromExistingPartialFile() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(payload: payload)
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        try Data(payload.prefix(4)).write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let recorder = ProgressRecorder()
        let result = try await ResumableDownloader().download(
            artifact: artifact(for: payload, sourceURL: server.url),
            partialURL: partialURL
        ) { progress in
            recorder.append(progress)
        }

        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(server.requests.last?.rangeHeader, "bytes=4-")
        let finalProgress = try XCTUnwrap(recorder.values.last)
        XCTAssertEqual(finalProgress.completedBytes, Int64(payload.count))
        XCTAssertEqual(finalProgress.totalBytes, Int64(payload.count))
        XCTAssertGreaterThan(finalProgress.bytesPerSecond, 0)
        XCTAssertEqual(finalProgress.estimatedTimeRemaining, 0)
    }

    func testRestartsWhenServerIgnoresRange() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(rangeHandling: .ignore)
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        try Data(payload.prefix(4)).write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let result = try await ResumableDownloader().download(
            artifact: artifact(for: payload, sourceURL: server.url),
            partialURL: partialURL
        ) { _ in }

        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(server.requests.last?.rangeHeader, "bytes=4-")
    }

    func testCorruptCompletePartialResetsAndRetriesFromZero() async throws {
        let payload = Data("abcdefgh".utf8)
        let transport = DownloadURLProtocolFixture(payload: payload)
        defer { transport.invalidate() }

        let partialURL = temporaryPartialURL()
        try Data("xxxxxxxx".utf8).write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let result = try await ResumableDownloader(
            sessionConfiguration: transport.sessionConfiguration
        ).download(
            artifact: artifact(for: payload, sourceURL: transport.url),
            partialURL: partialURL
        ) { _ in }

        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(transport.rangeHeaders.count, 1)
        XCTAssertNil(transport.rangeHeaders.first!)
    }

    func testCorruptPrefixResetsAfterFailedResumeAndRetriesFromZero() async throws {
        let payload = Data("abcdefgh".utf8)
        let transport = DownloadURLProtocolFixture(payload: payload)
        defer { transport.invalidate() }

        let partialURL = temporaryPartialURL()
        try Data("xxxx".utf8).write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let result = try await ResumableDownloader(
            sessionConfiguration: transport.sessionConfiguration
        ).download(
            artifact: artifact(for: payload, sourceURL: transport.url),
            partialURL: partialURL
        ) { _ in }

        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(
            transport.rangeHeaders,
            ["bytes=4-", nil]
        )
    }

    func testCompletedPartialReplacementDuringHashFailsClosed() async throws {
        let payload = Data("abcdefgh".utf8)
        let replacement = Data("replaced".utf8)
        let partialURL = temporaryPartialURL()
        try payload.write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let downloader = ResumableDownloader(
            hasher: ReplacingDownloadHasher(
                fileURL: partialURL,
                replacement: replacement,
                digest: "9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab"
            )
        )

        do {
            _ = try await downloader.download(
                artifact: artifact(
                    for: payload,
                    sourceURL: URL(string: "https://fixture.invalid/file")!
                ),
                partialURL: partialURL
            ) { _ in }
            XCTFail("A replacement at the verified pathname must be rejected")
        } catch {
            XCTAssertEqual(
                error as? POSIXTransactionError,
                .ownershipChanged
            )
        }
        XCTAssertEqual(try Data(contentsOf: partialURL), replacement)
    }

    func testRetriesAfterTransientDisconnect() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(transientDisconnects: 1)
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let result = try await ResumableDownloader().download(
            artifact: artifact(for: payload, sourceURL: server.url),
            partialURL: partialURL
        ) { _ in }

        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testCancellationPreservesPartialFile() async throws {
        let payload = Data(repeating: 0x61, count: 64)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(chunkSize: 1, chunkDelay: 0.05)
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        try Data(payload.prefix(1)).write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }
        let downloadArtifact = artifact(for: payload, sourceURL: server.url)
        let downloader = ResumableDownloader()
        let task = Task.detached {
            try await downloader.download(
                artifact: downloadArtifact,
                partialURL: partialURL
            ) { _ in }
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let taskResult = await task.result

        XCTAssertThrowsError(try taskResult.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let partialSize = try FileManager.default.attributesOfItem(atPath: partialURL.path)[.size] as? Int
        XCTAssertNotNil(partialSize)
        XCTAssertGreaterThanOrEqual(partialSize ?? 0, 1)
        XCTAssertLessThan(partialSize ?? payload.count, payload.count)
        XCTAssertEqual(server.requests.last?.rangeHeader, "bytes=1-")
    }

    func testRejectsContentLengthMismatch() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(contentLength: payload.count - 1)
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        defer { try? FileManager.default.removeItem(at: partialURL) }

        let expected = ResumableDownloadError.contentLengthMismatch(expected: 8, actual: 7)
        await assertDownloadError(expected) {
            try await ResumableDownloader().download(
                artifact: artifact(for: payload, sourceURL: server.url),
                partialURL: partialURL
            ) { _ in }
        }
    }

    func testRejectsSHA256Mismatch() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(payload: payload)
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        defer { try? FileManager.default.removeItem(at: partialURL) }
        var invalidArtifact = artifact(for: payload, sourceURL: server.url)
        invalidArtifact = DeploymentArtifact(
            filename: invalidArtifact.filename,
            sourceURL: invalidArtifact.sourceURL,
            size: invalidArtifact.size,
            sha256: String(repeating: "0", count: 64)
        )

        await assertDownloadError(
            .checksumMismatch(
                expected: String(repeating: "0", count: 64),
                actual: "9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab"
            )
        ) {
            try await ResumableDownloader().download(
                artifact: invalidArtifact,
                partialURL: partialURL
            ) { _ in }
        }
    }

    func testRejectsMissingContentRangeWithExactError() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(contentRangeHandling: .omitted)
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        try Data(payload.prefix(4)).write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }

        await assertDownloadError(.invalidContentRange(nil)) {
            try await ResumableDownloader().download(
                artifact: artifact(for: payload, sourceURL: server.url),
                partialURL: partialURL
            ) { _ in }
        }
    }

    func testRejectsMalformedContentRangeWithExactError() async throws {
        let payload = Data("abcdefgh".utf8)
        let malformedRange = "bytes nope"
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(contentRangeHandling: .overridden(malformedRange))
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        try Data(payload.prefix(4)).write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }

        await assertDownloadError(.invalidContentRange(malformedRange)) {
            try await ResumableDownloader().download(
                artifact: artifact(for: payload, sourceURL: server.url),
                partialURL: partialURL
            ) { _ in }
        }
    }

    func testRejectsBodyOverrunWithoutWritingExcessBytes() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(includesContentLength: false)
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        defer { try? FileManager.default.removeItem(at: partialURL) }
        let artifact = DeploymentArtifact(
            filename: "fixture.bin",
            sourceURL: server.url,
            size: 4,
            sha256: "88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589"
        )

        await assertDownloadError(.contentLengthMismatch(expected: 4, actual: 8)) {
            try await ResumableDownloader().download(
                artifact: artifact,
                partialURL: partialURL
            ) { _ in }
        }
        XCTAssertEqual(try Data(contentsOf: partialURL), Data())
    }

    func testRetriesHTTP503ExactlyThreeTimesBeforeFailing() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(statusCodes: [503, 503, 503, 503])
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        defer { try? FileManager.default.removeItem(at: partialURL) }

        await assertDownloadError(.unexpectedHTTPStatus(503)) {
            try await ResumableDownloader().download(
                artifact: artifact(for: payload, sourceURL: server.url),
                partialURL: partialURL
            ) { _ in }
        }
        XCTAssertEqual(server.requests.count, 4)
    }

    func testCancellationBeforeRangeIgnoringResponsePreservesSeededPartial() async throws {
        let payload = Data("abcdefgh".utf8)
        let server = try RangeHTTPServer(
            payload: payload,
            configuration: .init(rangeHandling: .ignore, responseDelay: 0.2)
        )
        try server.start()
        defer { server.stop() }

        let partialURL = temporaryPartialURL()
        let seededPartial = Data(payload.prefix(4))
        try seededPartial.write(to: partialURL)
        defer { try? FileManager.default.removeItem(at: partialURL) }
        let downloader = ResumableDownloader()
        let downloadArtifact = artifact(for: payload, sourceURL: server.url)
        let task = Task.detached {
            try await downloader.download(
                artifact: downloadArtifact,
                partialURL: partialURL
            ) { _ in }
        }

        for _ in 0..<50 where server.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: partialURL), seededPartial)
        XCTAssertEqual(server.requests.last?.rangeHeader, "bytes=4-")
    }

    private func artifact(for payload: Data, sourceURL: URL) -> DeploymentArtifact {
        DeploymentArtifact(
            filename: "fixture.bin",
            sourceURL: sourceURL,
            size: Int64(payload.count),
            sha256: "9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab"
        )
    }

    private func temporaryPartialURL() -> URL {
        canonicalTemporaryDirectory()
            .appending(path: UUID().uuidString)
            .appendingPathExtension("partial")
    }

    private func canonicalTemporaryDirectory() -> URL {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        guard let resolvedPath = realpath(temporaryPath, nil) else {
            preconditionFailure(
                "Could not resolve test temporary directory: \(temporaryPath)"
            )
        }
        defer { free(resolvedPath) }
        return URL(
            fileURLWithPath: String(cString: resolvedPath),
            isDirectory: true
        )
    }

    private func assertDownloadError(
        _ expected: ResumableDownloadError,
        operation: () async throws -> URL
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? ResumableDownloadError, expected)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DownloadProgress] = []

    func append(_ value: DownloadProgress) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [DownloadProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct FixedHash: FileHashing {
    func sha256(file: URL) throws -> String { "fixed" }
}

private final class ReplacingDownloadHasher: FileHashing, @unchecked Sendable {
    private let fileURL: URL
    private let replacement: Data
    private let digest: String
    private let lock = NSLock()
    private var hasReplaced = false

    init(fileURL: URL, replacement: Data, digest: String) {
        self.fileURL = fileURL
        self.replacement = replacement
        self.digest = digest
    }

    func sha256(file: URL) throws -> String {
        try replaceOnce()
        return digest
    }

    func sha256(fileDescriptor: Int32) throws -> String {
        try replaceOnce()
        return digest
    }

    private func replaceOnce() throws {
        let shouldReplace = lock.withLock {
            guard !hasReplaced else { return false }
            hasReplaced = true
            return true
        }
        guard shouldReplace else { return }
        let temporary = fileURL.deletingLastPathComponent()
            .appending(path: ".replacement-\(UUID().uuidString)")
        try replacement.write(to: temporary)
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
    }
}

private final class DownloadURLProtocolFixture: @unchecked Sendable {
    let url = URL(string: "https://download-fixture.invalid/\(UUID().uuidString)")!
    let sessionConfiguration: URLSessionConfiguration

    private let lock = NSLock()
    private var recordedRangeHeaders: [String?] = []

    init(payload: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        sessionConfiguration = configuration
        DownloadURLProtocol.register(url: url) { [weak self] request in
            let range = request.value(forHTTPHeaderField: "Range")
            self?.lock.withLock {
                self?.recordedRangeHeaders.append(range)
            }
            if range == nil {
                return DownloadURLProtocol.Response(
                    statusCode: 200,
                    headers: [
                        "Content-Length": String(payload.count),
                    ],
                    body: payload
                )
            }
            let start = Int(range?.dropFirst("bytes=".count).dropLast() ?? "")
                ?? 0
            let body = Data(payload.dropFirst(start))
            return DownloadURLProtocol.Response(
                statusCode: 206,
                headers: [
                    "Content-Length": String(body.count),
                    "Content-Range":
                        "bytes \(start)-\(payload.count - 1)/\(payload.count)",
                ],
                body: body
            )
        }
    }

    var rangeHeaders: [String?] {
        lock.withLock { recordedRangeHeaders }
    }

    func invalidate() {
        DownloadURLProtocol.unregister(url: url)
    }
}

private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers:
        [URL: @Sendable (URLRequest) -> Response] = [:]

    static func register(
        url: URL,
        handler: @escaping @Sendable (URLRequest) -> Response
    ) {
        lock.withLock {
            handlers[url] = handler
        }
    }

    static func unregister(url: URL) {
        lock.withLock {
            handlers[url] = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return lock.withLock { handlers[url] != nil }
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.lock.withLock({
                  Self.handlers[url]
              }) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }
        let response = handler(request)
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
