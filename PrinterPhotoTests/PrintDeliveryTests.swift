import XCTest
import Network
import UIKit
@testable import PrinterPhoto

// MARK: - Test doubles for printer behaviour

/// A fake printer. `drains` = reads the job off the socket.
/// `closesWhenDone` = closes its end afterwards, like a real network printer.
final class FakePrinter: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var received = Data()
    private var connections: [NWConnection] = []
    private let drains: Bool
    private let closesWhenDone: Bool
    private(set) var port: Int = 0
    private let advertised = DispatchSemaphore(value: 0)

    init(drains: Bool, closesWhenDone: Bool, advertiseBonjourAs service: NWListener.Service? = nil) throws {
        self.drains = drains
        self.closesWhenDone = closesWhenDone
        listener = try NWListener(using: .tcp, on: .any)
        if let service {
            listener.service = service
            listener.serviceRegistrationUpdateHandler = { [advertised] change in
                if case .add = change { advertised.signal() }
            }
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.lock(); self.connections.append(connection); self.lock.unlock()
            connection.start(queue: .global())
            if self.drains { self.pump(connection) }
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "FakePrinter", code: 1)
        }
        port = Int(listener.port?.rawValue ?? 0)
    }

    private func pump(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock(); self.received.append(data); self.lock.unlock()
            }
            if isComplete || error != nil {
                if self.closesWhenDone { connection.cancel() }
                return
            }
            self.pump(connection)
        }
    }

    /// Blocks until Bonjour has actually registered the service, not a guessed delay.
    func waitUntilAdvertised(timeout: TimeInterval = 15) -> Bool {
        advertised.wait(timeout: .now() + timeout) == .success
    }

    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return received.count }
    var bytes: Data { lock.lock(); defer { lock.unlock() }; return received }
    func stop() { listener.cancel() }
}

final class PrintDeliveryTests: XCTestCase {

    private func job(_ side: Int = 1200) throws -> Data {
        try EscPosImageRenderer().printData(from: makeImage(side, side), paperWidth: .eightyMillimeter)
    }

    // MARK: - FIX 1: every phase has a deadline

    func test_unreachableHostFailsFastWithAnActionableError() async throws {
        var client = EscPosPrinterClient()
        client.connectTimeout = 3

        let start = Date()
        do {
            _ = try await client.send(Data([0x1B, 0x40]), host: "192.0.2.1", port: 9100)
            XCTFail("expected a timeout error")
        } catch let error as EscPosPrinterClient.ClientError {
            let elapsed = Date().timeIntervalSince(start)
            print("VERIFY: unreachable host failed after \(String(format: "%.1f", elapsed))s")
            print("VERIFY: message = \(error.localizedDescription)")
            guard case .connectTimedOut = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertLessThan(elapsed, 8, "should fail near the 3s connect timeout, not hang")
        }
    }

    func test_printerThatNeverDrainsTimesOutInsteadOfHanging() async throws {
        let printer = try FakePrinter(drains: false, closesWhenDone: false)
        defer { printer.stop() }

        var client = EscPosPrinterClient()
        client.sendTimeout = 3
        // Big enough that it cannot all sit in the socket send buffer.
        let huge = Data(repeating: 0x41, count: 12 * 1024 * 1024)

        let start = Date()
        do {
            _ = try await client.send(huge, host: "127.0.0.1", port: printer.port)
            XCTFail("expected a send timeout against a printer that never reads")
        } catch let error as EscPosPrinterClient.ClientError {
            let elapsed = Date().timeIntervalSince(start)
            print("VERIFY: stalled printer failed after \(String(format: "%.1f", elapsed))s")
            print("VERIFY: message = \(error.localizedDescription)")
            guard case .sendTimedOut = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertLessThan(elapsed, 10)
        }
    }

    func test_invalidPortIsReportedNotTrapped() async {
        do {
            _ = try await EscPosPrinterClient().send(Data([0x1B]), host: "127.0.0.1", port: 70_000)
            XCTFail("expected invalidPort")
        } catch let error as EscPosPrinterClient.ClientError {
            print("VERIFY: port 70000 -> \(error.localizedDescription)")
            XCTAssertEqual(error, .invalidPort(70_000))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - FIX 2: success means the printer actually took the job

    func test_printerThatConsumesAndClosesIsAcknowledged() async throws {
        let printer = try FakePrinter(drains: true, closesWhenDone: true)
        defer { printer.stop() }
        let payload = try job()

        let confirmation = try await EscPosPrinterClient().send(payload, host: "127.0.0.1", port: printer.port)
        print("VERIFY: sent=\(payload.count) received=\(printer.byteCount) confirmation=\(confirmation)")

        XCTAssertEqual(confirmation, .acknowledged)
        XCTAssertEqual(printer.bytes, payload, "the printer must receive exactly the bytes we sent")
    }

    /// The original bug: the app said "Sent to printer" when the printer read nothing.
    func test_printerThatReadsNothingIsNotReportedAsSuccess() async throws {
        let printer = try FakePrinter(drains: false, closesWhenDone: false)
        defer { printer.stop() }

        var client = EscPosPrinterClient()
        client.acknowledgementTimeout = 2

        let confirmation = try await client.send(Data([0x1B, 0x40, 0x0A]), host: "127.0.0.1", port: printer.port)
        print("VERIFY: printer read \(printer.byteCount) bytes; confirmation = \(confirmation)")

        guard case .unconfirmed(let reason) = confirmation else {
            return XCTFail("REGRESSION: a printer that read nothing was reported as acknowledged")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func test_printerThatConsumesButHoldsTheConnectionIsUnconfirmed() async throws {
        let printer = try FakePrinter(drains: true, closesWhenDone: false)
        defer { printer.stop() }

        var client = EscPosPrinterClient()
        client.acknowledgementTimeout = 2
        let payload = try job()

        let confirmation = try await client.send(payload, host: "127.0.0.1", port: printer.port)
        print("VERIFY: drained \(printer.byteCount)/\(payload.count) bytes, no close -> \(confirmation)")

        XCTAssertEqual(printer.byteCount, payload.count, "bytes still arrive in full")
        guard case .unconfirmed = confirmation else {
            return XCTFail("a printer that never closed should not be reported as acknowledged")
        }
    }

    // MARK: - FIX 3: Bonjour services resolve instead of hanging

    func test_bonjourDestinationBuildsAServiceEndpointNotAHostname() throws {
        let endpoint = try EscPosPrinterClient.endpoint(
            for: .bonjourService(name: "EPSON TM-T88VI", type: "_pdl-datastream._tcp", domain: "local.")
        )
        print("VERIFY: endpoint = \(endpoint)")
        guard case .service(let name, let type, _, _) = endpoint else {
            return XCTFail("REGRESSION: Bonjour printer resolved to \(endpoint) - the instance name is not a host")
        }
        XCTAssertEqual(name, "EPSON TM-T88VI")
        XCTAssertEqual(type, "_pdl-datastream._tcp")
    }

    /// End to end: advertise a real Bonjour service, then print to it by service name.
    func test_printingToARealAdvertisedBonjourServiceDelivers() async throws {
        let serviceName = "PrinterPhotoTest-\(Int.random(in: 1000...9999))"
        let printer = try FakePrinter(
            drains: true,
            closesWhenDone: true,
            advertiseBonjourAs: NWListener.Service(name: serviceName, type: "_pdl-datastream._tcp")
        )
        defer { printer.stop() }
        XCTAssertTrue(printer.waitUntilAdvertised(), "Bonjour service never registered")
        print("VERIFY: service registered as \(serviceName)._pdl-datastream._tcp.local.")

        let discovered = DiscoveredPrinter(
            id: "bonjour-\(serviceName)",
            name: serviceName,
            host: serviceName,
            ports: [9100],
            discoverySource: .bonjour,
            capabilities: [.rawSocket9100],
            lastSeen: Date(),
            destination: .bonjourService(name: serviceName, type: "_pdl-datastream._tcp", domain: "local.")
        )

        var client = EscPosPrinterClient()
        client.connectTimeout = 10
        let confirmation = try await client.print(image: makeImage(200, 200), to: discovered, paperWidth: .narrow)
        print("VERIFY: bonjour end-to-end -> received \(printer.byteCount) bytes, \(confirmation)")

        XCTAssertGreaterThan(printer.byteCount, 1000, "the Bonjour-discovered printer received the job")
        XCTAssertEqual(Array(printer.bytes.prefix(2)), [0x1B, 0x40], "job starts with ESC @")
    }
}

private func makeImage(_ w: Int, _ h: Int) -> UIImage {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
        UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w / 3, height: h))
    }
}
