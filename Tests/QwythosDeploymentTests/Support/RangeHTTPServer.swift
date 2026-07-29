import Foundation
import Network

final class RangeHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let rangeHeader: String?
    }

    struct Configuration: Sendable {
        enum RangeHandling: Equatable, Sendable {
            case honor
            case ignore
        }

        enum ContentRangeHandling: Equatable, Sendable {
            case automatic
            case omitted
            case overridden(String)
        }

        let rangeHandling: RangeHandling
        let contentRangeHandling: ContentRangeHandling
        let transientDisconnects: Int
        let contentLength: Int?
        let includesContentLength: Bool
        let chunkSize: Int
        let chunkDelay: TimeInterval
        let responseDelay: TimeInterval
        let statusCodes: [Int]

        init(
            rangeHandling: RangeHandling = .honor,
            contentRangeHandling: ContentRangeHandling = .automatic,
            transientDisconnects: Int = 0,
            contentLength: Int? = nil,
            includesContentLength: Bool = true,
            chunkSize: Int = .max,
            chunkDelay: TimeInterval = 0,
            responseDelay: TimeInterval = 0,
            statusCodes: [Int] = []
        ) {
            self.rangeHandling = rangeHandling
            self.contentRangeHandling = contentRangeHandling
            self.transientDisconnects = transientDisconnects
            self.contentLength = contentLength
            self.includesContentLength = includesContentLength
            self.chunkSize = chunkSize
            self.chunkDelay = chunkDelay
            self.responseDelay = responseDelay
            self.statusCodes = statusCodes
        }
    }

    private let payload: Data
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "RangeHTTPServer")
    private let lock = NSLock()
    private let listener: NWListener
    private var storedRequests: [Request] = []
    private var remainingDisconnects: Int
    private var remainingStatusCodes: [Int]

    init(payload: Data, configuration: Configuration = .init()) throws {
        self.payload = payload
        self.configuration = configuration
        self.remainingDisconnects = configuration.transientDisconnects
        self.remainingStatusCodes = configuration.statusCodes
        self.listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, data: Data())
        }
    }

    var url: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/fixture.bin")!
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        let result = StartupResult()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                result.error = error
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success else {
            throw NSError(domain: "RangeHTTPServer", code: 1)
        }
        if let error = result.error {
            throw error
        }
    }

    func stop() {
        listener.cancel()
    }

    private func receiveRequest(on connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, complete, error in
            guard let self else { return }
            if let error {
                connection.cancel()
                _ = error
                return
            }

            var request = data
            if let content {
                request.append(content)
            }
            guard let headerRange = request.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete {
                    self.receiveRequest(on: connection, data: request)
                }
                return
            }

            self.respond(to: connection, request: request[..<headerRange.lowerBound])
        }
    }

    private func respond(to connection: NWConnection, request: Data.SubSequence) {
        let headerLines = String(decoding: request, as: UTF8.self)
            .components(separatedBy: "\r\n")
        let rangeHeader = headerLines.dropFirst().first { line in
            line.lowercased().hasPrefix("range:")
        }.map { line in
            String(line.dropFirst("Range:".count)).trimmingCharacters(in: .whitespaces)
        }

        lock.lock()
        storedRequests.append(Request(rangeHeader: rangeHeader))
        let shouldDisconnect = remainingDisconnects > 0
        if shouldDisconnect {
            remainingDisconnects -= 1
        }
        let statusCode = remainingStatusCodes.isEmpty ? nil : remainingStatusCodes.removeFirst()
        lock.unlock()

        guard !shouldDisconnect else {
            connection.cancel()
            return
        }

        let response = makeResponse(rangeHeader: rangeHeader, statusCode: statusCode)
        let contentLengthHeader = configuration.includesContentLength
            ? "Content-Length: \(configuration.contentLength ?? response.body.count)\r\n"
            : ""
        let headers = "HTTP/1.1 \(response.status) \(response.reason)\r\n\(contentLengthHeader)Connection: close\r\n\(response.contentRange.map { "Content-Range: \($0)\r\n" } ?? "")\r\n"
        if configuration.responseDelay > 0 {
            queue.asyncAfter(deadline: .now() + configuration.responseDelay) { [weak self] in
                self?.sendResponse(headers: headers, body: response.body, on: connection)
            }
            return
        }
        sendResponse(headers: headers, body: response.body, on: connection)
    }

    private func sendResponse(headers: String, body: Data, on connection: NWConnection) {
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] _ in
            self?.send(body, on: connection, offset: 0)
        })
    }

    private func makeResponse(
        rangeHeader: String?,
        statusCode: Int?
    ) -> (status: Int, reason: String, contentRange: String?, body: Data) {
        if let statusCode, !(200...299).contains(statusCode) {
            return (statusCode, "Transient Failure", nil, Data())
        }
        guard configuration.rangeHandling == .honor,
              let rangeHeader,
              let startText = rangeHeader.split(separator: "=").last?.split(separator: "-").first,
              let start = Int(startText),
              start <= payload.count else {
            return (200, "OK", nil, payload)
        }

        let body = Data(payload.dropFirst(start))
        let contentRange: String?
        switch configuration.contentRangeHandling {
        case .automatic:
            contentRange = "bytes \(start)-\(payload.count - 1)/\(payload.count)"
        case .omitted:
            contentRange = nil
        case .overridden(let value):
            contentRange = value
        }
        return (206, "Partial Content", contentRange, body)
    }

    private func send(_ data: Data, on connection: NWConnection, offset: Int) {
        guard offset < data.count else {
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
            return
        }
        let end = min(offset + configuration.chunkSize, data.count)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if self.configuration.chunkDelay > 0 {
                self.queue.asyncAfter(deadline: .now() + self.configuration.chunkDelay) {
                    self.send(data, on: connection, offset: end)
                }
            } else {
                self.send(data, on: connection, offset: end)
            }
        })
    }

    private final class StartupResult: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Error?

        var error: Error? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }
}
