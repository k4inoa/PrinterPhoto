import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var discovery = PrinterDiscoveryService()
    @StateObject private var settings = AppSettings()

    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var selectedPrinterID: DiscoveredPrinter.ID?
    @State private var manualHost = ""
    @State private var isPrinting = false
    @State private var showAirPrint = false
    @State private var alert: AppAlert?

    private let renderer = EscPosImageRenderer()
    private let escPosClient = EscPosPrinterClient()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    UtilityTitleBar(title: "PrinterPhoto")
                    photoSection
                    printerSection
                    settingsSection
                    printSection
                }
                .padding(10)
                .foregroundStyle(AppTheme.navy)
            }
            .background(AppTheme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .background(airPrintBridge)
            .alert(item: $alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
            .task(id: selectedItem) {
                await loadSelectedPhoto()
            }
            .onAppear {
                manualHost = settings.lastPrinterHost
            }
        }
    }

    private var photoSection: some View {
        UtilityBox(title: "1. IMAGE") {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Text(selectedImage == nil ? "Select Photo..." : "Change Photo...")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(UtilityButtonStyle())

                    UtilityValueRow(label: "Crop", value: cropDescription)
                    UtilityValueRow(label: "Loaded", value: selectedImage == nil ? "No" : "Yes")
                }

                Rectangle()
                    .fill(AppTheme.paper)
                    .aspectRatio(previewAspectRatio, contentMode: .fit)
                    .overlay {
                        if let previewImage {
                            Image(uiImage: previewImage)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .padding(3)
                        } else {
                            Text("NO IMAGE")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AppTheme.muted)
                        }
                    }
                    .border(AppTheme.border, width: 1)
                    .frame(width: 116, height: 116)
            }
        }
    }

    private var printerSection: some View {
        UtilityBox(title: "2. PRINTER SEARCH") {
            HStack {
                Button {
                    discovery.startScan()
                } label: {
                    Text("Search")
                }
                .buttonStyle(UtilityButtonStyle())
                .disabled(discovery.isScanning)

                Button("Stop") {
                    discovery.stopScan()
                }
                .buttonStyle(UtilityButtonStyle())
                .disabled(!discovery.isScanning)

                if discovery.isScanning {
                    Text("BUSY")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(AppTheme.navyHighlight)
                        .border(AppTheme.border, width: 1)
                }
            }

            UtilityValueRow(label: "Status", value: discovery.statusMessage)
            manualEntry

            if discovery.printers.isEmpty {
                Text("No printer found. Enter IP address manually if needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 1) {
                    ForEach(discovery.printers) { printer in
                        PrinterRow(
                            printer: printer,
                            isSelected: selectedPrinterID == printer.id
                        ) {
                            selectedPrinterID = printer.id
                            if printer.supportsEscPos {
                                settings.lastPrintPath = .escPos
                            }
                        }
                    }
                }
            }
        }
    }

    private var manualEntry: some View {
        HStack(spacing: 6) {
            Text("IP Address:")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 76, alignment: .trailing)

            TextField("Manual printer IP", text: $manualHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(AppTheme.navy)
                .tint(AppTheme.navy)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(AppTheme.paper)
                .border(AppTheme.border, width: 1)

            Button("Add") {
                discovery.addManualPrinter(host: manualHost)
                selectedPrinterID = "manual-\(manualHost.trimmingCharacters(in: .whitespacesAndNewlines))-9100"
            }
            .buttonStyle(UtilityButtonStyle())
        }
    }

    private var settingsSection: some View {
        UtilityBox(title: "3. OUTPUT SETTING") {
            UtilityOptionRow(label: "Path") {
                ForEach(PrintPath.allCases, id: \.self) { path in
                    UtilityOptionButton(title: path.label, isSelected: settings.lastPrintPath == path) {
                        settings.lastPrintPath = path
                    }
                }
            }

            UtilityOptionGrid(label: "Crop") {
                ForEach(CropRatio.allCases) { ratio in
                    UtilityOptionButton(title: ratio.label, isSelected: settings.cropRatio == ratio) {
                        settings.cropRatio = ratio
                    }
                }
            }

            UtilityOptionRow(label: "Width") {
                ForEach(PaperWidth.allCases) { width in
                    UtilityOptionButton(title: width.label, isSelected: settings.paperWidth == width) {
                        settings.paperWidth = width
                    }
                }
            }

            UtilityValueRow(label: "Output", value: settings.lastPrintPath == .airPrint ? "AirPrint system dialog" : "ESC/POS TCP 9100")
        }
    }

    private var printSection: some View {
        UtilityBox(title: "4. EXECUTE") {
            Button {
                Task { await printSelectedPhoto() }
            } label: {
                if isPrinting {
                    Text("Sending...")
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Print")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(UtilityButtonStyle())
            .disabled(!canPrint)

            if settings.lastPrintPath == .escPos, selectedEscPosPrinter == nil {
                Text("ESC/POS requires selected raw socket printer.")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.muted)
            }
        }
    }

    @ViewBuilder
    private var airPrintBridge: some View {
        if let airPrintImage {
            AirPrintPresenter(image: airPrintImage, isPresented: $showAirPrint)
                .frame(width: 0, height: 0)
        }
    }

    private var previewImage: UIImage? {
        guard let selectedImage else { return nil }
        return try? renderer.renderedPreview(
            from: selectedImage,
            paperWidth: settings.paperWidth,
            cropRatio: settings.cropRatio
        )
    }

    /// AirPrint scales for itself, so it gets the full-resolution crop rather than the
    /// paper-width raster - but the same framing the receipt path would use.
    private var airPrintImage: UIImage? {
        guard let selectedImage else { return nil }
        return (try? renderer.croppedImage(from: selectedImage, cropRatio: settings.cropRatio)) ?? selectedImage
    }

    /// `UIImage.size` is already orientation-corrected, so it is safe to read the source
    /// ratio from it without paying for a full redraw on every view update.
    private var sourceSize: CGSize? {
        selectedImage.map(\.size)
    }

    private var previewAspectRatio: CGFloat {
        guard let sourceSize else { return 1 }
        return settings.cropRatio.effectiveRatio(for: sourceSize)
    }

    /// Shows what `auto` actually landed on, so the choice is legible rather than magic.
    private var cropDescription: String {
        guard settings.cropRatio == .auto else { return settings.cropRatio.label }
        guard let sourceSize else { return "AUTO" }
        return "AUTO -> \(CropRatio.resolve(for: sourceSize).label)"
    }

    private var selectedPrinter: DiscoveredPrinter? {
        discovery.printers.first { $0.id == selectedPrinterID }
    }

    private var selectedEscPosPrinter: DiscoveredPrinter? {
        guard let selectedPrinter, selectedPrinter.supportsEscPos else { return nil }
        return selectedPrinter
    }

    private var canPrint: Bool {
        guard selectedImage != nil, !isPrinting else { return false }
        if settings.lastPrintPath == .airPrint { return true }
        return selectedEscPosPrinter != nil
    }

    private func loadSelectedPhoto() async {
        guard let selectedItem else { return }
        do {
            guard let data = try await selectedItem.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                alert = AppAlert(title: "Could not load photo", message: "Choose another image and try again.")
                return
            }
            selectedImage = image
        } catch {
            alert = AppAlert(title: "Could not load photo", message: error.localizedDescription)
        }
    }

    private func printSelectedPhoto() async {
        guard let selectedImage else { return }

        if settings.lastPrintPath == .airPrint {
            showAirPrint = true
            return
        }

        guard let printer = selectedEscPosPrinter else {
            alert = AppAlert(title: "Choose a receipt printer", message: "Select a discovered ESC/POS printer or add the Epson IP manually.")
            return
        }

        isPrinting = true
        defer { isPrinting = false }

        do {
            let confirmation = try await escPosClient.print(
                image: selectedImage,
                to: printer,
                paperWidth: settings.paperWidth,
                cropRatio: settings.cropRatio
            )
            settings.remember(printer: printer, printPath: .escPos)
            switch confirmation {
            case .acknowledged:
                alert = AppAlert(
                    title: "Printed",
                    message: "\(printer.name) took the whole photo and closed the connection."
                )
            case .unconfirmed(let reason):
                alert = AppAlert(title: "Sent, but not confirmed", message: reason)
            }
        } catch {
            alert = AppAlert(title: "Print failed", message: error.localizedDescription)
        }
    }
}

private struct PrinterRow: View {
    let printer: DiscoveredPrinter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(isSelected ? "*" : " ")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .frame(width: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(printer.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer()
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.selected : AppTheme.paper)
            .border(AppTheme.lightBorder, width: 1)
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        let capabilities = printer.capabilities.map(\.label).sorted().joined(separator: ", ")
        let ports = printer.ports.map(String.init).joined(separator: ", ")
        return "\(printer.host) | \(capabilities) | Ports \(ports)"
    }
}

private struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct UtilityTitleBar: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold, design: .monospaced))
            .foregroundStyle(AppTheme.navy)
            .textCase(.none)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.panel)
            .border(AppTheme.border, width: 1)
    }
}

private struct UtilityBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .background(AppTheme.background)
                .offset(y: -3)

            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel)
        .border(AppTheme.border, width: 1)
    }
}

private struct UtilityValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(label):")
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 62, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UtilityOptionRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(label):")
                .font(.system(size: 12, design: .monospaced))
            HStack(spacing: 4) {
                content
            }
        }
    }
}

/// Same look as `UtilityOptionRow`, wrapped over several lines. The crop list has ten
/// entries, which will not fit the single `HStack` the other option rows use.
private struct UtilityOptionGrid<Content: View>: View {
    let label: String
    var columns: Int = 5
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(label):")
                .font(.system(size: 12, design: .monospaced))
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns),
                spacing: 4
            ) {
                content
            }
        }
    }
}

private struct UtilityOptionButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(isSelected ? "[\(title)]" : title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(UtilityButtonStyle(isSelected: isSelected))
    }
}

private struct UtilityButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isSelected ? .bold : .regular, design: .monospaced))
            .foregroundStyle(isEnabled ? AppTheme.navy : AppTheme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(background(isPressed: configuration.isPressed))
            .border(isEnabled ? AppTheme.border : AppTheme.lightBorder, width: 1)
            .opacity(isEnabled ? 1 : 0.55)
    }

    private func background(isPressed: Bool) -> Color {
        if !isEnabled {
            return AppTheme.background
        }
        if isPressed {
            return AppTheme.selected
        }
        if isSelected {
            return AppTheme.selected
        }
        return AppTheme.paper
    }
}

/// Every tone is defined as a light/dark pair so the utility look survives in
/// both appearances: `navy` is the ink, and the three grounds stack from the
/// page (`background`) up through `panel` to the `paper` that inputs sit on.
private enum AppTheme {
    static let navy = adaptive(
        light: (0.08, 0.16, 0.27),
        dark: (0.87, 0.90, 0.94)
    )
    static let background = adaptive(
        light: (0.86, 0.87, 0.89),
        dark: (0.07, 0.08, 0.11)
    )
    static let panel = adaptive(
        light: (0.93, 0.94, 0.95),
        dark: (0.12, 0.14, 0.18)
    )
    static let paper = adaptive(
        light: (0.98, 0.98, 0.97),
        dark: (0.17, 0.19, 0.24)
    )
    static let selected = adaptive(
        light: (0.76, 0.80, 0.86),
        dark: (0.27, 0.33, 0.43)
    )
    static let navyHighlight = adaptive(
        light: (0.70, 0.76, 0.84),
        dark: (0.31, 0.39, 0.51)
    )
    static let muted = adaptive(
        light: (0.38, 0.42, 0.48),
        dark: (0.63, 0.67, 0.73)
    )
    static let border = navy.opacity(0.7)
    static let lightBorder = navy.opacity(0.3)

    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}
