import CoreGraphics
import UIKit

struct EscPosImageRenderer {
    enum RenderError: Error {
        case missingCGImage
        case cannotCreateContext
        case cannotReadPixels
    }

    func centerSquareCrop(_ image: UIImage) throws -> UIImage {
        guard let cgImage = image.cgImage else { throw RenderError.missingCGImage }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let side = min(width, height)
        let rect = CGRect(
            x: (width - side) / 2,
            y: (height - side) / 2,
            width: side,
            height: side
        ).integral
        guard let cropped = cgImage.cropping(to: rect) else { throw RenderError.missingCGImage }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    func renderedPreview(from image: UIImage, paperWidth: PaperWidth) throws -> UIImage {
        let cropped = try centerSquareCrop(image)
        let targetSize = CGSize(width: paperWidth.rawValue, height: paperWidth.rawValue)
        return resize(cropped, to: targetSize)
    }

    func rasterCommand(from image: UIImage, paperWidth: PaperWidth) throws -> Data {
        let rendered = try renderedPreview(from: image, paperWidth: paperWidth)
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

    func printData(from image: UIImage, paperWidth: PaperWidth, cutPaper: Bool = true) throws -> Data {
        var data = Data([0x1B, 0x40])
        data.append(try rasterCommand(from: image, paperWidth: paperWidth))
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
