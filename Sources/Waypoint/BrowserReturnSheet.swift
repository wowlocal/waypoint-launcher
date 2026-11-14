import AppKit
import WaypointCore

/// Optional Safari handoff. No credentials are read from browser storage or clipboard.
@MainActor
final class BrowserReturnSheet: NSObject, NSWindowDelegate {
    private(set) var verifiedProfile: NativeAccountProfile?
    private var window: NSWindow?
    private weak var parent: NSWindow?
    private var continuation: CheckedContinuation<LoginToken?, Never>?
    private let field = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private var useButton = NSButton()
    private var openButton = NSButton()
    private var url: URL?
    private var task: Task<Void, Never>?

    func run(on parent: NSWindow, url: URL) async -> LoginToken? {
        self.parent = parent; self.url = url; verifiedProfile = nil
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let panel = NSPanel(contentRect: NSRect(x:0,y:0,width:520,height:430), styleMask:[.titled,.closable],backing:.buffered,defer:false)
            panel.title = "Sign in using Safari"; panel.isReleasedWhenClosed = false; panel.delegate = self
            self.window = panel
            let title = NSTextField(labelWithString:"Use your browser’s password manager")
            title.font = .systemFont(ofSize:17,weight:.semibold)
            let instructions = NSTextField(wrappingLabelWithString:"Sign in on Blizzard’s page in Safari. When Safari reaches its localhost error page, press ⌘L then ⌘C. Paste that return address below—it contains your game ticket, so keep it private.")
            instructions.textColor = .secondaryLabelColor
            openButton = NSButton(title:"Open Battle.net in Safari",target:self,action:#selector(openBrowser))
            field.placeholderString = "Paste the complete browser return address"
            field.setAccessibilityLabel("Private browser return address")
            useButton = NSButton(title:"Verify and sign in",target:self,action:#selector(useReturn)); useButton.keyEquivalent="\r"
            let cancel = NSButton(title:"Back",target:self,action:#selector(cancel));cancel.keyEquivalent="\u{1b}"
            spinner.style = .spinning;spinner.controlSize = .small;spinner.isDisplayedWhenStopped = false
            status.textColor = .secondaryLabelColor
            let progress = NSStackView(views:[spinner,status]);progress.spacing=10
            let buttons = NSStackView(views:[NSView(),cancel,useButton]);buttons.spacing=10
            let stack = NSStackView(views:[title,instructions,openButton,field,progress,NSView(),buttons])
            stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false
            panel.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor,constant:20),
                stack.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor,constant:-20),
                stack.topAnchor.constraint(equalTo:panel.contentView!.topAnchor,constant:20),
                stack.bottomAnchor.constraint(equalTo:panel.contentView!.bottomAnchor,constant:-20),
                instructions.widthAnchor.constraint(equalTo:stack.widthAnchor),field.widthAnchor.constraint(equalTo:stack.widthAnchor),
                progress.widthAnchor.constraint(equalTo:stack.widthAnchor),buttons.widthAnchor.constraint(equalTo:stack.widthAnchor),
            ])
            parent.beginSheet(panel)
        }
    }
    @objc private func openBrowser() {
        guard let url, let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Safari") else {
            status.stringValue="Safari couldn’t be opened.";return
        }
        NSWorkspace.shared.open([url],withApplicationAt:safari,configuration:NSWorkspace.OpenConfiguration())
    }
    @objc private func useReturn() {
        guard task == nil else { return }
        let text = field.stringValue; field.stringValue = ""
        guard let token = BrowserLoginReturn.parse(text) else {
            status.stringValue="Paste the full localhost return address from Safari’s address bar.";return
        }
        // A separate native authentication session must not disrupt an open client.
        guard !RunningProcesses.executables().contains(where: { URL(fileURLWithPath:$0.path).lastPathComponent.hasPrefix("World of Warcraft") }) else {
            status.stringValue="Close World of Warcraft before verifying this sign-in.";return
        }
        useButton.isEnabled=false;openButton.isEnabled=false;spinner.startAnimation(nil)
        status.stringValue="Verifying your game login with Blizzard…"
        task=Task { [weak self] in
            guard let self else { return }
            defer { self.task=nil;self.useButton.isEnabled=true;self.openButton.isEnabled=true;self.spinner.stopAnimation(nil) }
            let configuration=URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity=false;configuration.timeoutIntervalForRequest=10;configuration.timeoutIntervalForResource=20
            let session=URLSession(configuration:configuration)
            defer { session.invalidateAndCancel() }
            do {
                // Cold-start verification: no installed game or Battle.net metadata required.
                let version=try await VersionService(session:session).latest(product:"wowf",region:.us)
                guard version.buildID>0, version.region=="us" else { throw WoWAccountDiscovery.Failure.unavailable }
                guard !Task.isCancelled, self.continuation != nil else { return }
                guard !RunningProcesses.executables().contains(where: { URL(fileURLWithPath:$0.path).lastPathComponent.hasPrefix("World of Warcraft") }) else {
                    self.status.stringValue="Close World of Warcraft before verifying this sign-in.";return
                }
                let profile = try await WoWAccountDiscovery().profile(token: token, build: UInt64(version.buildID), region: .us)
                guard !Task.isCancelled, self.continuation != nil else { return }
                self.verifiedProfile = profile
                self.finish(token)
            } catch {
                guard !Task.isCancelled, self.continuation != nil else { return }
                self.status.stringValue="Blizzard couldn’t verify this return. Sign in again in Safari and retry. No saved login was replaced."
            }
        }
    }
    @objc func cancel() { finish(nil) }
    private func finish(_ token: LoginToken?) {
        guard let continuation else { return };self.continuation=nil
        if token == nil { verifiedProfile = nil }
        task?.cancel();field.stringValue=""
        if let window { window.delegate=nil;parent?.endSheet(window);window.orderOut(nil) }
        window=nil;url=nil
        continuation.resume(returning:token)
    }
    func windowShouldClose(_ sender:NSWindow)->Bool { cancel();return false }
}
