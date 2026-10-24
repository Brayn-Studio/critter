#if DEBUG
import SwiftUI

/// `-critterPressCheck`: drives a `PressedLook` with a 20 ms tap and then a 200 ms press, a second after the gallery
/// opens, and prints when it shows down and up, in milliseconds from each touch-down:
///
///     press tap: down at +0 ms, up at +70 ms
///     press hold: down at +0 ms, up at +200 ms
///
/// (the pressed look shows at touch-down, a quick tap stays down 70 ms, a long press comes up with the finger).
struct PressCheck: View {
    @State private var pressed = false
    @State private var label = ""
    @State private var start = ContinuousClock.now
    @State private var downAt: Duration?

    var body: some View {
        PressedLook(pressed: pressed) { down in
            Color.clear
                .frame(width: 1, height: 1)
                .onChange(of: down) { _, down in record(down) }
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            await press("tap", for: .milliseconds(20))
            try? await Task.sleep(for: .milliseconds(400))
            await press("hold", for: .milliseconds(200))
        }
    }

    private func press(_ name: String, for duration: Duration) async {
        label = name
        downAt = nil
        start = .now
        pressed = true
        try? await Task.sleep(for: duration)
        pressed = false
        try? await Task.sleep(for: .milliseconds(150))
    }

    private static func ms(_ d: Duration) -> Int {
        Int(d.components.seconds) * 1000 + Int((Double(d.components.attoseconds) / 1e15).rounded())
    }

    private func record(_ down: Bool) {
        let at = ContinuousClock.now - start
        if down {
            downAt = at
        } else {
            let line = "press \(label): down at +\(downAt.map(Self.ms) ?? -1) ms, up at +\(Self.ms(at)) ms\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}
#endif
