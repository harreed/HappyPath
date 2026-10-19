import SwiftUI

/// A quiet animated dot field for the simulator stage.
struct SimulatorDotMatrix: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let spacing: CGFloat = 13
    private let dotColor = WorkbenchStyle.accent

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                paused: reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let time = CGFloat(elapsed * 2.4)
                let columns = Int(ceil(size.width / spacing))
                let rows = Int(ceil(size.height / spacing))

                for row in 0...rows {
                    let y = CGFloat(row) * spacing + spacing / 2
                    let verticalFade = smoothstep(0, 0.16, y / max(size.height, 1))
                        * (1 - smoothstep(0.75, 1, y / max(size.height, 1)))
                    for column in 0...columns {
                        let x = CGFloat(column) * spacing + spacing / 2
                        let horizontalFade = smoothstep(0, 0.12, x / max(size.width, 1))
                            * (1 - smoothstep(0.88, 1, x / max(size.width, 1)))
                        let fade = horizontalFade * verticalFade
                        if fade < 0.015 { continue }

                        // A fixed value per dot breaks up the bands without changing between frames.
                        let seed = sin(CGFloat(row) * 127.1 + CGFloat(column) * 311.7) * 43_758.5453
                        let variation = (seed - floor(seed)) * 2 - 1
                        let bend = 1.1 * sin(y * 0.018 + time * 0.19)
                            + 0.8 * sin(x * 0.012 - y * 0.009 + time * 0.13)
                        let firstPhase = x * 0.021 + y * 0.014 + bend - time * 0.80 + variation * 0.45
                        let firstWave = sin(firstPhase)
                        let secondBend = 1.4 * sin(x * 0.007 + time * 0.16)
                        let secondPhase = x * 0.011 - y * 0.029 + secondBend + time * 0.47 - variation * 0.35
                        let secondWave = sin(secondPhase)
                        let wave = min(max(0.5 + 0.30 * firstWave + 0.20 * secondWave, 0), 1)
                        let radius = 1 + wave * 0.55 + variation * 0.08
                        let opacity = fade * (0.22 + 0.32 * wave) * (1 + variation * 0.10)
                        let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                          width: radius * 2, height: radius * 2))
                        context.fill(dot, with: .color(dotColor.opacity(opacity)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func smoothstep(_ start: CGFloat, _ end: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
