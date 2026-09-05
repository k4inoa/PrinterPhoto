import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var lastPrinterName: String {
        didSet { defaults.set(lastPrinterName, forKey: Keys.lastPrinterName) }
    }

    @Published var lastPrinterHost: String {
        didSet { defaults.set(lastPrinterHost, forKey: Keys.lastPrinterHost) }
    }

    @Published var lastPrinterPort: Int {
        didSet { defaults.set(lastPrinterPort, forKey: Keys.lastPrinterPort) }
    }

    @Published var paperWidth: PaperWidth {
        didSet { defaults.set(paperWidth.rawValue, forKey: Keys.paperWidth) }
    }

    @Published var lastPrintPath: PrintPath {
        didSet { defaults.set(lastPrintPath.rawValue, forKey: Keys.lastPrintPath) }
    }

    @Published var cropRatio: CropRatio {
        didSet { defaults.set(cropRatio.rawValue, forKey: Keys.cropRatio) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedPort = defaults.integer(forKey: Keys.lastPrinterPort)
        lastPrinterName = defaults.string(forKey: Keys.lastPrinterName) ?? ""
        lastPrinterHost = defaults.string(forKey: Keys.lastPrinterHost) ?? ""
        lastPrinterPort = savedPort == 0 ? 9100 : savedPort
        paperWidth = PaperWidth(rawValue: defaults.integer(forKey: Keys.paperWidth)) ?? .eightyMillimeter
        lastPrintPath = PrintPath(rawValue: defaults.string(forKey: Keys.lastPrintPath) ?? "") ?? .escPos
        cropRatio = CropRatio(rawValue: defaults.string(forKey: Keys.cropRatio) ?? "") ?? .auto
    }

    func remember(printer: DiscoveredPrinter, printPath: PrintPath) {
        lastPrinterName = printer.name
        lastPrinterHost = printer.host
        lastPrinterPort = printer.ports.first ?? 9100
        lastPrintPath = printPath
    }

    enum Keys {
        static let lastPrinterName = "lastPrinterName"
        static let lastPrinterHost = "lastPrinterHost"
        static let lastPrinterPort = "lastPrinterPort"
        static let paperWidth = "paperWidth"
        static let lastPrintPath = "lastPrintPath"
        static let cropRatio = "cropRatio"
    }
}
