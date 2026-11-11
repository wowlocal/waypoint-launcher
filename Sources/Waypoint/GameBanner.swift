import AppKit
import CoreImage
import ImageIO

// PROTOTYPE (banners): artwork a person puts behind a game's row.

/// Finds and prepares banners: `Artwork/<uid>.png` (or jpg, jpeg, heic,
/// tiff) in Waypoint's Application Support folder. Nothing is bundled or
/// downloaded; a game without a file has no banner.
///
/// A picture is never shown as it is on disk. Decoded, a 4K image is about
/// 33 MB whatever its file size; a row needs a strip of about 0.5 MB. The
/// strip is made off the main thread and kept while the app runs.
@MainActor
final class GameBanners {
    static let shared = GameBanners()

    var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Waypoint/Artwork", isDirectory: true) {
        didSet { files = nil }
    }
    /// uid -> file, from one listing of the folder; read again after each
    /// return to Waypoint, so a picture dropped there shows up.
    private var files: [String: URL]?
    private var strips: [Strip: CGImage] = [:]
    private var waiting: [Strip: [(CGImage?) -> Void]] = [:]

    private struct Strip: Hashable {
        var file: URL
        var modified: Date?
        var width: Int
        var height: Int
        var blurred: Bool
    }

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.files = nil }
        }
    }

    func file(for uid: String) -> URL? {
        if files == nil {
            var found: [String: URL] = [:]
            let listed = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in listed.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(file.pathExtension.lowercased()) {
                let uid = file.deletingPathExtension().lastPathComponent
                if found[uid] == nil { found[uid] = file }
            }
            files = found
        }
        return files?[uid]
    }

    /// The picture at `file` cut to fill `pixels`, to `then` on the main
    /// actor: at once if it has been made, else when it has. Sizes are
    /// rounded up to a few steps, so resizing the window makes few strips.
    func strip(of file: URL, pixels: CGSize, blurred: Bool = false, then: @escaping (CGImage?) -> Void) {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        // A tiny strip (for a blur or a color) is made as asked.
        let key = Strip(file: file, modified: modified,
                        width: pixels.width <= 128 ? max(1, Int(pixels.width)) : Int((pixels.width / 256).rounded(.up)) * 256,
                        height: pixels.height <= 32 ? max(1, Int(pixels.height)) : Int((pixels.height / 64).rounded(.up)) * 64,
                        blurred: blurred)
        if let strip = strips[key] { return then(strip) }
        waiting[key, default: []].append(then)
        guard waiting[key]?.count == 1 else { return }
        Task.detached(priority: .utility) { [weak self] in
            var strip = Self.makeStrip(of: file, width: key.width, height: key.height)
            if key.blurred, let sharp = strip { strip = Self.blurred(sharp) }
            await self?.made(strip, for: key)
        }
    }

    private func made(_ strip: CGImage?, for key: Strip) {
        // Only the newest size of a picture is kept.
        strips = strips.filter { $0.key.file != key.file }
        strips[key] = strip
        for then in waiting.removeValue(forKey: key) ?? [] { then(strip) }
    }

    /// Decodes no larger than needed, then draws the middle of that into a
    /// bitmap of its own: a cropped CGImage would keep the whole decoded
    /// picture alive.
    private nonisolated static func makeStrip(of file: URL, width: Int, height: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Double,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Double, sourceWidth > 0, sourceHeight > 0 else { return nil }
        // Scaled to cover the strip, the picture's longer side is this long.
        let scale = max(Double(width) / sourceWidth, Double(height) / sourceHeight)
        let longest = (max(sourceWidth, sourceHeight) * min(scale, 1)).rounded(.up)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let fill = max(Double(width) / Double(small.width), Double(height) / Double(small.height))
        let size = CGSize(width: Double(small.width) * fill, height: Double(small.height) * fill)
        // Which band of a tall picture: box art has its faces in the upper
        // third and its logo below, so the band is taken around 30% down. A
        // very tall one (the install pictures) has the logo on top and the
        // faces near the middle. (CGContext's y runs upward.)
        let focus = Double(small.height) > Double(small.width) * 1.7 ? 0.46 : 0.3
        let above = size.height > Double(height) * 1.5 ? min(max(size.height * focus - Double(height) / 2, 0), size.height - Double(height)) : (size.height - Double(height)) / 2
        context.interpolationQuality = .high
        context.draw(small, in: CGRect(x: (Double(width) - size.width) / 2, y: Double(height) - size.height + above,
                                       width: size.width, height: size.height))
        return context.makeImage()
    }
}

extension GameBanners {
    /// `image` blurred until only its colors are left. Its edges are
    /// stretched outward first, so they don't fade to nothing.
    fileprivate nonisolated static func blurred(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let soft = input.clampedToExtent().applyingGaussianBlur(sigma: Double(image.height) / 2.5).cropped(to: input.extent)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(soft, from: input.extent)
    }
}

/// What shows behind a game's row. Whatever the style, it fades out toward
/// the leading edge, so the name and status stay as readable as on a row
/// without it, in light and dark.
@MainActor
final class BannerView: NSView {
    /// PROTOTYPE: the looks being compared.
    enum Style: String {
        /// The picture on the trailing side of the row, faint.
        case soft
        /// The picture blurred to its colors, on the trailing two thirds.
        case blur
        /// No picture: a wash of the picture's main color from the trailing edge.
        case tint
        /// The same wash, from the game's own icon: needs no picture, so every game has one.
        case icontint
        /// Earlier, louder versions.
        case fade, card

        /// Drawn as a rounded shape of its own, which replaces the hairline
        /// between rows. A wash has no edge and keeps the hairlines.
        var isCard: Bool { self != .tint && self != .icontint }
    }

    nonisolated static let style = Style(rawValue: ProcessInfo.processInfo.environment["WAYPOINT_BANNER_STYLE"] ?? "") ?? .soft

    /// Under 1 for a quieter picture: a game that isn't installed.
    var strength: CGFloat = 1 { didSet { if strength != oldValue { needsDisplay = true } } }

    private var picture: URL?
    private var icon: String?
    private var strip: CGImage?
    private var tint: NSColor?
    private var requested: CGSize = .zero
    private static var iconTints: [String: NSColor?] = [:]

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(picture file: URL) {
        guard file != picture else { return }
        picture = file
        icon = nil
        strip = nil
        tint = nil
        requested = .zero
        needsLayout = true
        needsDisplay = true
    }

    /// The wash for the app at `path`, from its icon's main color.
    func show(iconAt path: String) {
        guard path != icon else { return }
        icon = path
        picture = nil
        strip = nil
        if Self.iconTints[path] == nil {
            var rect = NSRect(x: 0, y: 0, width: 32, height: 32)
            Self.iconTints[path] = NSWorkspace.shared.icon(forFile: path).cgImage(forProposedRect: &rect, context: nil, hints: nil)
                .flatMap(Self.mainColor(of:))
        }
        tint = Self.iconTints[path] ?? nil
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let picture, bounds.width > 0, bounds.height > 0 else { return }
        // A blur and a color need only a thumbnail of the picture, 32 KB at most.
        let pixels = switch Self.style {
        case .blur: CGSize(width: 256, height: 32)
        case .tint, .icontint: CGSize(width: 128, height: 16)
        case .soft: convertToBacking(pictureRect).size
        case .fade, .card: convertToBacking(bounds).size
        }
        guard pixels != requested else { return }
        requested = pixels
        GameBanners.shared.strip(of: picture, pixels: pixels, blurred: Self.style == .blur) { [weak self] strip in
            guard let self, self.picture == picture else { return }
            if Self.style == .tint {
                self.tint = strip.flatMap(Self.mainColor(of:))
            } else {
                self.strip = strip
            }
            self.needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Where the picture goes. The faint style shows it on the trailing 60%
    /// of the row only, so that is all it is made for: box art is 600 pixels
    /// wide, and a band of it covers that much at full sharpness.
    private var pictureRect: NSRect {
        guard Self.style == .soft else { return bounds }
        let width = (bounds.width * 0.6).rounded()
        return NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // How much shows, from the leading edge to the trailing one. Never
        // all of it: the buttons and the status sit on it.
        let showing: [(alpha: CGFloat, at: CGFloat)] = switch Self.style {
        case .soft: [(0, 0), (0.03, 0.15), (0.11, 0.32), (0.24, 0.55), (0.42, 1)]
        case .blur: [(0, 0), (0, 0.25), (0.28, 0.6), (0.5, 1)]
        case .tint, .icontint: [(0, 0), (0, 0.3), (0.1, 0.65), (0.24, 1)]
        case .fade: [(0, 0), (0, 0.3), (0.34, 0.6), (0.62, 1)]
        case .card: [(0.10, 0), (0.34, 0.5), (0.62, 1)]
        }
        func gradient(of color: NSColor) -> CGGradient? {
            CGGradient(colorsSpace: nil, colors: showing.map { color.withAlphaComponent($0.alpha * strength).cgColor } as CFArray,
                       locations: showing.map(\.at))
        }
        let area = pictureRect
        let start = CGPoint(x: area.minX, y: 0), end = CGPoint(x: area.maxX, y: 0)
        if let tint {
            if let wash = gradient(of: tint) { context.drawLinearGradient(wash, start: start, end: end, options: []) }
            return
        }
        guard let strip else { return }
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).addClip()
        if Self.style == .card {
            NSColor.quaternarySystemFill.setFill()
            bounds.fill()
        }
        // Fill the view, keeping the picture's shape. Drawn large, the
        // thumbnail of a blur comes out as soft color.
        let fill = max(area.width / CGFloat(strip.width), area.height / CGFloat(strip.height))
        let size = CGSize(width: CGFloat(strip.width) * fill, height: CGFloat(strip.height) * fill)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.clip(to: area)
        context.interpolationQuality = .high
        context.draw(strip, in: CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                       width: size.width, height: size.height))
        // Keep of the picture only what the gradient covers.
        context.setBlendMode(.destinationIn)
        if let mask = gradient(of: .black) { context.drawLinearGradient(mask, start: start, end: end, options: []) }
        context.endTransparencyLayer()
    }

    /// The color an image is mostly, going by its colorful pixels: an average
    /// of everything is mud. nil for an image with no color to speak of.
    private static func mainColor(of image: CGImage) -> NSColor? {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        // Twelve hues; the heaviest one wins, each pixel weighing as much as it is colorful.
        var bins = [(weight: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat)](repeating: (0, 0, 0, 0), count: 12)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = CGFloat(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            let color = NSColor(srgbRed: CGFloat(pixels[i]) / 255 / alpha, green: CGFloat(pixels[i + 1]) / 255 / alpha,
                                blue: CGFloat(pixels[i + 2]) / 255 / alpha, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            guard saturation > 0.25, brightness > 0.2 else { continue }
            let bin = min(11, Int(hue * 12)), weight = saturation * brightness
            bins[bin].weight += weight
            bins[bin].red += color.redComponent * weight
            bins[bin].green += color.greenComponent * weight
            bins[bin].blue += color.blueComponent * weight
        }
        guard let most = bins.max(by: { $0.weight < $1.weight }), most.weight > 4 else { return nil }
        return NSColor(srgbRed: most.red / most.weight, green: most.green / most.weight, blue: most.blue / most.weight, alpha: 1)
    }
}
