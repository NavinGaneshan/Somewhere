import SwiftUI

/// Slim time scrubber. "Now" is always centered; drag left for past, right for future.
/// Light hour ticks and labels shown along the track.
struct TimeBar: View {
    @Binding var selectedTime: Int?   // minutes-from-midnight; nil = no filter

    private let windowMins = 180      // ±3 hours visible on each side
    private let amber = Color(hex: "#E87A2C")
    private let tickCol  = Color.white.opacity(0.15)
    private let labelCol = Color.white.opacity(0.22)

    // MARK: - Time helpers

    private var nowMins: Int {
        let c = Calendar.current
        let h = c.component(.hour, from: Date())
        let m = c.component(.minute, from: Date())
        return h * 60 + m
    }

    private var winStart: Int { nowMins - windowMins }
    private var winEnd:   Int { nowMins + windowMins }
    private var span:     Int { windowMins * 2 }

    private func fraction(_ mins: Int) -> CGFloat {
        CGFloat(mins - winStart) / CGFloat(span)
    }

    private func minsFrom(_ x: CGFloat, width: CGFloat) -> Int {
        let f = max(0, min(1, x / width))
        return winStart + Int(f * CGFloat(span))
    }

    private func hourLabel(_ h: Int) -> String {
        let h24 = ((h % 24) + 24) % 24
        switch h24 {
        case 0:  return "12A"
        case 12: return "12P"
        default: return h24 < 12 ? "\(h24)A" : "\(h24 - 12)P"
        }
    }

    private func formatTime(_ m: Int) -> String {
        let norm = ((m % 1440) + 1440) % 1440
        let h = norm / 60; let mn = norm % 60
        let d = h == 0 ? 12 : h > 12 ? h - 12 : h
        let p = h >= 12 ? "PM" : "AM"
        return mn == 0 ? "\(d)\(p)" : "\(d):\(String(format: "%02d", mn))\(p)"
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let trackY: CGFloat = h - 14    // track near bottom; label + ticks above
            let nowX = w / 2               // "now" is always the midpoint
            let selX = selectedTime.map { fraction($0) * w }

            ZStack {
                // Hour ticks + labels (Canvas for performance)
                Canvas { ctx, size in
                    let firstH = Int(ceil(Double(winStart) / 60.0))
                    let lastH  = Int(floor(Double(winEnd) / 60.0))
                    guard firstH <= lastH else { return }
                    for hour in firstH...lastH {
                        let tx = fraction(hour * 60) * size.width
                        guard tx > 2 && tx < size.width - 2 else { continue }
                        // Tick
                        var t = Path()
                        t.move(to:    CGPoint(x: tx, y: trackY - 6))
                        t.addLine(to: CGPoint(x: tx, y: trackY - 1))
                        ctx.stroke(t, with: .color(tickCol), lineWidth: 1)
                        // Label
                        let h24 = ((hour % 24) + 24) % 24
                        ctx.draw(
                            Text(hourLabel(h24))
                                .font(.system(size: 8, weight: .regular, design: .monospaced))
                                .foregroundColor(labelCol),
                            at: CGPoint(x: tx, y: trackY + 7),
                            anchor: .center
                        )
                    }
                }
                .frame(width: w, height: h)

                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "#2A2420"))
                    .frame(width: w, height: 3)
                    .position(x: w / 2, y: trackY)

                // NOW — amber center marker
                Rectangle()
                    .fill(amber.opacity(0.7))
                    .frame(width: 1.5, height: 12)
                    .position(x: nowX, y: trackY - 4)
                Circle()
                    .fill(amber)
                    .frame(width: 5, height: 5)
                    .position(x: nowX, y: trackY)

                // Selected time thumb + floating label
                if let t = selectedTime, let sx = selX {
                    Circle()
                        .fill(amber)
                        .frame(width: 16, height: 16)
                        .shadow(color: amber.opacity(0.45), radius: 4)
                        .position(x: sx, y: trackY)

                    Text(formatTime(t))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(amber))
                        .position(x: min(max(sx, 26), w - 26), y: trackY - 22)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        selectedTime = minsFrom(v.location.x, width: w)
                    }
            )
        }
        .frame(height: 46)
    }
}
