import XCTest
import UIKit
@testable import Fox

@MainActor
final class JournalDisplayTests: XCTestCase {
    func testLargeDisplayDecodeIsBoundedAndOriginalIsUnchanged() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 2200), format: format).pngData { $0.fill(CGRect(x: 0, y: 0, width: 480, height: 2200)) }
        let copy = original
        let rendered = try JournalMedia.thumbnail(original, maxPixelSize: 400)
        let image = try XCTUnwrap(UIImage(data: rendered))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 400)
        XCTAssertEqual(original, copy)
        XCTAssertThrowsError(try JournalMedia.thumbnail(original, maxPixelSize: 5000))
    }
    func testNativePhotoZoomFitsThenClampsAndRefitsAfterResize() {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 1000), format: format).image { $0.fill(CGRect(x: 0, y: 0, width: 100, height: 1000)) }
        let view = JournalPhotoScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        view.setImage(image); view.layoutIfNeeded()
        XCTAssertEqual(view.minimumZoomScale, 0.8, accuracy: 0.001)
        view.adjustZoom(1); XCTAssertGreaterThan(view.zoomScale, view.minimumZoomScale)
        for _ in 0..<30 { view.adjustZoom(1) }
        XCTAssertLessThanOrEqual(view.zoomScale, view.maximumZoomScale)
        view.adjustZoom(0); XCTAssertEqual(view.zoomScale, view.minimumZoomScale)
        view.frame.size = CGSize(width: 800, height: 400); view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.minimumZoomScale, 0.4, accuracy: 0.001)
    }
}
