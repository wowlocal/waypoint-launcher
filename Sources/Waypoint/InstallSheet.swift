import AppKit
import WaypointCore

/// Where, which languages, which region; shows the real download size.
@MainActor
final class InstallSheet: NSViewController {
    private let product: InstallableProduct
    private let model: AppModel
    private var platform: InstallPlatform
    private let locations = InstallLocations()
    private var parentFolder: URL
    private var hasCustomParent = false
    private var sizeTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    /// What the download takes, once known.
    private var downloadSize: UInt64?
    /// The location's volume, once read: nil while it's being read, or
    /// (inside) when it can't be.
    private var volume: Result<InstallVolume?, Error>?

    private let location = NSTextField.label(.body, color: .secondaryLabelColor)
    /// The space free there, or why a game can't go there.
    private let volumeText = NSTextField(wrappingLabelWithString: "")
    private var volumeRow: NSGridRow?
    private let languagePicker: LanguagePicker
    private let regionPopup = NSPopUpButton()
    private let platformPopup = NSPopUpButton()
    private let sizeSpinner = NSProgressIndicator.spinner()
    private let sizeText = NSTextField.label(.body)
    private let installButton = NSButton(title: "Install", target: nil, action: nil)

    private var folderName: String { product.folderName + (platform == .windows ? " (Windows)" : "") }
    private var folder: URL { parentFolder.appendingPathComponent(folderName, isDirectory: true) }
    private var languages: GameLanguages? { languagePicker.languages }
    private var region: Region { Region.allCases[max(regionPopup.indexOfSelectedItem, 0)] }

    init(product: InstallableProduct, model: AppModel, platform: InstallPlatform? = nil) {
        self.product = product
        self.model = model
        self.platform = platform ?? model.defaultPlatform(for: product)
        parentFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        languagePicker = LanguagePicker(codes: product.languages, selected: GameLanguages(text: product.defaultLanguage()),
                                        hasSpokenLanguage: product.hasSpokenLanguage)
        super.init(nibName: nil, bundle: nil)
        parentFolder = offeredParent()
        languagePicker.onChange = { [weak self] in
            self?.refreshSize()
            self?.showVolume()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField.label(.title2)
        title.font = .boldSystemFont(ofSize: title.font?.pointSize ?? 17)
        title.stringValue = "Install \(product.displayName)"

        location.lineBreakMode = .byTruncatingMiddle
        let change = NSButton(title: "Change…", target: self, action: #selector(chooseParent))
        let locationRow = NSStackView(views: [location, change])
        volumeText.font = .preferredFont(forTextStyle: .subheadline)
        volumeText.textColor = .secondaryLabelColor
        volumeText.preferredMaxLayoutWidth = 360
        regionPopup.addItems(withTitles: Region.allCases.map(\.displayName))
        regionPopup.selectItem(at: Region.allCases.firstIndex(of: model.regionOverride ?? Region.preferred(games: model.games)) ?? 0)
        regionPopup.target = self
        regionPopup.action = #selector(refreshSize)
        sizeText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        platformPopup.addItems(withTitles: ["Windows (recommended)", "macOS"])
        platformPopup.selectItem(at: platform == .windows ? 0 : 1)
        platformPopup.target = self
        platformPopup.action = #selector(changePlatform)
        let platformRows: [[NSView]] = product.productCode == "hero" && WindowsHeroes.isAvailable
            ? [[Self.formLabel("Version:"), platformPopup]] : []
        let grid = NSGridView(views: platformRows + [[Self.formLabel("Location:"), locationRow], [NSGridCell.emptyContentView, volumeText]] + languagePicker.rows + [
            [Self.formLabel("Region:"), regionPopup],
            [Self.formLabel("Download:"), NSStackView(views: [sizeSpinner, sizeText])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        volumeRow = grid.cell(for: volumeText)?.row
        volumeRow?.topPadding = -4
        volumeRow?.isHidden = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        installButton.target = self
        installButton.action = #selector(install)
        installButton.keyEquivalent = "\r"
        installButton.isEnabled = false
        let buttons = NSStackView()
        buttons.setViews([cancel, installButton], in: .trailing)

        let stack = NSStackView.column([title, grid, buttons], spacing: 16)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 480),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = stack
        showLocation()
        refreshSize()
        readVolume(resolvingRemembered: true)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sizeTask?.cancel()
        volumeTask?.cancel()
    }

    /// Where another edition sharing the game's folder is (WoW's), so the
    /// two share their data; else the folder chosen last, or the built-in one.
    private func offeredParent() -> URL {
        model.sharedFolderParent(named: folderName, platform: platform) ?? locations.offered(for: platform)
    }

    private func showLocation() {
        location.stringValue = folder.path
        location.toolTip = folder.path
    }

    /// Reads the location's volume off the main thread. With
    /// `resolvingRemembered`, first checks the folder remembered from last
    /// time is still there, and goes back to the built-in one if not.
    private func readVolume(resolvingRemembered: Bool = false) {
        volumeTask?.cancel()
        volume = nil
        showVolume()
        let (locations, platform, parent, folderName) = (locations, platform, parentFolder, folderName)
        let resolves = resolvingRemembered && !hasCustomParent &&
            model.sharedFolderParent(named: folderName, platform: platform) == nil
        volumeTask = Task { [weak self] in
            let (resolved, volume) = await Task.detached(priority: .userInitiated) {
                let resolved = resolves ? locations.resolved(for: platform) : parent
                let folder = resolved.appendingPathComponent(folderName, isDirectory: true)
                return (resolved, Result { try InstallVolume.read(at: folder) })
            }.value
            guard !Task.isCancelled, let self else { return }
            if resolved != self.parentFolder {
                self.parentFolder = resolved
                self.showLocation()
                self.refreshSize()
            }
            self.volume = volume
            self.showVolume()
        }
    }

    /// The space free at the location, a caution about its format, or what
    /// keeps a game from going there; and whether Install can be clicked.
    private func showVolume() {
        var text: String?
        var problem = false
        switch volume {
        case nil:
            break
        case .failure(let error):
            text = errorMessage(error)
            problem = true
        case .success(let volume?):
            if let reason = volume.problem(download: downloadSize, platform: platform) {
                text = reason
                problem = true
            } else {
                text = [volume.summary, volume.caution].compactMap { $0 }.joined(separator: "\n")
            }
        case .success(nil):
            break
        }
        volumeText.stringValue = text ?? ""
        volumeRow?.isHidden = text?.isEmpty ?? true
        volumeText.textColor = problem ? .systemRed : .secondaryLabelColor
        installButton.isEnabled = languages != nil && volume != nil && !problem
    }

    /// The download size depends on languages and region; asks again when
    /// any changes, dropping an answer that's no longer wanted.
    @objc private func refreshSize() {
        sizeTask?.cancel()
        let (product, model, folder, region, platform) = (product, model, folder, region, platform)
        guard let languages else { return }
        show(size: nil)
        downloadSize = nil
        showVolume()
        sizeTask = Task { [weak self] in
            // A WoW plan is big: quick changes wait for the last one.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let size: Result<(download: UInt64, stored: UInt64), Error>
            do {
                size = .success(try await model.installSize(product, folder: folder, region: region, languages: languages, platform: platform))
            } catch {
                size = .failure(error)
            }
            guard !Task.isCancelled, let self else { return }
            self.show(size: size)
            self.downloadSize = try? size.get().download
            self.showVolume()
        }
    }

    private func show(size: Result<(download: UInt64, stored: UInt64), Error>?) {
        sizeSpinner.isHidden = size != nil
        if size == nil { sizeSpinner.startAnimation(nil) } else { sizeSpinner.stopAnimation(nil) }
        switch size {
        case nil:
            sizeText.stringValue = ""
        case .success(let bytes):
            let download = ByteCountFormatter.string(fromByteCount: Int64(bytes.download), countStyle: .file)
            sizeText.stringValue = bytes.stored == 0 ? download
                : "\(download) left (\(ByteCountFormatter.string(fromByteCount: Int64(bytes.stored), countStyle: .file)) already downloaded)"
            sizeText.textColor = .labelColor
            sizeText.toolTip = nil
        case .failure(let error):
            sizeText.stringValue = errorMessage(error)
            sizeText.textColor = .systemRed
            sizeText.toolTip = sizeText.stringValue
        }
    }

    @objc private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "\(product.displayName) will be installed in a \"\(folderName)\" folder here."
        panel.directoryURL = parentFolder
        if panel.runModal() == .OK, let url = panel.url {
            parentFolder = url
            hasCustomParent = true
            showLocation()
            refreshSize() // another folder may hold a partial install, or not
            readVolume()
        }
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func changePlatform() {
        platform = platformPopup.indexOfSelectedItem == 0 ? .windows : .macOS
        if model.heroesEdition(platform)?.isInstalled == true {
            model.selectHeroesEdition(platform)
            dismiss(nil)
            return
        }
        if !hasCustomParent { parentFolder = offeredParent() }
        showLocation()
        refreshSize()
        readVolume(resolvingRemembered: true)
    }

    @objc private func install() {
        let (product, model, folder, region, platform) = (product, model, folder, region, platform)
        guard let languages, installButton.isEnabled else { return }
        // Chosen with Change…: offered first from now on.
        let remembers = hasCustomParent
        Task { await model.install(product, folder: folder, region: region, languages: languages, platform: platform,
                                   remembersFolder: remembers) }
        dismiss(nil)
    }

    private static func formLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }
}
