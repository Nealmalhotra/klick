import CoreGraphics
import SwiftUI

/// Dimensions of the wheel, in points. Proportions measured from the original recording.
enum WheelMetrics {
    static let diameter: CGFloat = 296
    static var radius: CGFloat { diameter / 2 }
    /// Outer edge of the segments (leaves a thin glass rim).
    static let segmentOuterRadius: CGFloat = 140
    /// Inner edge of the segments (wraps the hub with a gap).
    static let segmentInnerRadius: CGFloat = 60
    /// Hub ring radius.
    static let hubRadius: CGFloat = 51
    /// Constant-width gap between neighbouring segments.
    static let segmentGap: CGFloat = 8
    /// Corner rounding of each segment ("more round" than the original).
    static let cornerRadius: CGFloat = 15
    /// Transparent margin around the disk inside the panel (shadow + hover pop).
    static let panelMargin: CGFloat = 70
    static var panelSize: CGFloat { diameter + panelMargin * 2 }

    /// Below this distance from the center nothing is highlighted.
    static let deadZone: CGFloat = 46
    /// Beyond this distance nothing is highlighted (lets you "leave" the wheel).
    static var outerTolerance: CGFloat { radius + 46 }

    /// Angle (radians, 0 = 12 o'clock, clockwise) of the middle of segment `index`.
    static func midAngle(index: Int, count: Int) -> Double {
        Double(index) * 2 * .pi / Double(count)
    }

    /// Index of the segment in the direction of `vector` (y up, AppKit), or nil.
    static func segmentIndex(for vector: CGVector, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let distance = hypot(vector.dx, vector.dy)
        guard distance >= deadZone, distance <= outerTolerance else { return nil }
        if count == 1 { return 0 }
        var angle = atan2(Double(vector.dx), Double(vector.dy)) // clockwise from top
        if angle < 0 { angle += 2 * .pi }
        let step = 2 * .pi / Double(count)
        return Int(((angle + step / 2) / step).rounded(.down)) % count
    }
}

/// An annular sector with a constant-width gap to its neighbours and uniformly
/// rounded corners (Minkowski sum of a shrunken sector with a disk).
struct WheelSegmentShape: Shape {
    let index: Int
    let count: Int
    var innerRadius: CGFloat = WheelMetrics.segmentInnerRadius
    var outerRadius: CGFloat = WheelMetrics.segmentOuterRadius
    var gap: CGFloat = WheelMetrics.segmentGap
    var corner: CGFloat = WheelMetrics.cornerRadius

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if count <= 1 {
            // Single action: a full ring.
            var ring = Path()
            ring.addEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
            ring.addEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
            return ring
        }

        let step = 2 * Double.pi / Double(count)
        // Screen angles: 0 = +x, clockwise (SwiftUI y grows downward); 12 o'clock = -π/2.
        let mid = -Double.pi / 2 + Double(index) * step
        let a0 = mid - step / 2
        let a1 = mid + step / 2

        let c = min(corner, (outerRadius - innerRadius) / 2 - 1)
        let r1 = innerRadius + c
        let r2 = outerRadius - c
        let d = gap / 2 + c // distance of the shrunken straight edges from the radial lines

        guard d < r1 else { return Path() }
        let inner0 = a0 + asin(Double(d / r1))
        let inner1 = a1 - asin(Double(d / r1))
        let outer0 = a0 + asin(Double(d / r2))
        let outer1 = a1 - asin(Double(d / r2))
        guard inner1 > inner0, outer1 > outer0 else { return Path() }

        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        }

        let core = CGMutablePath()
        core.move(to: point(r1, inner0))
        core.addLine(to: point(r2, outer0))
        core.addArc(center: center, radius: r2, startAngle: outer0, endAngle: outer1, clockwise: false)
        core.addLine(to: point(r1, inner1))
        core.addArc(center: center, radius: r1, startAngle: inner1, endAngle: inner0, clockwise: true)
        core.closeSubpath()

        let rounded = core.copy(strokingWithWidth: c * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return Path(core.union(rounded))
    }

    /// Center of the label for this segment, relative to the wheel center (SwiftUI coordinates).
    static func labelOffset(index: Int, count: Int) -> CGSize {
        guard count > 1 else { return CGSize(width: 0, height: -(WheelMetrics.segmentInnerRadius + WheelMetrics.segmentOuterRadius) / 2) }
        let angle = -Double.pi / 2 + WheelMetrics.midAngle(index: index, count: count)
        let r = (WheelMetrics.segmentInnerRadius + WheelMetrics.segmentOuterRadius) / 2 + 2
        return CGSize(width: r * CGFloat(cos(angle)), height: r * CGFloat(sin(angle)))
    }

    /// Unit vector pointing outward through the middle of the segment.
    static func outwardVector(index: Int, count: Int) -> CGSize {
        let angle = -Double.pi / 2 + WheelMetrics.midAngle(index: index, count: count)
        return CGSize(width: CGFloat(cos(angle)), height: CGFloat(sin(angle)))
    }
}

/// A ring (annulus) shape, used for the hub's bright edge.
struct RingShape: Shape {
    var outer: CGFloat
    var inner: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p
    }
}
