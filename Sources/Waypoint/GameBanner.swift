import AppKit
import ImageIO
import IOSurface

/// A band of a picture, in memory Core Animation shows as it is: a layer
/// with it as its contents needs no copy of its own.
struct Strip: @unchecked Sendable {
    let surface: IOSurface
}

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

    private var strips: [StripKey: Strip] = [:]
    private var waiting: [StripKey: [(Strip?) -> Void]] = [:]
    private var icons: [Icon: CGImage] = [:]
    /// Files that couldn't be drawn: not tried again.
    private var unusable: Set<URL> = []
    private var waitingIcons: [Icon: [(CGImage?) -> Void]] = [:]
    /// Pictures and icons are made one at a time: decoded, a picture is a
    /// few megabytes, and a list of them all at once took tens.
    private nonisolated static let maker = DispatchQueue(label: "Waypoint artwork", qos: .utility)

    /// `make` on `maker`, its leftovers let go of when it returns.
    private nonisolated static func oneAtATime<T: Sendable>(_ make: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            maker.async { done.resume(returning: autoreleasepool(invoking: make)) }
        }
    }

    private struct StripKey: Hashable {
        var file: URL
        var width: Int
        var height: Int
    }

    private struct Icon: Hashable {
        var file: URL
        var pixels: Int
    }

    /// Forgets everything made so far: artwork was turned off.
    func removeAll() {
        strips = [:]
        icons = [:]
        unusable = []
    }

    /// The picture at `file` cut to fill `pixels`, to `then` on the main
    /// actor: at once if it has been made, else when it has. Sizes are
    /// rounded up to a few steps, so resizing the window makes few strips.
    func strip(of file: URL, pixels: CGSize, then: @escaping (Strip?) -> Void) {
        let key = StripKey(file: file, width: max(1, Int((pixels.width / 128).rounded(.up))) * 128,
                        height: max(1, Int((pixels.height / 32).rounded(.up))) * 32)
        if let strip = strips[key] { return then(strip) }
        guard !unusable.contains(file) else { return then(nil) }
        waiting[key, default: []].append(then)
        guard waiting[key]?.count == 1 else { return }
        Task { [weak self] in
            let strip = await Self.oneAtATime { Self.makeStrip(of: file, width: key.width, height: key.height) }
            self?.made(strip, for: key)
        }
    }

    private func made(_ strip: Strip?, for key: StripKey) {
        // Only the newest size of a picture is kept.
        strips = strips.filter { $0.key.file != key.file }
        if let strip { strips[key] = strip } else { unusable.insert(key.file) }
        for then in waiting.removeValue(forKey: key) ?? [] { then(strip) }
    }

    /// Decodes no larger than needed, then draws a band of that into a
    /// bitmap of its own: a cropped CGImage would keep the whole decoded
    /// picture alive. A picture smaller than the band is not blown up here;
    /// the view stretches it when drawing, which costs no memory.
    private nonisolated static func makeStrip(of file: URL, width: Int, height: Int) -> Strip? {
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
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let surface = IOSurface(properties: [.width: bandWidth, .height: bandHeight, .bytesPerElement: 4,
                                                   .pixelFormat: 0x4247_5241 /* BGRA */]) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        if let colors = space.copyPropertyList() { IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colors) }
        guard let context = CGContext(data: surface.baseAddress, width: bandWidth, height: bandHeight, bitsPerComponent: 8,
                                      bytesPerRow: surface.bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
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
        context.flush()
        return Strip(surface: surface)
    }

    /// The icon at `file` drawn `pixels` wide and high, to `then` on the main
    /// actor: at once if it has been made, else when it has.
    func icon(of file: URL, pixels: Int, then: @escaping (CGImage?) -> Void) {
        let key = Icon(file: file, pixels: pixels)
        if let icon = icons[key] { return then(icon) }
        guard !unusable.contains(file) else { return then(nil) }
        waitingIcons[key, default: []].append(then)
        guard waitingIcons[key]?.count == 1 else { return }
        Task { [weak self] in
            let icon = await Self.oneAtATime { Self.makeIcon(of: file, pixels: pixels) }
            self?.made(icon, for: key)
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
/// a row without one, in light and dark. The band is the layer's contents
/// and the fade its mask: nothing is drawn into a buffer of the view's own.
@MainActor
final class BannerView: NSView {
    /// How much of the row's width the picture takes. Box art is 600 pixels
    /// wide; a band of it covers this much of the default window at 2x
    /// without being stretched.
    static let share: CGFloat = 0.6

    /// Under 1 for a quieter picture: a game that isn't installed.
    var strength: CGFloat = 1 { didSet { if strength != oldValue { needsDisplay = true } } }

    private var picture: URL?
    private var strip: Strip?
    private var requested: CGSize = .zero
    private let fade = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Fill the view, keeping the picture's shape. (AppKit sets the
        // layer's gravity from this, and resets what's set on the layer
        // before it is the view's.)
        layerContentsPlacement = .scaleProportionallyToFill
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.mask = fade
        // Keep of the picture only what the gradient covers: nothing at the
        // leading edge, and never all of it, since the buttons and the
        // status sit on it.
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.locations = Self.showing.map { $0.at as NSNumber }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let showing: [(alpha: CGFloat, at: CGFloat)] = [(0, 0), (0.03, 0.15), (0.11, 0.32), (0.24, 0.55), (0.42, 1)]

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = strip?.surface
        fade.colors = Self.showing.map { NSColor.black.withAlphaComponent($0.alpha * strength).cgColor }
    }

    /// Hides the view and lets go of its picture.
    func clear() {
        isHidden = true
        picture = nil
        strip = nil
        requested = .zero
        stopWatchingScrolling()
        needsDisplay = true
    }

    func show(picture file: URL) {
        isHidden = false
        guard file != picture else { return }
        picture = file
        strip = nil
        requested = .zero
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = layer?.bounds ?? bounds
        CATransaction.commit()
        requestStrip()
    }

    /// Asks for the band at the size the view is, once it shows: a row the
    /// list has made but that is scrolled away has none made for it yet.
    private func requestStrip() {
        guard let picture, bounds.width > 0, bounds.height > 0 else { return }
        guard !visibleRect.isEmpty else { return watchScrolling() }
        stopWatchingScrolling()
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

    private var scrolling: [NSObjectProtocol] = []

    /// Asks again as the list scrolls, or its visible part or the list
    /// itself changes size (the window grows, rows above go), until the
    /// view shows.
    private func watchScrolling() {
        guard scrolling.isEmpty, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        clip.documentView?.postsFrameChangedNotifications = true
        let watched: [(NSNotification.Name, NSView?)] = [(NSView.boundsDidChangeNotification, clip),
                                                         (NSView.frameDidChangeNotification, clip),
                                                         (NSView.frameDidChangeNotification, clip.documentView)]
        scrolling = watched.compactMap { name, view in
            guard let view else { return nil }
            return NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                // Looked at again once the rows are in their new places.
                MainActor.assumeIsolated { self?.needsLayout = true }
            }
        }
    }

    private func stopWatchingScrolling() {
        scrolling.forEach(NotificationCenter.default.removeObserver)
        scrolling = []
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        stopWatchingScrolling()
        if newWindow != nil { needsLayout = true }
    }

    /// Moved to a display with another pixel density: cut the picture again
    /// for that one.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}
