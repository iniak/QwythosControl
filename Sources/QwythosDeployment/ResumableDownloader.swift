import Foundation

public struct DownloadProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double
    public let estimatedTimeRemaining: TimeInterval?

    public init(
        completedBytes: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

public protocol ArtifactDownloading: Sendable {
    func download(
        artifact: DeploymentArtifact,
        partialURL: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL
}

public enum ResumableDownloadError: Error, Equatable, Sendable {
    case partialFileTooLarge(expected: Int64, actual: Int64)
    case invalidHTTPResponse
    case unexpectedHTTPStatus(Int)
    case invalidContentRange(String?)
    case contentLengthMismatch(expected: Int64, actual: Int64)
    case fileSizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
}

public struct ResumableDownloader: ArtifactDownloading {
    private let hasher: any FileHashing
    private let sessionConfiguration: URLSessionConfiguration

    public init(
        hasher: any FileHashing = SHA256Hasher(),
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.hasher = hasher
        self.sessionConfiguration = sessionConfiguration
    }

    public func download(
        artifact: DeploymentArtifact,
        partialURL: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let directory = try openPartialDirectory(for: partialURL)
        let filename = partialURL.lastPathComponent
        var transportRetry = 0
        var restartedAfterIntegrityFailure = false

        while true {
            try Task.checkCancellation()
            var partial = try partialState(
                in: directory,
                named: filename
            )
            if partial == nil, artifact.size == 0 {
                partial = try createEmptyPartial(
                    in: directory,
                    named: filename
                )
            }
            let partialSize = partial?.size ?? 0
            guard partialSize <= artifact.size else {
                throw ResumableDownloadError.partialFileTooLarge(
                    expected: artifact.size,
                    actual: partialSize
                )
            }

            if partialSize == artifact.size {
                do {
                    try verify(
                        in: directory,
                        named: filename,
                        expectedIdentity: partial?.identity,
                        matches: artifact
                    )
                    try verifyDirectoryStillNames(
                        directory,
                        at: partialURL.deletingLastPathComponent()
                    )
                    return partialURL
                } catch let error as ResumableDownloadError {
                    guard case .checksumMismatch = error,
                          !restartedAfterIntegrityFailure,
                          let identity = partial?.identity else {
                        throw error
                    }
                    try resetPartial(
                        in: directory,
                        named: filename,
                        expectedIdentity: identity
                    )
                    restartedAfterIntegrityFailure = true
                    continue
                }
            }

            do {
                let attempt = DownloadAttempt(
                    artifact: artifact,
                    directory: directory,
                    filename: filename,
                    initialSize: partialSize,
                    expectedIdentity: partial?.identity,
                    sessionConfiguration: sessionConfiguration,
                    progress: progress
                )
                let downloadedIdentity = try await attempt.run()
                do {
                    try verify(
                        in: directory,
                        named: filename,
                        expectedIdentity: downloadedIdentity,
                        matches: artifact
                    )
                } catch let error as ResumableDownloadError {
                    guard case .checksumMismatch = error,
                          !restartedAfterIntegrityFailure else {
                        throw error
                    }
                    try resetPartial(
                        in: directory,
                        named: filename,
                        expectedIdentity: downloadedIdentity
                    )
                    restartedAfterIntegrityFailure = true
                    continue
                }
                try verifyDirectoryStillNames(
                    directory,
                    at: partialURL.deletingLastPathComponent()
                )
                return partialURL
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard transportRetry < 3, shouldRetry(error) else {
                    throw error
                }
                try await Task.sleep(for: .seconds(1 << transportRetry))
                transportRetry += 1
            }
        }
    }

    private func verify(
        in directory: POSIXDirectoryDescriptor,
        named name: String,
        expectedIdentity: POSIXFileIdentity?,
        matches artifact: DeploymentArtifact
    ) throws {
        let file = try directory.openFile(
            name,
            flags: O_RDONLY | O_NOFOLLOW
        )
        let opened = try file.metadata()
        guard opened.st_mode & S_IFMT == S_IFREG,
              expectedIdentity.map({
                  POSIXFileIdentity(opened) == $0
              }) ?? true else {
            throw POSIXTransactionError.ownershipChanged
        }
        let identity = POSIXFileIdentity(opened)
        let actualSize = Int64(opened.st_size)
        guard actualSize == artifact.size else {
            throw ResumableDownloadError.fileSizeMismatch(
                expected: artifact.size,
                actual: actualSize
            )
        }

        let actualHash = try hasher.sha256(
            fileDescriptor: file.rawValue
        )
        let afterHash = try file.metadata()
        guard afterHash.st_mode & S_IFMT == S_IFREG,
              Int64(afterHash.st_size) == actualSize,
              POSIXFileIdentity(afterHash) == identity,
              let current = try directory.metadata(for: name),
              current.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(current) == identity else {
            throw POSIXTransactionError.ownershipChanged
        }
        guard actualHash.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw ResumableDownloadError.checksumMismatch(
                expected: artifact.sha256,
                actual: actualHash
            )
        }
    }

    private func openPartialDirectory(for partialURL: URL) throws -> POSIXDirectoryDescriptor {
        let parent = partialURL.deletingLastPathComponent()
        let root = parent.deletingLastPathComponent()
        let directory = try POSIXDirectoryDescriptor.openOrCreateRoot(root)
        return try directory.openDirectory(parent.lastPathComponent, createMode: 0o700)
    }

    private func partialState(
        in directory: POSIXDirectoryDescriptor,
        named name: String
    ) throws -> (size: Int64, identity: POSIXFileIdentity)? {
        guard let metadata = try directory.metadata(for: name) else {
            return nil
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else {
            throw POSIXTransactionError.unsafePath
        }
        return (Int64(metadata.st_size), POSIXFileIdentity(metadata))
    }

    private func createEmptyPartial(
        in directory: POSIXDirectoryDescriptor,
        named name: String
    ) throws -> (size: Int64, identity: POSIXFileIdentity) {
        let file = try directory.openFile(
            name,
            flags: O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode: 0o600
        )
        let metadata = try file.metadata()
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size == 0 else {
            throw POSIXTransactionError.ownershipChanged
        }
        try file.closeChecked()
        try directory.sync()
        return (0, POSIXFileIdentity(metadata))
    }

    private func resetPartial(
        in directory: POSIXDirectoryDescriptor,
        named name: String,
        expectedIdentity: POSIXFileIdentity
    ) throws {
        let file = try directory.openFile(
            name,
            flags: O_RDWR | O_NOFOLLOW
        )
        let metadata = try file.metadata()
        guard metadata.st_mode & S_IFMT == S_IFREG,
              POSIXFileIdentity(metadata) == expectedIdentity,
              let current = try directory.metadata(for: name),
              POSIXFileIdentity(current) == expectedIdentity else {
            throw POSIXTransactionError.ownershipChanged
        }
        guard ftruncate(file.rawValue, 0) == 0,
              fsync(file.rawValue) == 0 else {
            throw POSIXTransactionError.operationFailed(errno)
        }
        guard let current = try directory.metadata(for: name),
              POSIXFileIdentity(current) == expectedIdentity else {
            throw POSIXTransactionError.ownershipChanged
        }
    }

    private func verifyDirectoryStillNames(
        _ directory: POSIXDirectoryDescriptor,
        at url: URL
    ) throws {
        let reopened = try POSIXDirectoryDescriptor.openRoot(url)
        guard POSIXFileIdentity(try reopened.metadata())
                == POSIXFileIdentity(try directory.metadata()) else {
            throw POSIXTransactionError.ownershipChanged
        }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if case ResumableDownloadError.unexpectedHTTPStatus(let code) = error {
            return code == 408 || code == 429 || (500...599).contains(code)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .badServerResponse,
                .cannotConnectToHost,
                .cannotFindHost,
                .dnsLookupFailed,
                .networkConnectionLost,
                .notConnectedToInternet,
                .resourceUnavailable,
                .timedOut:
            return true
        default:
            return false
        }
    }
}

private final class DownloadAttempt: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private enum TerminalState {
        case active
        case cancelled
        case failed(Error)
        case completed
    }

    private let artifact: DeploymentArtifact
    private let directory: POSIXDirectoryDescriptor
    private let filename: String
    private let initialSize: Int64
    private let expectedIdentity: POSIXFileIdentity?
    private let sessionConfiguration: URLSessionConfiguration
    private let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()

    private var continuation:
        CheckedContinuation<POSIXFileIdentity, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var fileHandle: FileHandle?
    private var openedIdentity: POSIXFileIdentity?
    private var terminalState: TerminalState = .active
    private var finished = false
    private var writeOffset: Int64 = 0
    private var receivedBodyBytes: Int64 = 0
    private var expectedBodyBytes: Int64 = 0
    private var transferStart = Date()
    private var restartPending = false

    init(
        artifact: DeploymentArtifact,
        directory: POSIXDirectoryDescriptor,
        filename: String,
        initialSize: Int64,
        expectedIdentity: POSIXFileIdentity?,
        sessionConfiguration: URLSessionConfiguration,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) {
        self.artifact = artifact
        self.directory = directory
        self.filename = filename
        self.initialSize = initialSize
        self.expectedIdentity = expectedIdentity
        self.sessionConfiguration = sessionConfiguration
        self.progress = progress
    }

    func run() async throws -> POSIXFileIdentity {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                start(continuation)
            }
        }, onCancel: {
            cancel()
        })
    }

    private func start(
        _ continuation:
            CheckedContinuation<POSIXFileIdentity, Error>
    ) {
        lock.lock()
        guard isActiveLocked else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        let configuration = sessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        var request = URLRequest(url: artifact.sourceURL)
        if initialSize > 0 {
            request.setValue("bytes=\(initialSize)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        let resources = terminateLocked(with: .cancelled)
        lock.unlock()
        closeIgnoringErrors(resources.handle)
        resources.task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            fail(ResumableDownloadError.invalidHTTPResponse)
            completionHandler(.cancel)
            return
        }

        lock.lock()
        do {
            guard isActiveLocked else {
                lock.unlock()
                completionHandler(.cancel)
                return
            }
            let statusCode = httpResponse.statusCode
            let progressUpdate: DownloadProgress
            switch statusCode {
            case 200:
                progressUpdate = try configureFileLocked(
                    restarting: initialSize > 0,
                    response: httpResponse
                )
            case 206 where initialSize > 0:
                try validateResumeResponse(httpResponse)
                progressUpdate = try configureFileLocked(restarting: false, response: httpResponse)
            default:
                throw ResumableDownloadError.unexpectedHTTPStatus(statusCode)
            }
            lock.unlock()
            progress(progressUpdate)
            completionHandler(.allow)
        } catch {
            lock.unlock()
            fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard isActiveLocked else {
            lock.unlock()
            return
        }

        let handle: FileHandle
        do {
            if restartPending {
                try openFileLocked(restarting: true)
                restartPending = false
            }
            guard let openedHandle = fileHandle else {
                throw ResumableDownloadError.invalidHTTPResponse
            }
            handle = openedHandle
        } catch {
            let resources = terminateLocked(with: .failed(error))
            lock.unlock()
            closeIgnoringErrors(resources.handle)
            resources.task?.cancel()
            return
        }

        let count = Int64(data.count)
        let (newReceivedBodyBytes, overflowed) = receivedBodyBytes.addingReportingOverflow(count)
        guard !overflowed, newReceivedBodyBytes <= expectedBodyBytes else {
            let actual = overflowed ? Int64.max : newReceivedBodyBytes
            let resources = terminateLocked(with: .failed(
                ResumableDownloadError.contentLengthMismatch(
                    expected: expectedBodyBytes,
                    actual: actual
                )
            ))
            lock.unlock()
            closeIgnoringErrors(resources.handle)
            resources.task?.cancel()
            return
        }

        do {
            try handle.write(contentsOf: data)
            let (newWriteOffset, writeOverflowed) = writeOffset.addingReportingOverflow(count)
            guard !writeOverflowed else {
                throw ResumableDownloadError.fileSizeMismatch(
                    expected: artifact.size,
                    actual: Int64.max
                )
            }
            receivedBodyBytes = newReceivedBodyBytes
            writeOffset = newWriteOffset
            let progressUpdate = progressLocked()
            lock.unlock()
            progress(progressUpdate)
        } catch {
            let resources = terminateLocked(with: .failed(error))
            lock.unlock()
            closeIgnoringErrors(resources.handle)
            resources.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        var handleToClose: FileHandle?
        if isActiveLocked {
            if let error {
                handleToClose = fileHandle
                fileHandle = nil
                terminalState = .failed(error)
            } else if receivedBodyBytes != expectedBodyBytes {
                handleToClose = fileHandle
                fileHandle = nil
                terminalState = .failed(ResumableDownloadError.contentLengthMismatch(
                    expected: expectedBodyBytes,
                    actual: receivedBodyBytes
                ))
            } else {
                let handle = fileHandle
                fileHandle = nil
                do {
                    try handle?.synchronize()
                    try handle?.close()
                    if openedIdentity == nil {
                        terminalState = .failed(
                            POSIXTransactionError.ownershipChanged
                        )
                    } else {
                        terminalState = .completed
                    }
                } catch {
                    handleToClose = handle
                    terminalState = .failed(error)
                }
            }
        }
        let completion = takeCompletionLocked()
        lock.unlock()
        closeIgnoringErrors(handleToClose)
        resume(completion)
    }

    private func configureFileLocked(
        restarting: Bool,
        response: HTTPURLResponse
    ) throws -> DownloadProgress {
        guard isActiveLocked else { throw CancellationError() }
        let expectedBodyBytes = restarting ? artifact.size : artifact.size - initialSize
        let responseLength = response.expectedContentLength
        if responseLength >= 0, responseLength != expectedBodyBytes {
            throw ResumableDownloadError.contentLengthMismatch(
                expected: expectedBodyBytes,
                actual: responseLength
            )
        }

        if restarting {
            restartPending = true
            writeOffset = 0
        } else {
            try openFileLocked(restarting: false)
            writeOffset = initialSize
        }
        self.expectedBodyBytes = expectedBodyBytes
        self.receivedBodyBytes = 0
        self.transferStart = Date()
        return progressLocked()
    }

    private func openFileLocked(restarting: Bool) throws {
        guard isActiveLocked else { throw CancellationError() }
        var handle: FileHandle?
        do {
            var flags = O_WRONLY | O_NOFOLLOW | O_CLOEXEC
            if expectedIdentity == nil {
                flags |= O_CREAT | O_EXCL
            }
            let descriptor = openat(
                directory.rawValue,
                filename,
                flags,
                0o600
            )
            guard descriptor >= 0 else { throw POSIXTransactionError.operationFailed(errno) }
            handle = FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: true
            )
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw POSIXTransactionError.operationFailed(errno)
            }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size == initialSize,
                  expectedIdentity.map({
                      POSIXFileIdentity(metadata) == $0
                  }) ?? true else {
                throw POSIXTransactionError.ownershipChanged
            }
            let identity = POSIXFileIdentity(metadata)
            guard let current = try directory.metadata(for: filename),
                  current.st_mode & S_IFMT == S_IFREG,
                  POSIXFileIdentity(current) == identity else {
                throw POSIXTransactionError.ownershipChanged
            }
            if restarting {
                try handle?.truncate(atOffset: 0)
                try handle?.seek(toOffset: 0)
            } else {
                try handle?.seekToEnd()
            }
            fileHandle = handle
            openedIdentity = identity
        } catch {
            closeIgnoringErrors(handle)
            throw error
        }
    }

    private func validateResumeResponse(_ response: HTTPURLResponse) throws {
        guard let rawContentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let range = Self.parseContentRange(rawContentRange),
              range.start == initialSize,
              range.end == artifact.size - 1,
              range.total == artifact.size else {
            throw ResumableDownloadError.invalidContentRange(
                response.value(forHTTPHeaderField: "Content-Range")
            )
        }
    }

    private func progressLocked() -> DownloadProgress {
        let elapsed = max(Date().timeIntervalSince(transferStart), 0.001)
        let bytesPerSecond = Double(receivedBodyBytes) / elapsed
        let remaining = max(artifact.size - writeOffset, 0)
        return DownloadProgress(
            completedBytes: writeOffset,
            totalBytes: artifact.size,
            bytesPerSecond: bytesPerSecond,
            estimatedTimeRemaining: bytesPerSecond > 0 ? Double(remaining) / bytesPerSecond : nil
        )
    }

    private func fail(_ error: Error) {
        lock.lock()
        let resources = terminateLocked(with: .failed(error))
        lock.unlock()
        closeIgnoringErrors(resources.handle)
        resources.task?.cancel()
    }

    private var isActiveLocked: Bool {
        if case .active = terminalState {
            return true
        }
        return false
    }

    private func terminateLocked(with state: TerminalState) -> (task: URLSessionTask?, handle: FileHandle?) {
        guard isActiveLocked else { return (nil, nil) }
        terminalState = state
        let resources = (task as URLSessionTask?, fileHandle)
        fileHandle = nil
        return resources
    }

    private func takeCompletionLocked() -> (
        continuation:
            CheckedContinuation<POSIXFileIdentity, Error>?,
        session: URLSession?,
        state: TerminalState,
        identity: POSIXFileIdentity?
    )? {
        guard !finished, !isActiveLocked else { return nil }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        return (
            continuation,
            session,
            terminalState,
            openedIdentity
        )
    }

    private func resume(
        _ completion: (
            continuation:
                CheckedContinuation<POSIXFileIdentity, Error>?,
            session: URLSession?,
            state: TerminalState,
            identity: POSIXFileIdentity?
        )?
    ) {
        guard let completion else { return }
        completion.session?.invalidateAndCancel()
        switch completion.state {
        case .active:
            preconditionFailure("Active transfer cannot complete")
        case .cancelled:
            completion.continuation?.resume(throwing: CancellationError())
        case .failed(let error):
            completion.continuation?.resume(throwing: error)
        case .completed:
            guard let identity = completion.identity else {
                completion.continuation?.resume(
                    throwing: POSIXTransactionError.ownershipChanged
                )
                return
            }
            completion.continuation?.resume(returning: identity)
        }
    }

    private func closeIgnoringErrors(_ handle: FileHandle?) {
        try? handle?.close()
    }

    private static func parseContentRange(_ value: String) -> (start: Int64, end: Int64, total: Int64)? {
        let pieces = value.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = pieces[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else { return nil }
        let endpoints = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard endpoints.count == 2,
              let start = Int64(endpoints[0]),
              let end = Int64(endpoints[1]),
              let total = Int64(rangeAndTotal[1]),
              start >= 0,
              end >= start,
              total > end else {
            return nil
        }
        return (start, end, total)
    }
}
