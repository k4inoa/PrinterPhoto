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

    // MARK: - Orientation

    func testNonSquareCropUsesDisplayedAxesForRotatedImage() throws {
        // A portrait photo off an iPhone: 400x200 pixels stored landscape, flagged .right,
        // so it displays as 200 wide by 400 tall. A 4:5 crop must be 200x250, not 400x320.
        let image = makeImage(width: 400, height: 200, orientation: .right)
        XCTAssertEqual(image.size, CGSize(width: 200, height: 400))

        let cropped = try renderer.centerCrop(image, ratio: 4.0 / 5.0)

        XCTAssertEqual(cropped.cgImage?.width, 200)
        XCTAssertEqual(cropped.cgImage?.height, 250)
    }

    func testNormalizedUprightMatchesDisplayedSize() throws {
        let image = makeImage(width: 400, height: 200, orientation: .right)
        let upright = try renderer.normalizedUpright(image)

        XCTAssertEqual(upright.imageOrientation, .up)
        XCTAssertEqual(upright.cgImage?.width, 200)
        XCTAssertEqual(upright.cgImage?.height, 400)
    }

    // MARK: - Crop ratios

    func testLandscapeCropFromSquareSource() throws {
        let cropped = try renderer.centerCrop(makeImage(width: 400, height: 400), ratio: 16.0 / 9.0)

        XCTAssertEqual(cropped.cgImage?.width, 400)
        XCTAssertEqual(cropped.cgImage?.height, 225)
    }

    func testPortraitCropFromSquareSource() throws {
        let cropped = try renderer.centerCrop(makeImage(width: 400, height: 400), ratio: 2.0 / 3.0)

        XCTAssertEqual(cropped.cgImage?.width, 267)
        XCTAssertEqual(cropped.cgImage?.height, 400)
    }

    // MARK: - Auto selection

    func testAutoSnapsLandscapeCameraPhotoTo4By3() {
        XCTAssertEqual(CropRatio.resolve(for: CGSize(width: 4032, height: 3024)), .landscape43)
    }

    func testAutoSnapsPortraitCameraPhotoTo3By4() {
        XCTAssertEqual(CropRatio.resolve(for: CGSize(width: 3024, height: 4032)), .portrait34)
    }

    func testAutoSnaps16By9VideoFrame() {
        XCTAssertEqual(CropRatio.resolve(for: CGSize(width: 1920, height: 1080)), .landscape169)
        XCTAssertEqual(CropRatio.resolve(for: CGSize(width: 1080, height: 1920)), .portrait916)
    }

    func testAutoFallsBackToOriginalForTallPhoneScreenshot() {
        // A modern iPhone screen is roughly 19.5:9 - well past the 9:16 option, so the
        // honest answer is to print it uncropped rather than lop off the top and bottom.
        XCTAssertEqual(CropRatio.resolve(for: CGSize(width: 1179, height: 2556)), .original)
    }

    func testAutoKeepsSquareSquare() {
        XCTAssertEqual(CropRatio.resolve(for: CGSize(width: 1000, height: 1000)), .square)
    }

    func testAutoFallsBackToOriginalForUnusualRatio() {
        XCTAssertEqual(CropRatio.resolve(for: CGSize(width: 800, height: 3000)), .original)
    }

    func testOriginalClampsExtremeRatioToPrintableBounds() {
        let ratio = CropRatio.original.effectiveRatio(for: CGSize(width: 800, height: 3000))

        XCTAssertEqual(ratio, 9.0 / 16.0, accuracy: 0.0001)
    }

    func testAutoCropOfCameraRatioLosesNothing() throws {
        let cropped = try renderer.croppedImage(from: makeImage(width: 4032, height: 3024), cropRatio: .auto)

        XCTAssertEqual(cropped.cgImage?.width, 4032)
        XCTAssertEqual(cropped.cgImage?.height, 3024)
    }

    // MARK: - Raster geometry

    func testRasterCommandHeightFollowsCropRatio() throws {
        let image = makeImage(width: 100, height: 100)
        let command = try renderer.rasterCommand(from: image, paperWidth: .eightyMillimeter, cropRatio: .landscape43)

        // 576 dots wide = 72 bytes, 432 lines tall.
        XCTAssertEqual(command[4], 72)
        XCTAssertEqual(command[5], 0)
        XCTAssertEqual(command[6], UInt8(432 & 0xFF))
        XCTAssertEqual(command[7], UInt8(432 >> 8))
        XCTAssertEqual(command.count, 8 + 72 * 432)
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

    private func makeImage(width: Int, height: Int, orientation: UIImage.Orientation = .up) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let base = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        guard orientation != .up, let cgImage = base.cgImage else { return base }
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}
