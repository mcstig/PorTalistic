//
//  GameSettingsView.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 2023
//  Rebuilt by Claude Opus 5 on 15/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import SwordRPC
import OSLog
import Darwin

/**
 Everything about one game that a person can change.

 The old version put a blurred sixteen-by-nine cover across the top three quarters of the
 sheet, a `Form` under it, and a bottom bar as a sibling of both — inside a fixed
 720 × 420 frame. The form needed a thousand points and got a hundred and fifty, so the
 bar sat on top of the rows and the container settings were simply unreachable: the last
 four toggles laid out below the bottom of the window. A settings sheet is a list of
 controls, so the cover is now a thumbnail and the list gets the room.

 It also says what the app decided about the game, in the same panel the game's page uses.
 This is where someone comes to change how a game runs, so it is the one place where "it
 chose DXMT, and here is why" has to be legible before they start overriding it.
 */
struct GameSettingsView: View {
    @Binding var game: Game
    @Binding var isPresented: Bool

    @Bindable private var operationManager: GameOperationManager = .shared

    @State private var profile: RuntimeProfile?

    @State private var movingError: Error?
    @State private var isMovingErrorAlertPresented: Bool = false
    @State private var isMovingFileImporterPresented: Bool = false

    @State private var typingArgument: String = .init()
    @State private var isThumbnailURLChangeSheetPresented: Bool = false
    @State private var isConfiguringContainer: Bool = false
    @State private var containerSettings: Wine.Container.Settings?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xlarge) {
                    if let profile {
                        RuntimeProfilePanel(profile: profile)
                    }

                    if isWindowsGame {
                        compatibility
                    }

                    options
                    file

                    if isWindowsGame {
                        container
                    }
                }
                .padding(Theme.Spacing.xlarge)
            }

            Divider()

            bottomBar
        }
        .task {
            loadContainerSettings()
            await refreshProfile()
        }
        .task(priority: .background) { setDiscordPresence() }
    }

    /// Whether this sheet should offer the Wine side of things at all.
    ///
    /// Everything except a native macOS build, rather than a strict `.installed(_, .windows)`
    /// match. That match hid both the container and the settings for a GOG game that was
    /// running under Wine as anyone could see — because its recorded state said otherwise —
    /// and a settings sheet that hides the settings is worse than one that shows a panel
    /// saying nothing has been assigned yet, which is what these panels already do.
    private var isWindowsGame: Bool {
        if case .installed(_, .macOS) = game.installationState { return false }
        return true
    }
}

// MARK: - Header and footer

private extension GameSettingsView {
    var header: some View {
        GameSheetHeader(game: game,
                        action: String(localized: "Settings"),
                        badges: badges,
                        coverWidth: 96) {
            EmptyView()
        }
        .padding(Theme.Spacing.xlarge)
    }

    var badges: [PortalBadge] {
        guard case .installed(_, let platform) = game.installationState else {
            return [.init(String(localized: "Not installed"))]
        }

        return [.init(platform.description)]
    }

    var bottomBar: some View {
        HStack(spacing: Theme.Spacing.small) {
            GameCard.SubscriptedInfoView(game: $game)

            Spacer()

            Button("Close") { isPresented = false }
                .buttonStyle(.portalProminent)
        }
        .padding(Theme.Spacing.large)
    }

    func setDiscordPresence() {
        discordRPC.setPresence({
            var presence: RichPresence = .init()
            presence.details = "Configuring \"\(game.title)\""
            presence.state = "Configuring \(game.title)"
            presence.timestamps.start = .now
            presence.assets.largeImage = "macos_512x512_2x"
            return presence
        }())
    }
}

// MARK: - Options

private extension GameSettingsView {
    var options: some View {
        DetailPanel(title: String(localized: "Options"), systemImage: "slider.horizontal.3") {
            VStack(spacing: 0) {
                DetailRow(String(localized: "Thumbnail"),
                          value: game.verticalImageURL?.host ?? String(localized: "None set")) {
                    Button("Change...") { isThumbnailURLChangeSheetPresented = true }
                        .buttonStyle(.portalQuietCompact)
                        .disabled(game.storefront != .local)
                        .help(game.storefront == .local
                              ? String(localized: "Point this game at a different cover.")
                              : String(localized: "Covers for storefront games come from the storefront."))
                }

                launchArguments

                DetailRow(String(localized: "File integrity"),
                          value: isVerifying ? String(localized: "Checking…") : nil) {
                    HStack(spacing: Theme.Spacing.small) {
                        if isVerifying {
                            ProgressView().controlSize(.small)
                        }

                        GameCard.Buttons.VerificationButton(game: $game, withLabel: true)
                            .buttonStyle(.portalQuietCompact)
                    }
                }
            }
        }
        .sheet(isPresented: $isThumbnailURLChangeSheetPresented) {
            ThumbnailURLChangeView(game: $game, isPresented: $isThumbnailURLChangeSheetPresented)
                .sheetSurface(minWidth: 720, minHeight: 380)
        }
    }

    var isVerifying: Bool {
        operationManager.queue.contains { $0.game == game && $0.type == .repair }
    }

    /// The arguments, and the field that adds one.
    ///
    /// Below the row rather than beside it: a list that grows sideways in a shared row was
    /// a horizontal `ScrollView` nobody could see the end of, next to a text field with no
    /// width left.
    var launchArguments: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            DetailRow(String(localized: "Launch arguments"), value: nil) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    TextField(String(localized: "Add an argument"), text: $typingArgument)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit(submitLaunchArgument)

                    Button("Add", systemImage: "return") { submitLaunchArgument() }
                        .buttonStyle(.portalQuietCompact)
                        .labelStyle(.iconOnly)
                        .disabled(typingArgument.isEmpty)
                }
            }

            if !game.launchArguments.isEmpty {
                // Wrapping rather than scrolling: arguments are short, there are rarely more
                // than a handful, and all of them being visible is the point.
                FlowLayout(spacing: Theme.Spacing.small) {
                    ForEach(game.launchArguments, id: \.self) { argument in
                        ArgumentItem(game: $game,
                                     launchArguments: $game.launchArguments,
                                     argument: argument)
                    }
                }
                .padding(.bottom, Theme.Spacing.small)
            }
        }
    }

    func submitLaunchArgument() {
        let cleanedArgument = typingArgument
            .trimmingCharacters(in: .illegalCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Split parsed tokens from `cleanedArgument`, the way a shell would.
        var expansion = wordexp_t() // swiftlint:disable:this identifier_name
        defer { wordfree(&expansion) }

        guard Darwin.wordexp(cleanedArgument, &expansion, 0) == 0 else { return }

        let splitArguments: [String] = (0..<Int(expansion.we_wordc))
            .compactMap { String(cString: expansion.we_wordv[$0]!) }

        guard !cleanedArgument.isEmpty, !game.launchArguments.contains(cleanedArgument) else { return }

        game.launchArguments += splitArguments
        typingArgument = .init()
    }
}

// MARK: - File

private extension GameSettingsView {
    var file: some View {
        DetailPanel(title: String(localized: "File"), systemImage: "internaldrive") {
            VStack(spacing: 0) {
                if case .installed(let location, _) = game.installationState {
                    DetailRow(String(localized: "Location"), value: location.prettyPath) {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([location])
                        }
                        .buttonStyle(.portalQuietCompact)
                    }
                }

                DetailRow(String(localized: "Move"),
                          value: String(localized: "Somewhere else on disk")) {
                    if isMoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Move...") { isMovingFileImporterPresented = true }
                            .buttonStyle(.portalQuietCompact)
                            .disabled(operationManager.queue.first?.game == game)
                    }
                }
            }
        }
        .fileImporter(isPresented: $isMovingFileImporterPresented,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let newLocation = urls.first else { return }

                Task { @MainActor in
                    do {
                        try await game.move(to: newLocation)
                    } catch {
                        movingError = error
                        isMovingErrorAlertPresented = true
                    }
                }

            case .failure(let failure):
                movingError = failure
                isMovingErrorAlertPresented = true
            }
        }
        .alert("Unable to move \"\(game.title)\".",
               isPresented: $isMovingErrorAlertPresented,
               presenting: movingError) { _ in
            // Dismissing the alert, not the sheet. The old version closed the whole sheet on
            // OK, so the only way to read the error was to not dismiss it.
            Button("OK") { movingError = nil }
        } message: { error in
            Text(error?.localizedDescription ?? String(localized: "Unknown error."))
        }
    }

    var isMoving: Bool {
        operationManager.queue.contains { $0.game == game && $0.type == .move }
    }
}

// MARK: - Container

private extension GameSettingsView {
    /// Which container the game runs in, and a way into that container's own settings.
    ///
    /// The settings themselves are deliberately *not* inlined here. `ContainerSettingsView`
    /// is a list of `Form` rows, and a `Form` on macOS is a scroll view — putting one inside
    /// this sheet's scroll view nests two, which is the same shape as the bug that laid the
    /// GOG import tab out sixteen hundred points above its sheet. It also wasn't true to
    /// what these settings are: they belong to a prefix shared by every game on the same
    /// Wine build, and presenting them under a game's name invited people to change one
    /// game and alter another.
    var container: some View {
        DetailPanel(title: String(localized: "Container"), systemImage: "cube.transparent") {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                // Deliberately not a picker. The provisioner assigns the container from the
                // game's profile at every launch, so a container chosen here would be
                // silently moved back the next time the game started — a control that lies.
                // Which Wine build a game runs on is the one thing this app is for deciding;
                // the settings that ride on top of it are above, and those are the user's.
                if let containerURL = game.containerURL,
                   let container = try? Wine.Container(knownURL: containerURL) {
                    DetailRow(String(localized: "Runs in"), value: container.name) {
                        Button("Configure...") { isConfiguringContainer = true }
                            .buttonStyle(.portalQuietCompact)
                    }

                    DetailRow(String(localized: "Wine build"),
                              value: Wine.runtime(forContainerAtURL: containerURL).name)
                } else {
                    Text("This game hasn't been assigned a container yet. It gets one the first time it runs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("""
                    A container is a whole Windows installation, shared by every game on the \
                    same Wine build, so changing its settings changes them for those games too. \
                    What this game needs on its own is decided per launch and put back \
                    afterwards — that is the panel at the top.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.small)
            }
        }
        .sheet(isPresented: $isConfiguringContainer) {
            if let containerURL = game.containerURL {
                ContainerConfigurationView(containerURL: .constant(containerURL),
                                           isPresented: $isConfiguringContainer)
                    .sheetSurface(minWidth: 700, minHeight: 620)
            }
        }
    }
}

// MARK: - Pieces

extension GameSettingsView {
    /// One launch argument, removed by clicking it.
    struct ArgumentItem: View {
        @Binding var game: Game
        @Binding var launchArguments: [String]
        var argument: String

        @State private var isHovering: Bool = false

        var body: some View {
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(argument)
                    .monospaced()

                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(isHovering ? .white : .secondary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xsmall)
            .background(isHovering ? Theme.Palette.destructive : Color.primary.opacity(0.08),
                        in: .capsule)
            .onHover { hovering in
                withAnimation(Theme.Motion.hover) { isHovering = hovering }
            }
            .onTapGesture {
                withAnimation(Theme.Motion.layout) {
                    launchArguments.removeAll { $0 == argument }

                    // `.onChange` does not fire when the array empties, so the game is told
                    // directly.
                    if launchArguments.isEmpty { game.launchArguments = .init() }
                }
            }
            .help(String(localized: "Click to remove"))
            .accessibilityLabel(String(localized: "Remove argument \(argument)"))
        }
    }

    /// Where a local game's cover comes from.
    struct ThumbnailURLChangeView: View {
        @Binding var game: Game
        @Binding var isPresented: Bool

        var body: some View {
            HStack(alignment: .top, spacing: Theme.Spacing.xlarge) {
                GameArtwork(game: game, url: game.verticalImageURL, cornerRadius: Theme.Radius.card)
                    .aspectRatio(Theme.Grid.artworkAspectRatio, contentMode: .fit)
                    .frame(width: 180)

                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    Form {
                        GameCard.ImageURLModifierView(game: $game, imageURL: $game._verticalImageURL)
                    }
                    .portalForm()

                    Spacer(minLength: 0)

                    HStack {
                        Spacer()

                        Button("Done") { isPresented = false }
                            .buttonStyle(.portalProminent)
                    }
                }
            }
            .padding(Theme.Spacing.xlarge)
        }
    }
}

// MARK: - Flow layout

/// Lays its subviews out in rows, wrapping when the next one won't fit.
///
/// `LazyVGrid` needs a column count decided up front and a horizontal `ScrollView` hides
/// whatever doesn't fit; a list of short chips wants neither.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows: [CGFloat] = [0]
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let current = rows[rows.count - 1]
            let needed = current == 0 ? size.width : current + spacing + size.width

            if needed > width, current > 0 {
                height += rowHeight + spacing
                rowHeight = size.height
                rows.append(size.width)
            } else {
                rows[rows.count - 1] = needed
                rowHeight = max(rowHeight, size.height)
            }
        }

        return .init(width: proposal.width ?? rows.max() ?? 0, height: height + rowHeight)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        var x = bounds.minX // swiftlint:disable:this identifier_name
        var y = bounds.minY // swiftlint:disable:this identifier_name
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }

            subview.place(at: .init(x: x, y: y), anchor: .topLeading, proposal: .init(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    GameSettingsView(game: .constant(placeholderGame(type: Game.self)), isPresented: .constant(true))
        .sheetSurface(minWidth: 720, idealWidth: 760, minHeight: 560, idealHeight: 680)
}

// MARK: - Compatibility

private extension GameSettingsView {
    /// The settings this game runs with, and who decides them.
    ///
    /// Automatic by default, and that is the product: nobody should have to know which Wine
    /// build or which translation layer a game wants. But automatic is not the same as
    /// unavailable — the first version of this panel explained the decision and gave no way
    /// to disagree with it, which is a worse position than the old settings sheet was in.
    ///
    /// Switching automatic off hands over exactly what automatic had arrived at, rather than
    /// a blank slate. An empty override is indistinguishable from "no opinion", so a game
    /// would silently fall back to the shared container's values the moment someone took
    /// control — losing the settings it was running with a second earlier.
    var compatibility: some View {
        DetailPanel(title: String(localized: "Settings for this game"),
                    systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 0) {
                Toggle(isOn: automaticSettings) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                        Text("Set these up automatically")

                        Text("""
                            Read from the game's own files, refined by settings already known to \
                            work for it, and applied for that launch only. Turn this off to set \
                            them yourself — you get whatever it had arrived at, to change as \
                            you like.
                            """)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .padding(.bottom, Theme.Spacing.medium)

                ForEach(Self.settingSwitches, id: \.label) { entry in
                    DetailRow(entry.label, value: nil) {
                        Toggle("", isOn: binding(for: entry))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(game.isSettingsAutomatic)
                    }
                    .help(entry.help)
                }

                DetailRow(String(localized: "Windows version"), value: nil) {
                    Picker("", selection: windowsVersion) {
                        ForEach(Wine.WindowsVersion.allCases, id: \.self) { version in
                            Text("Windows® \(version.rawValue)").tag(version)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(game.isSettingsAutomatic)
                }
                .help(String(localized: "What the game is told it is running on."))
            }
        }
    }

    /// One switch: where the game's answer lives, and where to read a starting value from.
    struct SettingSwitch {
        let label: String
        let help: String
        let override: WritableKeyPath<RuntimeProfile.SettingsOverride, Bool?>
        let container: KeyPath<Wine.Container.Settings, Bool>
    }

    static var settingSwitches: [SettingSwitch] {
        [
            .init(label: String(localized: "Retina mode"),
                  help: String(localized: """
                      Full display resolution inside Windows. Off is right more often than it \
                      sounds: a game that doesn't ask for it renders a corner of a 4K desktop.
                      """),
                  override: \.retinaMode, container: \.retinaMode),
            .init(label: String(localized: "DXVK"),
                  help: String(localized: """
                      Direct3D 10 and 11 through Vulkan. Never the answer for a Direct3D 9 \
                      game, and it cannot share a container with D3DMetal or DXMT.
                      """),
                  override: \.dxvk, container: \.dxvk),
            .init(label: String(localized: "DXVK async"),
                  help: String(localized: "Compiles shaders in the background. Means nothing without DXVK."),
                  override: \.dxvkAsync, container: \.dxvkAsync),
            .init(label: String(localized: "Command-stream thread"),
                  help: String(localized: """
                      Wine's own CSMT. Usually faster, and the first thing to turn off when a \
                      game on wined3d hangs or crashes.
                      """),
                  override: \.commandStreamThread, container: \.commandStreamThread),
            .init(label: String(localized: "Msync"),
                  help: String(localized: "Faster thread synchronisation. Harmless to turn off if a game misbehaves."),
                  override: \.msync, container: \.msync),
            .init(label: String(localized: "AVX2"),
                  help: String(localized: "Report AVX2 support to the game. A few refuse to start without it."),
                  override: \.avx2, container: \.avx2),
            .init(label: String(localized: "Metal HUD"),
                  help: String(localized: "Apple's frame-rate overlay, drawn on top of the game."),
                  override: \.metalHUD, container: \.metalHUD)
        ]
    }

    /// Automatic on and off, seeding the override on the way out of automatic.
    var automaticSettings: Binding<Bool> {
        .init {
            game.isSettingsAutomatic
        } set: { isAutomatic in
            if !isAutomatic {
                game.settingsOverride = shownSettings
            }

            game.isSettingsAutomatic = isAutomatic
            persistGame()
            Task { await refreshProfile() }
        }
    }

    func binding(for entry: SettingSwitch) -> Binding<Bool> {
        .init {
            shownSettings[keyPath: entry.override]
                ?? containerSettings?[keyPath: entry.container]
                ?? false
        } set: { newValue in
            game.settingsOverride[keyPath: entry.override] = newValue
            persistGame()
            Task { await refreshProfile() }
        }
    }

    var windowsVersion: Binding<Wine.WindowsVersion> {
        .init {
            shownSettings.windowsVersion ?? containerSettings?.windowsVersion ?? .win10
        } set: { newValue in
            game.settingsOverride.windowsVersion = newValue
            persistGame()
            Task { await refreshProfile() }
        }
    }

    /// What the switches show: the resolved profile's opinion, filled in from the container
    /// where it has none. The profile is resolved exactly as a launch resolves it, overrides
    /// included, so these are the values the game will actually run with.
    var shownSettings: RuntimeProfile.SettingsOverride {
        guard let settings = containerSettings else { return profile?.settings ?? .init() }

        let floor: RuntimeProfile.SettingsOverride = .init(dxvk: settings.dxvk,
                                                           dxvkAsync: settings.dxvkAsync,
                                                           retinaMode: settings.retinaMode,
                                                           commandStreamThread: settings.commandStreamThread,
                                                           msync: settings.msync,
                                                           metalHUD: settings.metalHUD,
                                                           avx2: settings.avx2,
                                                           windowsVersion: settings.windowsVersion)

        return floor.overlaid(with: profile?.settings ?? .init())
    }

    @MainActor func refreshProfile() async {
        profile = await Provisioner.shared.profile(for: game)
    }

    @MainActor func loadContainerSettings() {
        guard let containerURL = game.containerURL,
              let container = try? Wine.Container(knownURL: containerURL) else { return }

        containerSettings = container.settings
    }

    /// The library is a `Set` of reference types, so changing a game in place doesn't reach
    /// its `didSet`. Replacing the member does, and that is what writes it to disk.
    func persistGame() {
        Task { @MainActor in GameDataStore.shared.library.update(with: game) }
    }
}
