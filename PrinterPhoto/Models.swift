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

/// Where to actually open a socket. A Bonjour service is kept as a service
/// reference rather than a host string: the instance name ("EPSON TM-T88VI") is
/// not a DNS name, so Network.framework has to resolve the service itself.
enum PrinterDestination: Codable, Equatable, Hashable {
    case hostPort(host: String, port: Int)
    case bonjourService(name: String, type: String, domain: String)

    /// Human-readable form for the printer list.
    var displayHost: String {
        switch self {
        case .hostPort(let host, _): host
        case .bonjourService(let name, _, _): name
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
    var destination: PrinterDestination

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

    /// The port an ESC/POS job should go to, preferring the raw-socket port.
    var escPosPort: Int {
        ports.contains(9100) ? 9100 : (ports.first ?? 9100)
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

/// Aspect ratios the crop stage can target, expressed as width ÷ height.
///
/// `auto` resolves against the source image at render time; `original` skips the
/// crop entirely, clamped to `originalBounds` so a tall panorama cannot spool an
/// unbounded length of receipt paper.
enum CropRatio: String, CaseIterable, Codable, Identifiable {
    case auto
    case square
    case portrait45
    case portrait34
    case portrait23
    case portrait916
    case landscape43
    case landscape32
    case landscape169
    case original

    var id: String { rawValue }

    /// Width ÷ height, or nil for the two cases that only resolve against a source image.
    var value: CGFloat? {
        switch self {
        case .auto, .original: nil
        case .square: 1
        case .portrait45: 4.0 / 5.0
        case .portrait34: 3.0 / 4.0
        case .portrait23: 2.0 / 3.0
        case .portrait916: 9.0 / 16.0
        case .landscape43: 4.0 / 3.0
        case .landscape32: 3.0 / 2.0
        case .landscape169: 16.0 / 9.0
        }
    }

    var label: String {
        switch self {
        case .auto: "AUTO"
        case .square: "1:1"
        case .portrait45: "4:5"
        case .portrait34: "3:4"
        case .portrait23: "2:3"
        case .portrait916: "9:16"
        case .landscape43: "4:3"
        case .landscape32: "3:2"
        case .landscape169: "16:9"
        case .original: "ORIG"
        }
    }

    /// The fixed ratios `auto` is allowed to snap to.
    static var concreteCases: [CropRatio] {
        allCases.filter { $0.value != nil }
    }

    /// How far, in log space, a source ratio may sit from a fixed ratio and still snap to it.
    /// Roughly 8%: enough to absorb sensor and screenshot rounding, not enough to hack a
    /// meaningful slice off the frame.
    static let snapTolerance = 0.08

    /// Tallest and widest ratios `original` will print, so paper use stays bounded.
    static let originalBounds: ClosedRange<CGFloat> = (9.0 / 16.0)...(16.0 / 9.0)

    /// Picks the ratio `auto` means for a source image of this size.
    ///
    /// Distance is measured on `log(ratio)` so 4:3 and 3:4 read as equally far from square;
    /// plain subtraction makes the landscape side look closer than it is. A source that
    /// matches nothing closely falls back to `original` rather than losing a third of the frame.
    static func resolve(for size: CGSize) -> CropRatio {
        guard size.width > 0, size.height > 0 else { return .square }
        let source = log(Double(size.width / size.height))
        let nearest = concreteCases
            .compactMap { ratio -> (ratio: CropRatio, distance: Double)? in
                guard let value = ratio.value else { return nil }
                return (ratio, abs(log(Double(value)) - source))
            }
            .min { $0.distance < $1.distance }

        guard let nearest, nearest.distance <= snapTolerance else { return .original }
        return nearest.ratio
    }

    /// The ratio to actually crop to for a source image of this size.
    func effectiveRatio(for size: CGSize) -> CGFloat {
        switch self {
        case .auto:
            // `resolve` never returns `.auto`, so this recurses at most once.
            return CropRatio.resolve(for: size).effectiveRatio(for: size)
        case .original:
            guard size.width > 0, size.height > 0 else { return 1 }
            let source = size.width / size.height
            return min(max(source, CropRatio.originalBounds.lowerBound), CropRatio.originalBounds.upperBound)
        default:
            return value ?? 1
        }
    }
}
