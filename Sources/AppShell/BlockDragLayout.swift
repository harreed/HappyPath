import SwiftUI

enum BlockInsertion: Equatable { case before(UUID), end }

struct BlockFramesPreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

extension View {
    func blockFrame(_ id: UUID, space: String) -> some View {
        background(GeometryReader { proxy in Color.clear.preference(key: BlockFramesPreference.self, value: [id: proxy.frame(in: .named(space))]) })
    }
    func insertionMarker(_ visible: Bool) -> some View {
        overlay(alignment: .top) { if visible { Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -7).allowsHitTesting(false) } }
    }
}

enum BlockDragLayout {
    static func insertion(at point: CGPoint, ids: [UUID], frames: [UUID: CGRect], endID: UUID, viewport: CGRect) -> BlockInsertion? {
        guard viewport.contains(point) else { return nil }
        let validFrames = (ids + [endID]).compactMap { frames[$0] }.filter { !$0.isEmpty }
        guard let first = validFrames.first else { return nil }
        let bounds = validFrames.dropFirst().reduce(first) { $0.union($1) }
        guard bounds.contains(point) else { return nil }
        for id in ids { if let frame = frames[id], point.y < frame.midY { return .before(id) } }
        return .end
    }
}
