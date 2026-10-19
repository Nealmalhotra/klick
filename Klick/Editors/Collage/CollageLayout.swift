import CoreGraphics
import Foundation

/// How the pictures of a collage are arranged.
enum CollageStyle: String, CaseIterable, Hashable {
    /// Justified rows: every picture uncropped, rows balanced to a pleasant 3:2-ish canvas.
    case auto = "Auto"
    /// Uniform cells; pictures fill (and are cropped to) their cell.
    case grid = "Grid"
    case row = "Row"
    case column = "Column"
}

/// Canvas size and picture frames, in output pixels (top-left origin).
struct CollageLayout: Equatable {
    let canvas: CGSize
    /// One frame per picture, in the same order as the sizes passed in.
    let tiles: [CGRect]

    /// Width used by Auto, Grid and Column before the long-side cap.
    static let referenceWidth: CGFloat = 3000
    /// Picture height in a Row (and width in a Column).
    static let referenceStrip: CGFloat = 1400
    /// Largest side of a saved collage.
    static let maxLongSide: CGFloat = 8000
    /// Canvas height / width that Auto aims for.
    private static let autoTargetRatio: CGFloat = 0.66

    /// - Parameters:
    ///   - sizes: oriented pixel size of every picture, in display order.
    ///   - spacing: gap between pictures and around the edge, in output pixels.
    init(sizes: [CGSize], style: CollageStyle, spacing: CGFloat) {
        let aspects = sizes.map { $0.height > 0 ? max(min($0.width / $0.height, 8), 0.125) : 1 }
        let s = max(spacing, 0)
        var canvas: CGSize
        var tiles: [CGRect]
        switch style {
        case .auto: (canvas, tiles) = Self.justified(aspects, spacing: s)
        case .grid: (canvas, tiles) = Self.grid(aspects, spacing: s)
        case .row: (canvas, tiles) = Self.strip(aspects, spacing: s, horizontal: true)
        case .column: (canvas, tiles) = Self.strip(aspects, spacing: s, horizontal: false)
        }
        // Long rows / columns are scaled down as a whole so the file stays reasonable.
        let longSide = max(canvas.width, canvas.height)
        if longSide > Self.maxLongSide {
            let k = Self.maxLongSide / longSide
            canvas = CGSize(width: canvas.width * k, height: canvas.height * k)
            tiles = tiles.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k) }
        }
        self.canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        self.tiles = tiles.map { $0.integral }
    }

    // MARK: Styles

    /// Splits the pictures (in order) into rows that each span the full width at a shared
    /// height, trying every row count and keeping the canvas closest to the target ratio.
    private static func justified(_ aspects: [CGFloat], spacing s: CGFloat) -> (CGSize, [CGRect]) {
        let width = referenceWidth
        var best: (score: CGFloat, canvas: CGSize, tiles: [CGRect])?
        for rowCount in 1...max(aspects.count, 1) {
            let rows = partition(aspects, into: rowCount)
            var tiles: [CGRect] = []
            var y = s
            for row in rows {
                let sum = row.reduce(0) { $0 + aspects[$1] }
                let height = (width - s * CGFloat(row.count + 1)) / sum
                var x = s
                for index in row {
                    tiles.append(CGRect(x: x, y: y, width: height * aspects[index], height: height))
                    x += height * aspects[index] + s
                }
                y += height + s
            }
            let canvas = CGSize(width: width, height: y)
            let score = abs(log((canvas.height / canvas.width) / autoTargetRatio))
            if best == nil || score < best!.score - 0.0001 { best = (score, canvas, tiles) }
        }
        return best.map { ($0.canvas, $0.tiles) } ?? (CGSize(width: width, height: width), [])
    }

    /// Ordered split of `aspects` into at most `count` rows with similar aspect sums.
    private static func partition(_ aspects: [CGFloat], into count: Int) -> [[Int]] {
        let target = aspects.reduce(0, +) / CGFloat(count)
        var rows: [[Int]] = [[]]
        var sum: CGFloat = 0
        for (index, aspect) in aspects.enumerated() {
            let remainingItems = aspects.count - index
            let remainingRows = count - rows.count
            let closerIfBroken = abs(sum + aspect - target) > abs(sum - target)
            if !rows[rows.count - 1].isEmpty, remainingRows > 0, closerIfBroken || remainingItems <= remainingRows {
                rows.append([])
                sum = 0
            }
            rows[rows.count - 1].append(index)
            sum += aspect
        }
        return rows
    }

    /// Near-square grid of identical cells shaped like the median picture; a shorter last
    /// row is centered.
    private static func grid(_ aspects: [CGFloat], spacing s: CGFloat) -> (CGSize, [CGRect]) {
        let n = max(aspects.count, 1)
        let columns = Int(ceil(sqrt(Double(n))))
        let rows = Int(ceil(Double(n) / Double(columns)))
        let sorted = aspects.sorted()
        let cellAspect = min(max(sorted.isEmpty ? 1 : sorted[sorted.count / 2], 0.6), 1.8)
        let cellWidth = (referenceWidth - s * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = cellWidth / cellAspect
        var tiles: [CGRect] = []
        for index in aspects.indices {
            let row = index / columns
            let column = index % columns
            let inRow = row == rows - 1 ? n - row * columns : columns
            let inset = CGFloat(columns - inRow) * (cellWidth + s) / 2
            tiles.append(CGRect(
                x: s + inset + CGFloat(column) * (cellWidth + s),
                y: s + CGFloat(row) * (cellHeight + s),
                width: cellWidth, height: cellHeight
            ))
        }
        return (CGSize(width: referenceWidth, height: s + CGFloat(rows) * (cellHeight + s)), tiles)
    }

    /// Side by side at the same height (or stacked at the same width).
    private static func strip(_ aspects: [CGFloat], spacing s: CGFloat, horizontal: Bool) -> (CGSize, [CGRect]) {
        let side = referenceStrip
        var tiles: [CGRect] = []
        var offset = s
        for aspect in aspects {
            if horizontal {
                tiles.append(CGRect(x: offset, y: s, width: side * aspect, height: side))
                offset += side * aspect + s
            } else {
                tiles.append(CGRect(x: s, y: offset, width: side, height: side / aspect))
                offset += side / aspect + s
            }
        }
        let canvas = horizontal ? CGSize(width: offset, height: side + 2 * s) : CGSize(width: side + 2 * s, height: offset)
        return (canvas, tiles)
    }
}
