import SwiftUI

@main
struct VerifyBlockDragLayout {
    static func main() {
        let a = UUID(), b = UUID(), c = UUID(), end = UUID()
        let ids = [a, b, c]
        let frames = [a: CGRect(x: 20, y: 60, width: 300, height: 80),
                      b: CGRect(x: 20, y: 160, width: 300, height: 100),
                      c: CGRect(x: 20, y: 280, width: 300, height: 80),
                      end: CGRect(x: 20, y: 380, width: 300, height: 40)]
        let full = CGRect(x: 0, y: 0, width: 340, height: 440)
        let clipped = CGRect(x: 0, y: 0, width: 340, height: 250)
        func expect(_ point: CGPoint, _ result: BlockInsertion?, viewport: CGRect = full,
                    measured: [UUID: CGRect] = frames, label: String) {
            precondition(BlockDragLayout.insertion(at: point, ids: ids, frames: measured,
                                                  endID: end, viewport: viewport) == result, label)
        }
        expect(CGPoint(x: 100, y: 70), .before(a), label: "Upper first card inserts first")
        expect(CGPoint(x: 100, y: 130), .before(b), label: "Lower first card inserts before second")
        expect(CGPoint(x: 100, y: 150), .before(b), label: "Card gap has predictable insertion")
        expect(CGPoint(x: 100, y: 330), .end, label: "Lower final card inserts at end")
        expect(CGPoint(x: 100, y: 400), .end, label: "Explicit end drop area works")
        expect(CGPoint(x: 100, y: 330), nil, viewport: clipped, label: "Offscreen card cannot accept drop")
        expect(CGPoint(x: 100, y: 400), nil, viewport: clipped, label: "Offscreen end target cannot accept drop")
        expect(CGPoint(x: 5, y: 100), nil, label: "Outside card region rejects drop")
        expect(CGPoint(x: 400, y: 100), nil, label: "Inspector-side drop rejected")
        expect(CGPoint(x: 100, y: 30), nil, label: "Header-side drop rejected")
        expect(CGPoint(x: 100, y: 70), nil, measured: [:], label: "Missing layout cannot accept drop")
        // Frames move as the document scrolls while the viewport remains fixed.
        let scrolled = frames.mapValues { $0.offsetBy(dx: 0, dy: -200) }
        expect(CGPoint(x: 100, y: 90), .before(c), viewport: clipped, measured: scrolled,
               label: "Scrolled frames resolve in viewport coordinates")
        print("12 drag layout assertions passed")
    }
}
