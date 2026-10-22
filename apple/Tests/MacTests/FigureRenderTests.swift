import AppKit
import XCTest

@testable import BinauralCore

@testable import Binaural

/// A temporary harness: renders the chakra figure into a PNG so its shape can be
/// looked at rather than guessed at. Deleted once the drawing is settled.
@MainActor
final class FigureRenderTests: XCTestCase {

    func testRenderFigure() throws {
        let view = ChakraFigureView(frame: NSRect(x: 0, y: 0, width: 90, height: 190))
        view.currentIndex = 4
        view.reachedIndex = 4
        view.setFrameSize(view.frame.size)
        view.layoutSubtreeIfNeeded()

        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = rep.representation(using: .png, properties: [:])!
        try data.write(to: URL(fileURLWithPath: "/tmp/chakra-figure.png"))
        print("WROTE /tmp/chakra-figure.png")
    }
}
