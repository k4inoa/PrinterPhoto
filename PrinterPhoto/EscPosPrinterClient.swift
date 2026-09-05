import Foundation
import Network
import UIKit

struct EscPosPrinterClient {
    enum ClientError: LocalizedError, Equatable {
        case invalidPort(Int)
        case connectTimedOut(destination: String, seconds: TimeInterval, lastError: String?)
        case connectionFailed(String)
        case sendTimedOut(seconds: TimeInterval)
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                return "Port \(port) is not a valid TCP port. Use a number between 1 and 65535."
            case .connectTimedOut(let destination, let seconds, let lastError):
                let detail = lastError.map { " (\($0))" } ?? ""
                return "Could not reach \(destination) within \(Int(seconds)) seconds\(detail). "
                    + "Check that the printer is powered on and on this Wi-Fi network."
            case .connectionFailed(let reason):
                return "Could not connect to the printer: \(reason)"
            case .sendTimedOut(let seconds):
                return "The printer accepted the connection but stopped reading after \(Int(seconds)) seconds. "
                    + "It may be out of paper, jammed, or busy with another job."
            case .sendFailed(let reason):
                return "Sending to the printer failed: \(reason)"
            }
        }
    }

    /// How certain we are that the printer actually took the job.
    ///
    /// Raw ESC/POS over port 9100 has no application-level acknowledgement, so the
    /// strongest signal available without sending extra command bytes is the printer
    /// closing its end of the connection once it has consumed the job.
    enum DeliveryConfirmation: Equatable {
        /// The printer read the whole job and then closed the connection.
        case acknowledged
        /// The bytes were flushed to the printer, but it never closed the connection.
        case unconfirmed(String)
    }

    /// Time allowed to reach `.ready`. Unreachable hosts otherwise wait forever.
    var connectTimeout: TimeInterval = 8
    /// Time allowed for the printer to drain the job off the socket.
    var sendTimeout: TimeInterval = 20
    /// Time to wait for the printer to close the connection after the job.
    var acknowledgementTimeout: TimeInterval = 6

    private let renderer = EscPosImageRenderer()

    @discardableResult
    func print(image: UIImage, to printer: DiscoveredPrinter, paperWidth: PaperWidth, cropRatio: CropRatio = .auto) async throws -> DeliveryConfirmation {
        let data = try renderer.printData(from: image, paperWidth: paperWidth, cropRatio: cropRatio)
        return try await send(data, to: printer.destination)
    }

    @discardableResult
    func send(_ data: Data, host: String, port: Int) async throws -> DeliveryConfirmation {
        try await send(data, to: .hostPort(host: host, port: port))
    }

    @discardableResult
    func send(_ data: Data, to destination: PrinterDestination) async throws -> DeliveryConfirmation {
        let session = TCPSession(endpoint: try Self.endpoint(for: destination))
        defer { session.cancel() }

        try await session.connect(timeout: connectTimeout, describing: destination.displayHost)
        try await session.sendAll(data, timeout: sendTimeout)

        if await session.waitForPeerClose(timeout: acknowledgementTimeout) {
            return .acknowledged
        }
        return .unconfirmed(
            "The data reached \(destination.displayHost), but the printer did not close the connection within "
            + "\(Int(acknowledgementTimeout)) seconds, so it may not have finished printing. Check the paper."
        )
    }

    static func endpoint(for destination: PrinterDestination) throws -> NWEndpoint {
        switch destination {
        case .hostPort(let host, let port):
            // UInt16(port) would TRAP on an out-of-range value; UInt16(exactly:) reports it.
            guard let narrowed = UInt16(exactly: port), let nwPort = NWEndpoint.Port(rawValue: narrowed) else {
                throw ClientError.invalidPort(port)
            }
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        case .bonjourService(let name, let type, let domain):
            // Let Network.framework resolve the service; the instance name is not a host.
            return .service(name: name, type: type, domain: domain, interface: nil)
        }
    }
}

/// A single-use TCP conversation with a printer, with a deadline on every phase.
private final class TCPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.jah.PrinterPhoto.escpos", qos: .userInitiated)

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    func cancel() {
        connection.cancel()
    }

    /// Waits for `.ready`. `.waiting` is retried by Network.framework indefinitely,
    /// so the deadline - not the framework - decides when to give up.
    func connect(timeout: TimeInterval, describing destination: String) async throws {
        let gate = OneShot<Void>()
        let lastWaitingError = Locked<String?>(nil)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.finish(.success(()))
            case .waiting(let error):
                lastWaitingError.set(error.localizedDescription)
            case .failed(let error):
                gate.finish(.failure(EscPosPrinterClient.ClientError.connectionFailed(error.localizedDescription)))
            case .cancelled:
                gate.finish(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            gate.finish(.failure(EscPosPrinterClient.ClientError.connectTimedOut(
                destination: destination,
                seconds: timeout,
                lastError: lastWaitingError.get()
            )))
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { gate.attach($0) }
        } onCancel: {
            self.cancel()
        }
    }

    /// Sends the whole job and half-closes, so the printer sees a clean end-of-job.
    func sendAll(_ data: Data, timeout: TimeInterval) async throws {
        let gate = OneShot<Void>()

        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
            if let error {
                gate.finish(.failure(EscPosPrinterClient.ClientError.sendFailed(error.localizedDescription)))
            } else {
                gate.finish(.success(()))
            }
        })
        queue.asyncAfter(deadline: .now() + timeout) {
            gate.finish(.failure(EscPosPrinterClient.ClientError.sendTimedOut(seconds: timeout)))
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { gate.attach($0) }
        } onCancel: {
            self.cancel()
        }
    }

    /// True if the printer closed its end - the only end-to-end signal available
    /// on a raw socket that the job was actually consumed.
    func waitForPeerClose(timeout: TimeInterval) async -> Bool {
        let gate = OneShot<Bool>()

        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, isComplete, error in
                if isComplete {
                    gate.finish(.success(true))
                } else if error != nil {
                    gate.finish(.success(false))
                } else {
                    pump()
                }
            }
        }
        pump()
        queue.asyncAfter(deadline: .now() + timeout) { gate.finish(.success(false)) }

        return (try? await withCheckedThrowingContinuation { gate.attach($0) }) ?? false
    }
}

/// Resumes a continuation exactly once, whichever of the racing callbacks wins,
/// and tolerates the result arriving before the continuation is attached.
private final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var settled: Result<T, Error>?

    func attach(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let settled {
            lock.unlock()
            continuation.resume(with: settled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard settled == nil else {
            lock.unlock()
            return
        }
        settled = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) { self.value = value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
