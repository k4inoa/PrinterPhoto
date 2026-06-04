import XCTest
@testable import PrinterPhoto

final class SubnetScannerTests: XCTestCase {
    func testSlash24Prefix() {
        XCTAssertEqual(SubnetScanner.ipv4Slash24Prefix("192.168.1.44"), "192.168.1")
        XCTAssertNil(SubnetScanner.ipv4Slash24Prefix("not-an-ip"))
    }

    func testClassifiesRawSocketPrinter() {
        let printer = SubnetScanner.printer(host: "192.168.1.20", openPorts: [9100])

        XCTAssertTrue(printer.capabilities.contains(.rawSocket9100))
        XCTAssertEqual(printer.ports, [9100])
    }

    func testClassifiesHybridNetworkPrinter() {
        let printer = SubnetScanner.printer(host: "192.168.1.30", openPorts: [631, 9100])

        XCTAssertTrue(printer.capabilities.contains(.airPrint))
        XCTAssertTrue(printer.capabilities.contains(.ipp))
        XCTAssertTrue(printer.capabilities.contains(.rawSocket9100))
        XCTAssertEqual(printer.ports, [631, 9100])
    }

    func testScanUsesMockedPortResponses() async {
        let scanner = SubnetScanner(
            prober: MockPortProber(openPorts: [
                "192.168.1.10": [9100],
                "192.168.1.11": [631]
            ]),
            ports: [9100, 631],
            timeout: 0.01,
            concurrency: 4
        )

        let printers = await scanner.scan(hosts: ["192.168.1.10", "192.168.1.11", "192.168.1.12"])

        XCTAssertEqual(printers.count, 2)
        XCTAssertTrue(printers.first { $0.host == "192.168.1.10" }?.capabilities.contains(.rawSocket9100) == true)
        XCTAssertTrue(printers.first { $0.host == "192.168.1.11" }?.capabilities.contains(.airPrint) == true)
    }
}

private struct MockPortProber: PortProbing {
    let openPorts: [String: Set<Int>]

    func probe(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        openPorts[host]?.contains(port) == true
    }
}
