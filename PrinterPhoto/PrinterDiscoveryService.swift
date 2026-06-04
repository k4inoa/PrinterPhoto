import Darwin
import Foundation
import Network

@MainActor
final class PrinterDiscoveryService: ObservableObject {
    @Published private(set) var printers: [DiscoveredPrinter] = []
    @Published private(set) var isScanning = false
    @Published private(set) var statusMessage = "Ready"

    private var browsers: [NWBrowser] = []
    private var scanTask: Task<Void, Never>?
    private let scanner: SubnetScanner

    init(scanner: SubnetScanner = SubnetScanner()) {
        self.scanner = scanner
    }

    func startScan() {
        stopScan()
        printers = []
        isScanning = true
        statusMessage = "Scanning with Bonjour and subnet probes..."
        startBonjourBrowsing()

        scanTask = Task {
            let found = await scanner.scanCurrentSubnet()
            guard !Task.isCancelled else { return }
            merge(found)
            isScanning = false
            statusMessage = found.isEmpty ? "Scan complete. Try manual IP if your printer did not appear." : "Scan complete."
            stopBonjourOnly()
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        stopBonjourOnly()
        isScanning = false
        statusMessage = "Ready"
    }

    func addManualPrinter(host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let printer = DiscoveredPrinter(
            id: "manual-\(trimmed)-9100",
            name: "Manual \(trimmed)",
            host: trimmed,
            ports: [9100],
            discoverySource: .manual,
            capabilities: [.rawSocket9100],
            lastSeen: Date()
        )
        merge([printer])
    }

    private func startBonjourBrowsing() {
        let serviceTypes = ["_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp"]
        browsers = serviceTypes.map { serviceType in
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let printers = results.compactMap { result -> DiscoveredPrinter? in
                    guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
                    let capability = Self.capability(forBonjourType: type)
                    return DiscoveredPrinter(
                        id: "bonjour-\(name)-\(type)-\(domain)",
                        name: name,
                        host: name,
                        ports: Self.ports(for: capability),
                        discoverySource: .bonjour,
                        capabilities: [capability],
                        lastSeen: Date()
                    )
                }

                Task { @MainActor in
                    self?.merge(printers)
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    Task { @MainActor in
                        self?.statusMessage = "Bonjour browsing failed. Subnet scanning is still running."
                    }
                }
            }
            browser.start(queue: .global(qos: .utility))
            return browser
        }
    }

    private func stopBonjourOnly() {
        browsers.forEach { $0.cancel() }
        browsers = []
    }

    private func merge(_ newPrinters: [DiscoveredPrinter]) {
        var merged = Dictionary(uniqueKeysWithValues: printers.map { ($0.id, $0) })
        for printer in newPrinters {
            if var existing = merged[printer.id] {
                existing.ports = Array(Set(existing.ports + printer.ports)).sorted()
                existing.capabilities.formUnion(printer.capabilities)
                existing.lastSeen = printer.lastSeen
                merged[printer.id] = existing
            } else {
                merged[printer.id] = printer
            }
        }
        printers = merged.values.sorted {
            if $0.primaryCapability != $1.primaryCapability {
                return capabilityRank($0.primaryCapability) < capabilityRank($1.primaryCapability)
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func capability(forBonjourType type: String) -> PrinterCapability {
        switch type {
        case "_ipp._tcp", "_ipps._tcp":
            return .airPrint
        case "_printer._tcp":
            return .lpd
        case "_pdl-datastream._tcp":
            return .rawSocket9100
        default:
            return .unknown
        }
    }

    nonisolated private static func ports(for capability: PrinterCapability) -> [Int] {
        switch capability {
        case .airPrint, .ipp: [631]
        case .rawSocket9100: [9100]
        case .lpd: [515]
        case .unknown: []
        }
    }

    private func capabilityRank(_ capability: PrinterCapability) -> Int {
        switch capability {
        case .rawSocket9100: 0
        case .airPrint: 1
        case .ipp: 2
        case .lpd: 3
        case .unknown: 4
        }
    }
}

protocol PortProbing: Sendable {
    func probe(host: String, port: Int, timeout: TimeInterval) async -> Bool
}

struct SubnetScanner: Sendable {
    var prober: PortProbing
    var ports: [Int]
    var timeout: TimeInterval
    var concurrency: Int

    init(
        prober: PortProbing = NetworkPortProber(),
        ports: [Int] = [9100, 631, 515, 80, 443],
        timeout: TimeInterval = 0.8,
        concurrency: Int = 32
    ) {
        self.prober = prober
        self.ports = ports
        self.timeout = timeout
        self.concurrency = concurrency
    }

    func scanCurrentSubnet() async -> [DiscoveredPrinter] {
        guard let localIPv4 = NetworkInterface.currentWiFiIPv4() ?? NetworkInterface.firstUsableIPv4(),
              let prefix = Self.ipv4Slash24Prefix(localIPv4) else {
            return []
        }

        let hosts = (1...254).map { "\(prefix).\($0)" }.filter { $0 != localIPv4 }
        return await scan(hosts: hosts)
    }

    func scan(hosts: [String]) async -> [DiscoveredPrinter] {
        let jobs = hosts.flatMap { host in ports.map { (host, $0) } }
        var openPortsByHost: [String: Set<Int>] = [:]
        var nextIndex = 0

        await withTaskGroup(of: (String, Int, Bool).self) { group in
            func addNext() {
                guard nextIndex < jobs.count else { return }
                let job = jobs[nextIndex]
                nextIndex += 1
                group.addTask {
                    let isOpen = await prober.probe(host: job.0, port: job.1, timeout: timeout)
                    return (job.0, job.1, isOpen)
                }
            }

            for _ in 0..<min(concurrency, jobs.count) {
                addNext()
            }

            while let result = await group.next() {
                if result.2 {
                    openPortsByHost[result.0, default: []].insert(result.1)
                }
                addNext()
            }
        }

        return openPortsByHost.map { host, openPorts in
            Self.printer(host: host, openPorts: openPorts)
        }
        .sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
    }

    static func printer(host: String, openPorts: Set<Int>) -> DiscoveredPrinter {
        var capabilities = Set<PrinterCapability>()
        if openPorts.contains(9100) { capabilities.insert(.rawSocket9100) }
        if openPorts.contains(631) {
            capabilities.insert(.airPrint)
            capabilities.insert(.ipp)
        }
        if openPorts.contains(515) { capabilities.insert(.lpd) }
        if capabilities.isEmpty { capabilities.insert(.unknown) }

        return DiscoveredPrinter(
            id: "scan-\(host)",
            name: "Printer \(host)",
            host: host,
            ports: Array(openPorts).sorted(),
            discoverySource: .subnetScan,
            capabilities: capabilities,
            lastSeen: Date()
        )
    }

    static func ipv4Slash24Prefix(_ address: String) -> String? {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.prefix(3).joined(separator: ".")
    }
}

struct NetworkPortProber: PortProbing {
    func probe(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = ResumeGate()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resume: @Sendable (Bool) -> Void = { value in
                    guard gate.claim() else { return }
                    connection.cancel()
                    continuation.resume(returning: value)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        resume(true)
                    case .failed, .cancelled:
                        resume(false)
                    default:
                        break
                    }
                }

                connection.start(queue: .global(qos: .utility))
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    resume(false)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

enum NetworkInterface {
    static func currentWiFiIPv4() -> String? {
        ipv4Address(interfaceName: "en0")
    }

    static func firstUsableIPv4() -> String? {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name != "lo0", let address = ipv4String(from: interface.ifa_addr) else { continue }
            addresses.append(address)
        }

        return addresses.first
    }

    private static func ipv4Address(interfaceName: String) -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard String(cString: interface.ifa_name) == interfaceName,
                  interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            return ipv4String(from: interface.ifa_addr)
        }

        return nil
    }

    private static func ipv4String(from address: UnsafePointer<sockaddr>) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: hostname)
    }
}
