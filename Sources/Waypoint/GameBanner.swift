import AppKit
import ImageIO

/// Prepares the catalog's pictures and icons for the library's rows.
///
/// A picture is never shown as it is on disk: decoded, box art is a few
/// megabytes and a row shows a band of it. The band is cut off the main
/// thread at the size it shows at, in the display's pixels and no larger than
/// the picture itself, and kept while the app runs. Icons are drawn once per
/// size the same way.
@MainActor
final class GameBanners {
    static let shared = GameBanners()

    private var strips: [Strip: CGImage] = [:]
    private var waiting: [Strip: [(CGImage?) -> Void]] = [:]
    private var icons: [Icon: CGImage] = [:]
    /// Files that couldn't be drawn: not tried again.
    private var unusable: Set<URL> = []
    private var waitingIcons: [Icon: [(CGImage?) -> Void]] = [:]

    private struct Strip: Hashable {
        var file: URL
        var width: Int
        var height: Int
    }

    private struct Icon: Hashable {
        var file: URL
        var pixels: Int
    }

    /// The picture at `file` cut to fill `pixels`, to `then` on the main
    /// actor: at once if it has been made, else when it has. Sizes are
    /// rounded up to a few steps, so resizing the window makes few strips.
    func strip(of file: URL, pixels: CGSize, then: @escaping (CGImage?) -> Void) {
        let key = Strip(file: file, width: max(1, Int((pixels.width / 128).rounded(.up))) * 128,
                        height: max(1, Int((pixels.height / 32).rounded(.up))) * 32)
        if let strip = strips[key] { return then(strip) }
        guard !unusable.contains(file) else { return then(nil) }
        waiting[key, default: []].append(then)
        guard waiting[key]?.count == 1 else { return }
        Task.detached(priority: .utility) { [weak self] in
            let strip = Self.makeStrip(of: file, width: key.width, height: key.height)
            await self?.made(strip, for: key)
        }
    }

    private func made(_ strip: CGImage?, for key: Strip) {
        // Only the newest size of a picture is kept.
        strips = strips.filter { $0.key.file != key.file }
        if let strip { strips[key] = strip } else { unusable.insert(key.file) }
        for then in waiting.removeValue(forKey: key) ?? [] { then(strip) }
    }

    /// Decodes no larger than needed, then draws a band of that into a
    /// bitmap of its own: a cropped CGImage would keep the whole decoded
    /// picture alive. A picture smaller than the band is not blown up here;
    /// the view stretches it when drawing, which costs no memory.
    private nonisolated static func makeStrip(of file: URL, width: Int, height: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Double,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Double,
              sourceWidth > 0, sourceHeight > 0, sourceWidth <= 16384, sourceHeight <= 16384 else { return nil }
        // Scaled to cover the band, the picture is this many times its size.
        let cover = max(Double(width) / sourceWidth, Double(height) / sourceHeight)
        let shrink = min(cover, 1)
        let bandWidth = max(1, Int((Double(width) / cover * shrink).rounded()))
        let bandHeight = max(1, Int((Double(height) / cover * shrink).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: (max(sourceWidth, sourceHeight) * shrink).rounded(.up),
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(data: nil, width: bandWidth, height: bandHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let fill = max(Double(bandWidth) / Double(small.width), Double(bandHeight) / Double(small.height))
        let size = CGSize(width: Double(small.width) * fill, height: Double(small.height) * fill)
        // Which band of a tall picture: box art has its faces in the upper
        // third and its logo below, so the band is taken around 30% down. A
        // very tall one (the install pictures) has the logo on top and the
        // faces near the middle. (CGContext's y runs upward.)
        let focus = Double(small.height) > Double(small.width) * 1.7 ? 0.46 : 0.3
        let above = size.height > Double(bandHeight) * 1.5
            ? min(max(size.height * focus - Double(bandHeight) / 2, 0), size.height - Double(bandHeight))
            : (size.height - Double(bandHeight)) / 2
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(x: (Double(bandWidth) - size.width) / 2, y: Double(bandHeight) - size.height + above,
                                       width: size.width, height: size.height))
        return context.makeImage()
    }

    /// The icon at `file` drawn `pixels` wide and high, to `then` on the main
    /// actor: at once if it has been made, else when it has.
    func icon(of file: URL, pixels: Int, then: @escaping (CGImage?) -> Void) {
        let key = Icon(file: file, pixels: pixels)
        if let icon = icons[key] { return then(icon) }
        guard !unusable.contains(file) else { return then(nil) }
        waitingIcons[key, default: []].append(then)
        guard waitingIcons[key]?.count == 1 else { return }
        Task.detached(priority: .utility) { [weak self] in
            let icon = Self.makeIcon(of: file, pixels: pixels)
            await self?.made(icon, for: key)
        }
    }

    private func made(_ icon: CGImage?, for key: Icon) {
        if let icon { icons[key] = icon } else { unusable.insert(key.file) }
        for then in waitingIcons.removeValue(forKey: key) ?? [] { then(icon) }
    }

    /// An emblem fitted into a square with a margin, as it sits on its tile.
    /// SVG is drawn by AppKit at this very size; anything else is scaled
    /// down by ImageIO.
    private nonisolated static func makeIcon(of file: URL, pixels: Int) -> CGImage? {
        guard pixels > 0, pixels <= 1024, let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let side = Double(pixels)
        func fitted(_ width: Double, _ height: Double, margin: Double) -> CGRect {
            let scale = (side - 2 * margin) / max(width, height)
            return CGRect(x: (side - width * scale) / 2, y: (side - height * scale) / 2, width: width * scale, height: height * scale)
        }
        context.interpolationQuality = .high
        if isMarkup(data) {
            guard isPlainDrawing(data), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            image.draw(in: fitted(image.size.width, image.size.height, margin: side * 0.12))
            NSGraphicsContext.restoreGraphicsState()
        } else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let small = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: pixels,
                  ] as CFDictionary) {
            context.draw(small, in: fitted(Double(small.width), Double(small.height), margin: 0))
        } else {
            return nil
        }
        return context.makeImage()
    }

    /// Text that begins like XML, after a byte-order mark and white space.
    nonisolated static func isMarkup(_ data: Data) -> Bool {
        var bytes = data.prefix(64)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return bytes.first { $0 != 0x20 && !(0x09...0x0D).contains($0) } == UInt8(ascii: "<")
    }

    /// Whether an SVG is small and made only of shapes, as the catalog's
    /// emblems are. A filter or a chain of `use` in a few hundred bytes can
    /// make drawing it take gigabytes, whatever size it is drawn at; such a
    /// file is not drawn at all.
    nonisolated static func isPlainDrawing(_ svg: Data) -> Bool {
        guard svg.count <= 256 << 10, let text = String(data: svg, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return false }
        let allowed: Set<Substring> = ["svg", "g", "path", "defs", "clipPath", "rect", "circle", "ellipse", "polygon", "polyline",
                                       "line", "linearGradient", "radialGradient", "stop", "title", "desc"]
        var rest = text[...]
        while let open = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: open)...]
            if rest.hasPrefix("/") || rest.hasPrefix("?xml ") || rest.hasPrefix("!--") { continue }
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" || $0 == "_" }
            guard allowed.contains(name) else { return false }
        }
        return true
    }
}

/// A faint band of a game's picture behind the trailing part of its row,
/// fading out toward the text, so the name and status stay as readable as on
/// a row without one, in light and dark.
@MainActor
final class BannerView: NSView {
    /// How much of the row's width the picture takes. Box art is 600 pixels
    /// wide; a band of it covers this much of the default window at 2x
    /// without being stretched.
    static let share: CGFloat = 0.6

    /// Under 1 for a quieter picture: a game that isn't installed.
    var strength: CGFloat = 1 { didSet { if strength != oldValue { needsDisplay = true } } }

    private var picture: URL?
    private var strip: CGImage?
    private var requested: CGSize = .zero

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(picture file: URL) {
        guard file != picture else { return }
        picture = file
        strip = nil
        requested = .zero
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let picture, bounds.width > 0, bounds.height > 0 else { return }
        let pixels = convertToBacking(bounds).size
        guard pixels != requested else { return }
        requested = pixels
        GameBanners.shared.strip(of: picture, pixels: pixels) { [weak self] strip in
            // A slower answer for another picture or an earlier size is not this one's.
            guard let self, self.picture == picture, self.requested == pixels else { return }
            self.strip = strip
            self.needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Moved to a display with another pixel density: cut the picture again
    /// for that one.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let strip, let context = NSGraphicsContext.current?.cgContext else { return }
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
        // Fill the view, keeping the picture's shape.
        let fill = max(bounds.width / CGFloat(strip.width), bounds.height / CGFloat(strip.height))
        let size = CGSize(width: CGFloat(strip.width) * fill, height: CGFloat(strip.height) * fill)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.interpolationQuality = .high
        context.draw(strip, in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                       width: size.width, height: size.height))
        // Keep of the picture only what the gradient covers: nothing at the
        // leading edge, and never all of it, since the buttons and the
        // status sit on it.
        let showing: [(alpha: CGFloat, at: CGFloat)] = [(0, 0), (0.03, 0.15), (0.11, 0.32), (0.24, 0.55), (0.42, 1)]
        context.setBlendMode(.destinationIn)
        if let mask = CGGradient(colorsSpace: nil, colors: showing.map { NSColor.black.withAlphaComponent($0.alpha * strength).cgColor } as CFArray,
                                 locations: showing.map(\.at)) {
            context.drawLinearGradient(mask, start: CGPoint(x: bounds.minX, y: 0), end: CGPoint(x: bounds.maxX, y: 0), options: [])
        }
        context.endTransparencyLayer()
    }
}
