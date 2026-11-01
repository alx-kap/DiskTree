import SwiftUI

struct TreemapTile: Identifiable {
    let id: Int
    let node: FileNode?          // nil for the "smaller items" group
    let rect: CGRect
    let depth: Int
    let color: Color
    let isContainer: Bool
    let label: String
    let size: Int64
}

enum TreemapLayout {
    static let maxDepth = 3
    private static let hues: [Double] = [0.58, 0.08, 0.38, 0.78, 0.0, 0.5, 0.13, 0.92, 0.68, 0.25]

    static func tiles(for root: FileNode, in bounds: CGRect) -> [TreemapTile] {
        var out: [TreemapTile] = []
        layout(root, in: bounds, depth: 1, hue: nil, out: &out)
        return out
    }

    private static func layout(_ node: FileNode, in rect: CGRect, depth: Int, hue: Int?, out: inout [TreemapTile]) {
        let kids = node.children.filter { $0.size > 0 }
        guard !kids.isEmpty, rect.width > 3, rect.height > 3 else { return }
        let total = Double(kids.reduce(Int64(0)) { $0 + $1.size })
        let area = Double(rect.width * rect.height)
        let minArea: Double = depth == 1 ? 30 : 60

        var shown: [FileNode] = []
        var values: [Double] = []
        var otherSize: Int64 = 0
        var otherCount = 0
        for k in kids {
            let a = Double(k.size) / total * area
            if a >= minArea && shown.count < 300 {
                shown.append(k)
                values.append(a)
            } else {
                otherSize += k.size
                otherCount += 1
            }
        }
        if otherSize > 0 { values.append(Double(otherSize) / total * area) }
        let rects = squarify(values, in: rect)

        for (i, k) in shown.enumerated() {
            let r = rects[i]
            let h = hue ?? i
            let nest = k.isDirectory && depth < maxDepth && r.width > 50 && r.height > 40 && !k.children.isEmpty
            out.append(TreemapTile(
                id: out.count, node: k, rect: r, depth: depth,
                color: color(hue: h, depth: depth, isDirectory: k.isDirectory),
                isContainer: nest, label: k.name, size: k.size
            ))
            if nest {
                let inner = CGRect(x: r.minX + 3, y: r.minY + 18, width: r.width - 6, height: r.height - 21)
                layout(k, in: inner, depth: depth + 1, hue: h, out: &out)
            }
        }
        if otherSize > 0, let r = rects.last {
            out.append(TreemapTile(
                id: out.count, node: nil, rect: r, depth: depth, color: Color(white: 0.55, opacity: 0.5),
                isContainer: false, label: "\(otherCount) smaller item\(otherCount == 1 ? "" : "s")", size: otherSize
            ))
        }
    }

    private static func color(hue index: Int, depth: Int, isDirectory: Bool) -> Color {
        let h = hues[index % hues.count]
        let d = Double(depth - 1)
        let s = (isDirectory ? 0.62 : 0.42) - d * 0.08
        let b = (isDirectory ? 0.80 : 0.88) + d * 0.04
        return Color(hue: h, saturation: max(0.2, s), brightness: min(0.97, b))
    }

    /// Squarified treemap (Bruls, Huizing & van Wijk). `values` are areas summing to the rect's area.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var i = 0
        while i < values.count {
            let short = Double(min(remaining.width, remaining.height))
            if short <= 0 { break }
            var rowEnd = i + 1
            var rowSum = values[i]
            var best = worst(sum: rowSum, maxV: values[i], minV: values[i], side: short)
            while rowEnd < values.count {
                let s = rowSum + values[rowEnd]
                let mx = max(values[i], values[rowEnd])
                let mn = min(values[rowEnd - 1], values[rowEnd])
                let w = worst(sum: s, maxV: mx, minV: mn, side: short)
                if w > best { break }
                best = w
                rowSum = s
                rowEnd += 1
            }
            let thickness = rowSum / short
            if remaining.width >= remaining.height {
                var y = Double(remaining.minY)
                for k in i..<rowEnd {
                    let h = values[k] / thickness
                    result[k] = CGRect(x: remaining.minX, y: y, width: thickness, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + thickness, y: remaining.minY,
                                   width: max(0, remaining.width - thickness), height: remaining.height)
            } else {
                var x = Double(remaining.minX)
                for k in i..<rowEnd {
                    let w = values[k] / thickness
                    result[k] = CGRect(x: x, y: remaining.minY, width: w, height: thickness)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thickness,
                                   width: remaining.width, height: max(0, remaining.height - thickness))
            }
            i = rowEnd
        }
        return result
    }

    private static func worst(sum: Double, maxV: Double, minV: Double, side: Double) -> Double {
        let s2 = sum * sum, w2 = side * side
        return max(w2 * maxV / s2, s2 / (w2 * max(minV, 0.0001)))
    }
}

final class HoverModel: ObservableObject {
    @Published var tile: TreemapTile?
}

private final class TreemapCache {
    var key: (ObjectIdentifier, CGSize, Int)?
    var tiles: [TreemapTile] = []

    func tiles(for node: FileNode, size: CGSize, revision: Int) -> [TreemapTile] {
        if let k = key, k.0 == node.id, k.1 == size, k.2 == revision { return tiles }
        key = (node.id, size, revision)
        tiles = TreemapLayout.tiles(for: node, in: CGRect(origin: .zero, size: size))
        return tiles
    }
}

struct TreemapView: View {
    let node: FileNode
    let revision: Int
    @ObservedObject var hover: HoverModel
    var onClick: (FileNode) -> Void
    var onTrash: ([FileNode]) -> Void
    @State private var cache = TreemapCache()

    var body: some View {
        GeometryReader { geo in
            let tiles = cache.tiles(for: node, size: geo.size, revision: revision)
            let hovered = hover.tile
            Canvas { ctx, _ in
                for t in tiles { draw(t, in: &ctx) }
                if let h = hovered, h.id < tiles.count {
                    let path = Path(roundedRect: h.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3)
                    ctx.fill(path, with: .color(.white.opacity(0.18)))
                    ctx.stroke(path, with: .color(.white), lineWidth: 2)
                }
            }
            .overlay {
                if tiles.isEmpty {
                    ContentUnavailableView("Empty Folder", systemImage: "folder", description: Text("Nothing here takes up space."))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let t = hit(tiles, p)
                    if t?.id != hover.tile?.id { hover.tile = t }
                case .ended:
                    hover.tile = nil
                }
            }
            .onTapGesture { location in
                if let n = hit(tiles, location)?.node { onClick(n) }
            }
            .contextMenu {
                if let n = hover.tile?.node {
                    FileActionsMenu(nodes: [n], onOpen: onClick, onTrash: onTrash)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func hit(_ tiles: [TreemapTile], _ p: CGPoint) -> TreemapTile? {
        tiles.last { $0.rect.contains(p) }
    }

    private func draw(_ t: TreemapTile, in ctx: inout GraphicsContext) {
        let r = t.rect.insetBy(dx: 0.75, dy: 0.75)
        guard r.width > 0.5, r.height > 0.5 else { return }
        let path = Path(roundedRect: r, cornerRadius: min(3, r.width / 3, r.height / 3))
        ctx.fill(path, with: .color(t.color))
        if t.isContainer {
            ctx.stroke(path, with: .color(.black.opacity(0.12)), lineWidth: 1)
        }
        guard r.width > 44, r.height > 15 else { return }
        var layer = ctx
        layer.clip(to: Path(r.insetBy(dx: 3, dy: 1)))
        let weight: Font.Weight = t.isContainer || t.depth == 1 ? .semibold : .regular
        let showSize = r.height > 32 || t.isContainer
        let title = Text(t.label).font(.system(size: 11, weight: weight)).foregroundColor(.black.opacity(0.78))
        let sizeText = Text("  " + t.size.bytes).font(.system(size: 10)).foregroundColor(.black.opacity(0.5))
        if t.isContainer {
            layer.draw(showSize ? title + sizeText : title, at: CGPoint(x: r.minX + 5, y: r.minY + 2), anchor: .topLeading)
        } else {
            layer.draw(title, at: CGPoint(x: r.minX + 5, y: r.minY + 3), anchor: .topLeading)
            if showSize {
                layer.draw(Text(t.size.bytes).font(.system(size: 10)).foregroundColor(.black.opacity(0.55)),
                           at: CGPoint(x: r.minX + 5, y: r.minY + 17), anchor: .topLeading)
            }
        }
    }
}
