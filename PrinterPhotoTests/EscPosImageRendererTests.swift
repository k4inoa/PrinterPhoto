import XCTest
import UIKit
@testable import PrinterPhoto

final class EscPosImageRendererTests: XCTestCase {
    private let renderer = EscPosImageRenderer()

    func testSquareCropFromPortraitImage() throws {
        let image = makeImage(width: 200, height: 400)
        let cropped = try renderer.centerSquareCrop(image)

        XCTAssertEqual(cropped.cgImage?.width, 200)
        XCTAssertEqual(cropped.cgImage?.height, 200)
    }

    func testSquareCropFromLandscapeImage() throws {
        let image = makeImage(width: 400, height: 200)
        let cropped = try renderer.centerSquareCrop(image)

        XCTAssertEqual(cropped.cgImage?.width, 200)
        XCTAssertEqual(cropped.cgImage?.height, 200)
    }

    func testSquareCropKeepsSquareImage() throws {
        let image = makeImage(width: 240, height: 240)
        let cropped = try renderer.centerSquareCrop(image)

        XCTAssertEqual(cropped.cgImage?.width, 240)
        XCTAssertEqual(cropped.cgImage?.height, 240)
    }

    func testRasterCommandUsesByteAlignedPaperWidth() throws {
        let image = makeImage(width: 100, height: 100)
        let command = try renderer.rasterCommand(from: image, paperWidth: .eightyMillimeter)

        XCTAssertEqual(Array(command.prefix(4)), [0x1D, 0x76, 0x30, 0x00])
        XCTAssertEqual(command[4], 72)
        XCTAssertEqual(command[5], 0)
        XCTAssertEqual(command[6], 64)
        XCTAssertEqual(command[7], 2)
        XCTAssertEqual(command.count, 8 + 72 * 576)
    }

    func testPrintDataContainsInitRasterFeedAndCut() throws {
        let image = makeImage(width: 100, height: 100)
        let data = try renderer.printData(from: image, paperWidth: .narrow)

        XCTAssertEqual(Array(data.prefix(2)), [0x1B, 0x40])
        XCTAssertEqual(Array(data.dropFirst(2).prefix(4)), [0x1D, 0x76, 0x30, 0x00])
        XCTAssertEqual(Array(data.suffix(4)), [0x1D, 0x56, 0x42, 0x00])
        XCTAssertTrue(data.contains(Data([0x0A, 0x0A, 0x0A])))
    }

    private func makeImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
    }
}
