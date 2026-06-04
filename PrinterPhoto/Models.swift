import Foundation
import UIKit

enum PrinterCapability: String, Codable, CaseIterable, Hashable {
    case airPrint
    case rawSocket9100
    case ipp
    case lpd
    case unknown

    var label: String {
        switch self {
        case .airPrint: "AirPrint"
        case .rawSocket9100: "ESC/POS"
        case .ipp: "IPP"
        case .lpd: "LPD"
        case .unknown: "Unknown"
        }
    }
}

enum DiscoverySource: String, Codable, Hashable {
    case bonjour
    case subnetScan
    case manual
}

enum PrintPath: String, Codable, CaseIterable {
    case airPrint
    case escPos

    var label: String {
        switch self {
        case .airPrint: "AirPrint"
        case .escPos: "Receipt"
        }
    }
}

struct DiscoveredPrinter: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var host: String
    var ports: [Int]
    var discoverySource: DiscoverySource
    var capabilities: Set<PrinterCapability>
    var lastSeen: Date

    var primaryCapability: PrinterCapability {
        if capabilities.contains(.rawSocket9100) { return .rawSocket9100 }
        if capabilities.contains(.airPrint) { return .airPrint }
        if capabilities.contains(.ipp) { return .ipp }
        if capabilities.contains(.lpd) { return .lpd }
        return .unknown
    }

    var supportsEscPos: Bool {
        capabilities.contains(.rawSocket9100)
    }

    var supportsAirPrint: Bool {
        capabilities.contains(.airPrint) || capabilities.contains(.ipp)
    }
}

struct PrintJob {
    var selectedImage: UIImage
    var targetPrinter: DiscoveredPrinter?
    var outputMode: PrintPath
    var paperWidth: PaperWidth
}

enum PaperWidth: Int, CaseIterable, Identifiable, Codable {
    case narrow = 384
    case medium = 420
    case eightyMillimeter = 576

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .narrow: "384 dots"
        case .medium: "420 dots"
        case .eightyMillimeter: "576 dots"
        }
    }
}
