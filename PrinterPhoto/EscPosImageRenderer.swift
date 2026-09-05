import CoreGraphics
import UIKit

struct EscPosImageRenderer {
    enum RenderError: Error {
        case missingCGImage
        case cannotCreateContext
        case cannotReadPixels
    }

    /// Redraws the image upright so pixel dimensions match displayed dimensions.
    ///
    /// A camera photo is stored in sensor orientation with an `imageOrientation` flag, so
    /// `cgImage.width` is the displayed *height* for portrait shots. A square crop survives
    /// that by symmetry, but any other ratio would take the wrong axis.
    func normalizedUpright(_ image: UIImage) throws -> UIImage {
        guard image.imageOrientation != .up || image.scale != 1 else { return image }
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Center-crops to `ratio` (width ÷ height), taking the largest such rect that fits.
    func centerCrop(_ image: UIImage, ratio: CGFloat) throws -> UIImage {
        let upright = try normalizedUpright(image)
        guard let cgImage = upright.cgImage else { throw RenderError.missingCGImage }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard ratio > 0, width > 0, height > 0 else { throw RenderError.missingCGImage }

        var cropWidth = width
        var cropHeight = width / ratio
        if cropHeight > height {
            cropHeight = height
            cropWidth = height * ratio
        }

        // Round the extent first, then place it. Rounding the whole rect outward with
        // `.integral` would grow both edges and pull the result off the requested ratio.
        let extentWidth = min(width, max(1, cropWidth.rounded()))
        let extentHeight = min(height, max(1, cropHeight.rounded()))
        let rect = CGRect(
            x: ((width - extentWidth) / 2).rounded(.down),
            y: ((height - extentHeight) / 2).rounded(.down),
            width: extentWidth,
            height: extentHeight
        )

        guard let cropped = cgImage.cropping(to: rect) else { throw RenderError.missingCGImage }
        return UIImage(cgImage: cropped, scale: 1, orientation: .up)
    }

    func centerSquareCrop(_ image: UIImage) throws -> UIImage {
        try centerCrop(image, ratio: 1)
    }

    /// Full-resolution crop, for output paths that do their own scaling (AirPrint).
    func croppedImage(from image: UIImage, cropRatio: CropRatio = .auto) throws -> UIImage {
        let upright = try normalizedUpright(image)
        return try centerCrop(upright, ratio: cropRatio.effectiveRatio(for: upright.size))
    }

    func renderedPreview(from image: UIImage, paperWidth: PaperWidth, cropRatio: CropRatio = .auto) throws -> UIImage {
        let upright = try normalizedUpright(image)
        let ratio = cropRatio.effectiveRatio(for: upright.size)
        let cropped = try centerCrop(upright, ratio: ratio)
        let width = CGFloat(paperWidth.rawValue)
        let height = max(1, (width / ratio).rounded())
        return resize(cropped, to: CGSize(width: width, height: height))
    }

    func rasterCommand(from image: UIImage, paperWidth: PaperWidth, cropRatio: CropRatio = .auto) throws -> Data {
        let rendered = try renderedPreview(from: image, paperWidth: paperWidth, cropRatio: cropRatio)
        guard let cgImage = rendered.cgImage else { throw RenderError.missingCGImage }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width
        var grayscale = [UInt8](repeating: 255, count: width * height)

        guard let context = CGContext(
            data: &grayscale,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw RenderError.cannotCreateContext
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let monochrome = dither(grayscale: grayscale, width: width, height: height)
        let rasterBytes = packBits(monochrome: monochrome, width: width, height: height)
        let widthBytes = (width + 7) / 8

        var command = Data([0x1D, 0x76, 0x30, 0x00])
        command.append(UInt8(widthBytes & 0xFF))
        command.append(UInt8((widthBytes >> 8) & 0xFF))
        command.append(UInt8(height & 0xFF))
        command.append(UInt8((height >> 8) & 0xFF))
        command.append(rasterBytes)
        return command
    }

    func printData(from image: UIImage, paperWidth: PaperWidth, cropRatio: CropRatio = .auto, cutPaper: Bool = true) throws -> Data {
        var data = Data([0x1B, 0x40])
        data.append(try rasterCommand(from: image, paperWidth: paperWidth, cropRatio: cropRatio))
        data.append(contentsOf: [0x0A, 0x0A, 0x0A])
        if cutPaper {
            data.append(contentsOf: [0x1D, 0x56, 0x42, 0x00])
        }
        return data
    }

    private func resize(_ image: UIImage, to size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func dither(grayscale: [UInt8], width: Int, height: Int) -> [Bool] {
        var values = grayscale.map(Double.init)
        var output = [Bool](repeating: false, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let old = values[index]
                let newValue = old < 128 ? 0.0 : 255.0
                output[index] = newValue == 0
                let error = old - newValue

                distribute(error: error, factor: 7.0 / 16.0, x: x + 1, y: y, width: width, height: height, values: &values)
                distribute(error: error, factor: 3.0 / 16.0, x: x - 1, y: y + 1, width: width, height: height, values: &values)
                distribute(error: error, factor: 5.0 / 16.0, x: x, y: y + 1, width: width, height: height, values: &values)
                distribute(error: error, factor: 1.0 / 16.0, x: x + 1, y: y + 1, width: width, height: height, values: &values)
            }
        }

        return output
    }

    private func distribute(error: Double, factor: Double, x: Int, y: Int, width: Int, height: Int, values: inout [Double]) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let index = y * width + x
        values[index] = min(255, max(0, values[index] + error * factor))
    }

    private func packBits(monochrome: [Bool], width: Int, height: Int) -> Data {
        let widthBytes = (width + 7) / 8
        var data = Data(count: widthBytes * height)

        for y in 0..<height {
            for x in 0..<width {
                guard monochrome[y * width + x] else { continue }
                let byteIndex = y * widthBytes + x / 8
                let mask = UInt8(0x80 >> UInt8(x % 8))
                data[byteIndex] |= mask
            }
        }

        return data
    }
}
