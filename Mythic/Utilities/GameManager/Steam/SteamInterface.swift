//
//  SteamInterface.swift
//  Mythic
//
//  Created by Claude (Cowork) on 4/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import CoreGraphics
import OSLog

/**
 Controls Mythic's Steam integration.

 Unlike Epic Games (where Mythic reimplements the storefront protocol via `Legendary`),
 Steam support works by managing a single, dedicated Wine container that runs the real,
 official Windows Steam client. This means:

 - Login, 2FA, cloud saves, the overlay, achievements, and Steam's own update/download
   manager all work exactly as they do on Windows, because it *is* Steam, not a
   reimplementation of it.
 - Mythic's job is narrower and more reliable as a result: create a sane container,
   install the real client into it, and read Steam's own on-disk state
   (`libraryfolders.vdf` / `appmanifest_*.acf`) to know what's installed so those games
   can appear in Mythic's library and be launched with one click.
 - New game installs/updates happen inside the real Steam client (opened via
   ``openClient()``); Mythic does not attempt to reimplement Steam's download manager.
   This is a deliberate reliability trade-off: automating that step over a GUI installer
   is fragile, whereas reading Steam's own manifests after the fact is not.
 */
final class Steam {
    static let log: Logger = .custom(category: "SteamInterface")

    /// The fixed name given to Mythic's dedicated Steam container.
    /// Only one is ever created — Steam does not benefit from per-game containers
    /// the way arbitrary Windows games do, since it manages its own game folders.
    static let containerName = "Steam"

    // MARK: - Container

    /// The URL of Mythic's dedicated Steam container, if one has been created.
    static var containerURL: URL? {
        Wine.containerObjects.first(where: { $0.name == containerName })?.url
    }

    /// Default settings used when creating the Steam container.
    /// DXVK + msync + AVX2 mirror what Mythic already recommends for demanding
    /// Windows games; Windows 10 is used because Steam's installer and self-updater
    /// are more conservative about the Windows version they expect than most games are.
    static var recommendedContainerSettings: Wine.Container.Settings {
        .init(metalHUD: false,
              msync: true,
              retinaMode: true,

              // Off, because the engine below already provides Direct3D 11 and DXVK would
              // replace it with something worse. See `runtimeID`.
              dxvk: false,
              dxvkAsync: false,

              windowsVersion: .win10,

              // Mythic's usual scaling. Steam logs its login window at 805240832, 805240832,
              // which looks like a DPI overflow and was chased as one; it isn't. The value is
              // identical on every run this container has ever had, including the ones where
              // the window was plainly on screen, so it is an internal sentinel rather than a
              // coordinate. Changing the DPI moves nothing.
              scaling: 192,

              avx2: true,

              // The newest runtime Mythic manages, with DXMT supplying Direct3D 11.
              //
              // Neither engine works for the Steam client on its own, and it took both
              // failures to see why:
              //
              //   - The bundled engine is Game Porting Toolkit derived and has Apple's
              //     D3DMetal, so Direct3D 11 works and every Win32 window draws. It is also
              //     Wine 7.7, and Steam trips over its socket layer continuously
              //     (`getsockname failed in BGetBoundAddr with error: 10022`, IPv6 checks
              //     timing out, a connectivity test taking a minute). The login page never
              //     loads.
              //   - The managed builds have working sockets and only wined3d, which on macOS
              //     has OpenGL 2.1 underneath. Direct3D reports feature level 9_3 and an
              //     "NVIDIA GeForce 6800" that is not in any Mac; ANGLE caps GLES at 2.0,
              //     Steam concludes the GPU is unusable and paints nothing. That was the
              //     black login window, unchanged across client builds from 2024 to 2026,
              //     four launch flags and both runtimes, because none of them touched it.
              //
              // ``Wine/DXMT`` closes the gap by giving the newer Wine a real Direct3D 11 on
              // Metal. DXVK cannot: upstream DXVK 2.x requires the Vulkan `geometryShader`
              // feature, which Metal does not have, so it rejects MoltenVK outright.
              runtimeID: Runtime.newestManagedByMythic()?.id ?? Runtime.bundled.id)
    }

    /// Creates the Steam container if it doesn't already exist, or returns the existing one.
    @discardableResult
    static func ensureContainer() async throws -> Wine.Container {
        if let containerURL, var existing = try? Wine.getContainerObject(at: containerURL) {
            try await reconcileContainerForClient(&existing)
            return existing
        }

        return try await Wine.createContainer(name: containerName, settings: recommendedContainerSettings)
    }

    /// Brings an existing Steam container in line with what the client actually needs.
    ///
    /// This container is Mythic's, made for one application, so Mythic gets to correct it —
    /// and it needs correcting: containers created before this was understood have DXVK
    /// installed, which is what stops the client drawing. Turning the setting off isn't
    /// enough on its own, because installing DXVK overwrites the prefix's Direct3D DLLs and
    /// nothing put them back.
    ///
    /// Only the settings that belong to Mythic are touched. A runtime the user chose is
    /// theirs, and stays.
    private static func reconcileContainerForClient(_ container: inout Wine.Container) async throws {
        // Containers created before Mythic imported them have no root certificates, and the
        // symptom is Steam insisting it needs to be online while the network is fine.
        try? await Wine.Certificates.installIfMissing(inContainerAtURL: container.url)

        // Apply the container's display settings, rather than only writing them when the
        // container was created. A setting changed afterwards otherwise says one thing while
        // the prefix's registry keeps doing another — which for DPI is the difference between
        // a login window on screen and one at 805240832, 805240832.
        try? await Wine.setDisplayScaling(containerURL: container.url, dpi: container.settings.scaling)
        try? await Wine.toggleRetinaMode(containerURL: container.url, toggle: container.settings.retinaMode)

        // The client needs Direct3D 11, and on a managed runtime that means DXMT. Say so
        // rather than letting the window come up black with nothing to explain it.
        let clientRuntime = Wine.runtime(forContainerAtURL: container.url)
        if clientRuntime.isManagedByMythic {
            if Wine.DXMT.isInstalled(in: clientRuntime) {
                try? Wine.DXMT.prepareContainer(at: container.url, runtime: clientRuntime)
            } else {
                log.warning("""
                    Steam container runs on \(clientRuntime.description, privacy: .public), which has no DXMT. \
                    Direct3D 11 will fall back to wined3d at feature level 9_3 and the client's window will \
                    stay black. Install DXMT from Settings › Engine.
                    """)
            }
        }

        // A container that asked for DXVK but never received the DLLs. `createContainer` now
        // installs them, but containers made before it did are still out there, running on
        // builtin Direct3D while their settings claim otherwise.
        if container.settings.dxvk, !Wine.DXVK.isInstalled(inContainerAtURL: container.url) {
            log.notice("Steam container wants DXVK but has none of its DLLs; installing.")
            try? await Wine.DXVK.install(toContainerAtURL: container.url)
        }

    }

    // MARK: - Client detection & installation

    /// Where `steam.exe` lives inside the container, once installed.
    static func steamExecutableURL(containerURL: URL) -> URL {
        containerURL.appending(path: "drive_c/Program Files (x86)/Steam/steam.exe")
    }

    /// Whether the real Windows Steam client has been installed into the container.
    static var isClientInstalled: Bool {
        guard let containerURL else { return false }
        return FileManager.default.fileExists(atPath: steamExecutableURL(containerURL: containerURL).path)
    }

    static let installerDownloadURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    struct ClientInstallationFailedError: LocalizedError {
        var errorDescription: String? = String(localized: "Steam's installer didn't finish successfully. Try running Set Up Steam again.")
    }

    /// Downloads the official Steam installer and runs it, silently, inside Mythic's Steam container.
    /// - Parameter onProgress: Called with a 0...1 fraction while downloading. Installation itself
    ///   (after download) is fast but not progress-reporting, since it's a black-box NSIS installer.
    @discardableResult
    static func installClient(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Wine.Container {
        try await Preflight.requireEngineAndRosetta()
        let container = try await ensureContainer()

        let downloadedInstaller = try await downloadInstaller(onProgress: onProgress)
        defer { try? FileManager.default.removeItem(at: downloadedInstaller) }

        let process: Process = .init()
        // NSIS silent-install flag — installs to Steam's normal default location
        // (`C:\Program Files (x86)\Steam`) inside this container without showing UI.
        process.arguments = [downloadedInstaller.path, "/S"]
        Wine.transformProcess(process, containerURL: container.url)

        let result = try await process.runWrapped()
        log.notice("Steam installer finished for container \(container.url.prettyPath). stderr: \(result.standardError ?? "none")")

        // The installer's own bootstrapping can briefly relaunch/exit; give the
        // filesystem a moment before checking, then verify unconditionally.
        try await Task.sleep(for: .seconds(2))
        guard isClientInstalled else { throw ClientInstallationFailedError() }

        try await ensureClientRegistryConfiguration(containerURL: container.url)

        return container
    }

    /// Holds the progress observation by reference, so it stays alive for the whole
    /// download without the completion handler having to capture a mutable local.
    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
        func invalidate() { observation?.invalidate(); observation = nil }
    }

    private static func downloadInstaller(onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let progressObservation = ObservationBox()

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: installerDownloadURL) { location, response, error in
                progressObservation.invalidate()

                if let error { continuation.resume(throwing: error); return }
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    continuation.resume(throwing: URLError(.badServerResponse)); return
                }
                guard let location else { continuation.resume(throwing: CocoaError(.fileNoSuchFile)); return }

                // `location` is a temp file that URLSession will delete after this closure returns —
                // move it somewhere stable first.
                let destination = FileManager.default.temporaryDirectory.appending(path: "SteamSetup-\(UUID().uuidString).exe")
                do {
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            progressObservation.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
                if let newValue = change.newValue { onProgress(newValue) }
            }

            task.resume()
        }
    }

    /// Launch arguments Mythic always passes to the real Steam client.
    ///
    /// Steam's bootstrapper is *the* failure point when running the Windows client under
    /// Wine. Left to itself it tries to self-update on every launch, fails partway through,
    /// and dies with "Steam needs to be online to update. Please confirm your network
    /// connection and try again" — even when the network is perfectly fine. The client is
    /// already fully installed at that point; it just refuses to start.
    ///
    /// These flags stop it doing that, and are the long-standing workaround the Wine
    /// community (Lutris, Bottles, Proton) settled on for the same bug:
    ///
    /// - `-no-cef-sandbox`: Steam's Chromium UI can't run its sandbox under Wine.
    /// - `-noverifyfiles`: skip the file-verification pass that kicks off the update loop.
    /// - `-nobootstrapupdate`: don't try to replace the bootstrapper itself.
    /// - `-skipinitialbootstrap`: don't run the initial bootstrap at all.
    /// - `-norepairfiles`: don't "repair" (re-download) a install that isn't broken.
    ///
    /// - Note: These suppress Steam's *self*-update. Game downloads, updates, login, cloud
    ///   saves and the rest are untouched and still work normally.
    /// Whether the client is not merely installed but *complete* — the bootstrapper has
    /// unpacked the real client, not just laid down `steam.exe`.
    ///
    /// `steamui.dll` is the useful signal: it only exists once the downloaded packages have
    /// been extracted, and it's the file Steam names when it can't start.
    static var isClientFullyInstalled: Bool {
        guard let containerURL else { return false }
        let steamRoot = containerURL.appending(path: "drive_c/Program Files (x86)/Steam")
        return FileManager.default.fileExists(atPath: steamRoot.appending(path: "steamui.dll").path)
    }

    /// Launch arguments for the real Steam client.
    ///
    /// Whether it's right to suppress Steam's self-update depends entirely on whether the
    /// client is already complete, and getting this backwards fails either way:
    ///
    /// - On a **fresh** container, Steam's installer lays down only the bootstrapper.
    ///   `steamui.dll` and everything else arrive on first run. Suppressing the update there
    ///   suppresses the very download the client needs, and it dies with
    ///   "Failed to load steamui.dll".
    /// - On a **complete** install, the update check is the thing that breaks it: a
    ///   manifest fetch that times out leaves a perfectly working client refusing to start
    ///   with "Steam needs to be online to update", even though nothing needs updating.
    ///
    /// So: bootstrap freely when incomplete, and stop letting a failed update check block a
    /// client that's already good. Steam still updates itself whenever the check succeeds.
    static var clientLaunchArguments: [String] {
        [
            // Steam's Chromium UI can't run its sandbox under Wine; always needed.
            "-no-cef-sandbox",

            // Deliberately *not* `-cef-disable-gpu`.
            //
            // It was added because the client drew a black rectangle while CEF logged
            // ANGLE failing to initialise its Direct3D 11 backend. That reasoning had a
            // hole in it: on those runs Steam also had no working network, so the login
            // page had nothing to display either way, and the GPU errors were the more
            // visible of two causes rather than the operative one.
            //
            // With networking fixed, software rendering still paints nothing — so the
            // black window is not explained by the GPU path being unavailable, and
            // disabling it costs smoothness for no demonstrated benefit.
            //
            // The older CEF runtime.
            //
            // steamwebhelper crash-loops here, and its first complaint is its own:
            //
            //     check.cc(376)] Check failed: false. NOTREACHED log messages are omitted
            //     crashpad_client_win.cc(144)] crash server failed to launch, self-terminating
            //
            // In that order — the NOTREACHED fires first and crashpad then fails trying to
            // report it, so the crash handler is a symptom. Steam launches the webhelper with
            // `--enable-chrome-runtime`, CEF's newer browser runtime, and this turns that off
            // in favour of the older one that has far less of Chromium's browser layer behind
            // it.
            //
            // Both flag names here were read out of the shipped binaries rather than from a
            // forum post, which is worth doing: `-cef-force-32bit`, cited everywhere as *the*
            // macOS fix, is not in this build at all. It was tried, appeared to be ignored,
            // and it was — `strings steam.exe` has no such option.
            "-cef-disable-chrome-runtime",


            // No GPU swap chain for Chromium. This gets the window shown; it does not get it
            // painted.
            //
            // With DXMT in place ANGLE gets a real Direct3D 11 device — `ANGLE (Apple, Apple
            // M4 Max ... vs_5_0 ps_5_0)` — and then cannot get a surface out of it:
            //
            //     SwapChain11.cpp:636 (rx::SwapChain11::reset): Could not create additional
            //         swap chains or offscreen surfaces
            //     eglCreateWindowSurface failed with error EGL_BAD_ALLOC
            //
            // Without this flag the login window is created and stays hidden. With it, CEF
            // renders to software surfaces, which need no swap chain, and the window is shown
            // with its page loaded — the title changes to "Sign in to". It is still black,
            // because Steam's own compositor presents through Direct3D 11 and hits the same
            // wall ANGLE did.
            //
            // So this is kept for the progress it does make, and the remaining problem is not
            // in this list. See ``Wine/DXMT`` for what is actually missing.
            "-cef-disable-gpu",


            // A Wine virtual desktop (`explorer /desktop=Steam,WxH`) was tried too, on the
            // theory that Steam composing its window at 0x2FFF0000 — some eight hundred
            // million pixels out — was why nothing reached the screen. It made things
            // strictly worse: steamwebhelper reached its message loop and quit five seconds
            // later, with no login window created at all.

            // Not `-noreactlogin` either. It is a widely cited workaround for the black
            // login window on Wine, and here it stopped Steam starting at all. Every flag
            // tried in this file beyond `-no-cef-sandbox` has either done nothing or made
            // things worse; the remaining lead is container preparation — the registry
            // values and fonts CrossOver installs before Steam ever runs — not arguments.
        ]
    }

    /// Turns Steam's own bootstrapper self-update on or off via `steam.cfg`.
    ///
    /// Command-line flags don't reliably reach the bootstrapper — it relaunches itself with
    /// its own arguments, discarding ours. `steam.cfg`, which it reads from its install
    /// directory on every start, is the mechanism that actually holds.
    ///
    /// This matters because a *complete* client still refuses to start when its update
    /// check fails: it can't reach `client-update.steamstatic.com` from inside the
    /// container, times out after two minutes, and reports "Steam needs to be online to
    /// update" — with nothing actually needing updating.
    ///
    /// - Parameter inhibited: `true` to stop the bootstrapper self-updating.
    /// - Note: While inhibited the Steam *client* won't update itself. Game downloads,
    ///   updates and everything else are unaffected. ``updateClient()`` lifts it deliberately.
    static func setBootstrapperUpdateInhibited(_ inhibited: Bool, containerURL: URL) throws {
        let configURL = containerURL
            .appending(path: "drive_c/Program Files (x86)/Steam/steam.cfg")

        guard inhibited else {
            try? FileManager.default.removeItem(at: configURL)
            return
        }

        let contents = """
        BootStrapperInhibitAll=enable
        BootStrapperForceSelfUpdate=disable

        """
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        log.notice("Steam bootstrapper self-update inhibited via steam.cfg")
    }

    /// Lets the client update itself once, by lifting the inhibit and launching.
    /// Use this when the user explicitly asks for a Steam client update.
    static func updateClient() async throws -> Process {
        let container = try await ensureContainer()
        try setBootstrapperUpdateInhibited(false, containerURL: container.url)
        return try await openClient()
    }

    /// Where the Steam client's console output is captured.
    static func clientOutputLogURL(containerURL: URL) -> URL {
        containerURL.appending(path: "steam-client-output.log")
    }

    /// Windows-side path of the Steam install, in the lowercase forward-slash form Steam
    /// itself writes to the registry.
    private static let windowsSteamPath = "c:/program files (x86)/steam"

    /// Makes sure `HKCU\\Software\\Valve\\Steam` names where Steam lives.
    ///
    /// The NSIS installer only writes `InstallPath` under
    /// `HKLM\\Software\\Wow6432Node\\Valve\\Steam`. On real Windows the client fills in the
    /// per-user `SteamPath`/`SteamExe` values itself on first run; in a fresh Wine container
    /// it doesn't get that far — it downloads every package, fails to resolve where to
    /// unpack them ("Failed to determine download location for universe 1"), and shuts down
    /// leaving the install with no `steamui.dll`. Writing the values up front breaks that
    /// deadlock.
    ///
    /// Idempotent, and cheap enough to run before every launch.
    static func ensureClientRegistryConfiguration(containerURL: URL) async throws {
        let values: [(key: String, name: String, value: String)] = [
            ("HKCU\\Software\\Valve\\Steam", "SteamPath", windowsSteamPath),
            ("HKCU\\Software\\Valve\\Steam", "SteamExe", "\(windowsSteamPath)/steam.exe"),
            ("HKCU\\Software\\Valve\\Steam", "ModInstallPath", "\(windowsSteamPath)/steamapps/sourcemods"),
            ("HKCU\\Software\\Valve\\Steam", "SourceModInstallPath", "\(windowsSteamPath)/steamapps/sourcemods")
        ]

        for entry in values {
            let process: Process = .init()
            process.arguments = ["reg", "add", entry.key, "/v", entry.name, "/t", "REG_SZ", "/d", entry.value, "/f"]
            Wine.transformProcess(process, containerURL: containerURL)

            let result = try await process.runWrapped()
            log.debug("reg add \(entry.name, privacy: .public): \(result.standardError ?? "ok", privacy: .public)")
        }

        // Steam expects this to exist; it won't create it before resolving a download location.
        let steamApps = containerURL.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        try? FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
    }

    /// Opens the real Steam client's window (installing/launching the container's copy if needed).
    /// This is the entry point for a user to sign in, browse the store, and install/update games —
    /// Mythic deliberately doesn't try to automate that part.
    @discardableResult
    static func openClient() async throws -> Process {
        try await Preflight.requireEngineAndRosetta()
        let container = try await ensureContainer()
        guard isClientInstalled else { throw NotInstalledError() }

        // If the container's runtime was changed while an older wineserver still held the
        // prefix, every wine call below would fail with a protocol mismatch on stderr and
        // nothing would open. Clear that first, and only when it's actually the case —
        // shutting the prefix down unconditionally would kill a game the user is playing.
        if await !Wine.isPrefixServerCompatible(containerURL: container.url) {
            log.notice("Steam container's wineserver predates its selected runtime; shutting it down.")
            await Wine.shutdownPrefix(at: container.url)

            // Verify rather than hope. Launching into a prefix that still refuses every wine
            // call produces exactly the symptom this whole exercise is about: a button that
            // does nothing, with the reason on a stderr no one reads.
            guard await Wine.isPrefixServerCompatible(containerURL: container.url) else {
                throw Wine.PrefixRuntimeMismatchError(containerName: container.name)
            }
        }

        try await ensureClientRegistryConfiguration(containerURL: container.url)

        // Only once the client is complete. On an incomplete install the bootstrapper is
        // exactly what we need to run, so inhibiting it there would strand the container
        // without `steamui.dll`.
        try? setBootstrapperUpdateInhibited(isClientFullyInstalled, containerURL: container.url)

        let process: Process = .init()
        process.arguments = [steamExecutableURL(containerURL: container.url).path] + clientLaunchArguments
        process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
        Wine.transformProcess(process, containerURL: container.url)

        // Capture the client's console output to a file rather than discarding it.
        // When Steam fails before it can write its own logs — which is most of the
        // interesting cases — this is the only account of what happened.
        // Deliberately a file rather than a Pipe: a pipe nobody drains fills its buffer and
        // blocks the very process we're trying to observe.
        let outputURL = clientOutputLogURL(containerURL: container.url)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: outputURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        try process.run()
        return process
    }


    /// Where the bootstrapper writes its own account of a launch.
    static func bootstrapLogURL(containerURL: URL) -> URL {
        containerURL.appending(path: "drive_c/Program Files (x86)/Steam/logs/bootstrap_log.txt")
    }

    /// A fatal error from the client's captured output, if one is there.
    ///
    /// The hard part is not finding errors — a healthy Steam launch under Wine logs hundreds.
    /// It's refusing to report the ones that don't matter. Steam spawns throwaway probes
    /// (`gldriverquery.exe`, `vulkandriverquery.exe`) whose whole job is to fail on machines
    /// that lack a driver, so `err:module:import_dll ... gldriverquery.exe` is what a
    /// *working* launch looks like. Reporting it as the cause of death sends someone hunting
    /// a missing SDL2.dll while the actual crash sits a thousand lines further down.
    ///
    /// So: only things that genuinely end the client.
    static func lastClientError(containerURL: URL) -> String? {
        guard let contents = try? String(contentsOf: clientOutputLogURL(containerURL: containerURL), encoding: .utf8) else {
            return nil
        }

        let lines = contents.split(whereSeparator: \.isNewline)

        // Wine couldn't start the process at all. Nothing after this is meaningful.
        if let refusal = lines.first(where: { $0.contains("wine client error") }) {
            return String(refusal.trimmingCharacters(in: .whitespaces).prefix(displayedReasonLimit))
        }

        // Steam's own fatal assertions, in Valve's words. These are the ones that actually
        // take the client down, and they name the source file they came from.
        let steamAssertion = lines.last {
            $0.contains("Thread synchronization object is unuseable")
            || $0.contains("Fatal Error")
            || $0.contains("Assertion Failed")
        }
        if let steamAssertion {
            return String(steamAssertion.trimmingCharacters(in: .whitespaces).prefix(displayedReasonLimit))
        }

        // A module that failed to load in the *client* itself, as opposed to one of its
        // disposable probes.
        let fatalImport = lines.last {
            $0.contains("err:module:loader_init")
            && (($0.contains("steam.exe") && !$0.contains("bin\\")) || $0.contains("steamwebhelper.exe"))
        }

        guard let fatalImport else { return nil }
        return String(fatalImport.trimmingCharacters(in: .whitespaces).prefix(displayedReasonLimit))
    }

    /// The last error the Steam bootstrapper recorded, in its own words.
    ///
    /// When Steam fails to start it almost never says so on screen — it exits, and the only
    /// account of why is this log. Reading it back turns "clicking the button did nothing"
    /// into an actual diagnosis, which is the whole point of the exercise.
    ///
    /// - Returns: The message after the last `Error:` line, or `nil` if the log records none.
    static func lastBootstrapError(containerURL: URL) -> String? {
        guard let contents = try? String(contentsOf: bootstrapLogURL(containerURL: containerURL), encoding: .utf8) else {
            return nil
        }

        // Only this launch. The bootstrapper appends run after run to the same file, so
        // scanning the whole thing reports a failure from days ago as though it just
        // happened — which is worse than saying nothing, because it's confidently wrong.
        let lines = contents.split(whereSeparator: \.isNewline)
        let currentRun = lines.lastIndex { $0.contains("Startup - updater built") }
            .map { Array(lines[$0...]) } ?? Array(lines)

        for line in currentRun.reversed() {
            guard let marker = line.range(of: "] Error: ") else { continue }
            let message = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)
            return message.isEmpty ? nil : String(message.prefix(displayedReasonLimit))
        }

        return nil
    }

    /// How much of a log line is worth putting in front of someone.
    ///
    /// Any of these readers can, in principle, hand back something enormous, and the import
    /// sheet sizes itself to its content — so an unbounded string doesn't produce an ugly
    /// label, it produces a window thousands of points tall that looks like the app has hung.
    private static let displayedReasonLimit = 400
    /// Whether the real Steam client is up inside the container right now.
    ///
    /// `steam.exe` is a bootstrapper, not the client. It checks for updates, starts the
    /// actual client, and exits — and when an instance is already running it simply signals
    /// that one and exits within a second, logging a single line. So the process Mythic
    /// spawned exiting says nothing whatsoever about whether Steam is running.
    ///
    /// Treating those as the same thing is how Mythic came to report "Steam closed before it
    /// finished starting" about a client that had been up for ten hours, signed in and
    /// connected. Ask the container what's running instead of inferring it from a pid we
    /// happen to hold.
    static func isClientRunning() async -> Bool {
        guard let containerURL else { return false }
        guard let tasks = try? await Wine.tasklist(for: containerURL) else { return false }

        return tasks.contains { task in
            let name = task.imageName.lowercased()
            return name == "steamwebhelper.exe" || name == "steam.exe"
        }
    }

    /// Waits for the client to appear in the container after a launch.
    ///
    /// - Parameter timeout: How long to keep looking before giving up.
    /// - Returns: `true` once Steam is visibly running.
    static func waitForClientToAppear(timeout: Duration = .seconds(45)) async -> Bool {
        let deadline: ContinuousClock.Instant = .now.advanced(by: timeout)

        while .now < deadline {
            if await isClientRunning() { return true }
            try? await Task.sleep(for: .seconds(3))
        }

        return await isClientRunning()
    }

    /// Which pinned client build this container is on, if any.
    ///
    /// Plain `UserDefaults` rather than a property wrapper: this is read from wherever a
    /// launch happens to be running, not from a view.
    private static let pinnedClientDefaultsKey = "steamClientPinID"

    private static var pinnedClientID: String? {
        get { UserDefaults.standard.string(forKey: pinnedClientDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: pinnedClientDefaultsKey) }
    }

    /// The pin currently applied to the Steam container.
    ///
    /// Reconstructed from the stored name rather than looked up in a table: the list of
    /// builds comes from the Internet Archive at runtime, so there is no fixed catalogue to
    /// look anything up in.
    static var pinnedClient: SteamClientPin? {
        guard let id = pinnedClientID else { return nil }
        let name = UserDefaults.standard.string(forKey: pinnedClientNameDefaultsKey) ?? id
        return .init(id: id, name: name, archiveTimestamp: id, summary: "")
    }

    private static let pinnedClientNameDefaultsKey = "steamClientPinName"

    struct ClientPinFailedError: LocalizedError {
        let pin: SteamClientPin

        var errorDescription: String? {
            String(localized: "Couldn't install the \(pin.name) Steam client.")
        }

        var failureReason: String? {
            String(localized: "Steam's bootstrapper didn't fetch the archived packages. The Internet Archive may be unreachable, or may not have that snapshot.")
        }
    }

    /// Replaces the installed client with an archived build, and holds it there.
    ///
    /// Steam's bootstrapper takes its package source from `-overridepackageurl`, so pointing
    /// it at an Internet Archive snapshot of `media.steampowered.com/client` reinstalls the
    /// client as it stood on that date. The sequence matters:
    ///
    /// 1. Lift the `steam.cfg` inhibit — it exists to stop the client updating itself, and
    ///    a downgrade is an update. Leaving it on makes this silently do nothing.
    /// 2. Run the bootstrapper with `-forcesteamupdate -forcepackagedownload` so it
    ///    re-fetches everything rather than deciding it's already current, and `-exitsteam`
    ///    so it stops once the packages are in place instead of starting the client.
    /// 3. Put the inhibit back, or Steam updates itself to the broken build on next launch.
    ///
    /// - Parameter pin: The build to install.
    static func installPinnedClient(_ pin: SteamClientPin) async throws {
        try await Preflight.requireEngineAndRosetta()
        let container = try await ensureContainer()
        guard isClientInstalled else { throw NotInstalledError() }

        if await !Wine.isPrefixServerCompatible(containerURL: container.url) {
            await Wine.shutdownPrefix(at: container.url)
        }

        // Anything still running would fight the bootstrapper for the same files.
        try? await quitClient()

        try setBootstrapperUpdateInhibited(false, containerURL: container.url)

        let process: Process = .init()
        process.arguments = [
            steamExecutableURL(containerURL: container.url).path,
            "-forcesteamupdate",
            "-forcepackagedownload",
            "-overridepackageurl", pin.packageURL.absoluteString,
            "-exitsteam"
        ]
        process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
        Wine.transformProcess(process, containerURL: container.url)

        let outputURL = clientOutputLogURL(containerURL: container.url)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: outputURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        log.notice("Pinning the Steam client to \(pin.name, privacy: .public) from \(pin.packageURL.absoluteString, privacy: .public)")
        try process.run()

        // The bootstrapper downloads a few hundred megabytes over the Internet Archive,
        // which is not fast. Give it room, but don't hang forever if the archive is down.
        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(900))
        while process.isRunning, .now < deadline {
            try? await Task.sleep(for: .seconds(2))
        }

        if process.isRunning { process.terminate() }

        try setBootstrapperUpdateInhibited(true, containerURL: container.url)

        guard isClientFullyInstalled else { throw ClientPinFailedError(pin: pin) }

        pinnedClientID = pin.archiveTimestamp
        UserDefaults.standard.set(pin.name, forKey: pinnedClientNameDefaultsKey)
        log.notice("Steam client pinned to \(pin.name, privacy: .public)")
    }

    /// Forgets the pin and lets Steam update itself back to current.
    static func unpinClient() async throws {
        guard let containerURL else { return }
        try? await quitClient()
        try setBootstrapperUpdateInhibited(false, containerURL: containerURL)
        pinnedClientID = nil
        UserDefaults.standard.removeObject(forKey: pinnedClientNameDefaultsKey)
    }

    /// Shuts the Steam client down inside the container.
    ///
    /// Asks Steam to quit itself first — it owns its own bookkeeping and force-killing it
    /// mid-write is how download manifests get corrupted. Only if it's still there after a
    /// grace period does the prefix get shut down outright.
    ///
    /// This exists because Steam under Wine does not always take its own children with it:
    /// closing the window can leave `steamwebhelper.exe` behind, still holding the
    /// single-instance lock, so the next `steam.exe` hands off to a corpse and exits
    /// without drawing anything. From the outside, Steam simply stops opening.
    static func quitClient() async throws {
        guard let containerURL else { return }

        let process: Process = .init()
        process.arguments = [steamExecutableURL(containerURL: containerURL).path, "-shutdown"]
        process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: containerURL)
        Wine.transformProcess(process, containerURL: containerURL)
        _ = try? await process.runWrapped()

        let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(20))
        while .now < deadline, await isClientRunning() {
            try? await Task.sleep(for: .seconds(2))
        }

        // The container goes down either way, rather than only when Steam refuses to.
        //
        // Steam's processes are not the whole of what a run leaves behind. Its client and
        // webhelper talk over named shared memory, those sections live in the wineserver
        // rather than in either process, and a webhelper that died mid-startup leaves them
        // there. The next client finds them already present —
        //
        //     Created mapping SteamChrome_MasterStream_spid32_mem when set to fail if created
        //     steamuisharedjscontroller.cpp (529) : Failed creating offscreen shared JS context
        //
        // — and never gets a UI. Only `wineserver -k` clears them, so a restart that stops at
        // killing processes restarts into the same wreckage. This container runs nothing but
        // Steam, so there is nothing else to lose.
        await Wine.shutdownPrefix(at: containerURL)
    }

    struct NotInstalledError: LocalizedError {
        var errorDescription: String? = String(localized: "The Steam client hasn't been installed into Mythic's Steam container yet. Use Set Up Steam first.")
    }

    // MARK: - Signing in without the login window

    /// Steam's own macOS install, if the user has one.
    static var macClientDirectory: URL? {
        FileLocations.userApplicationSupport?.appending(path: "Steam")
    }

    /// Whether there's a signed-in macOS Steam to take a session from.
    static var canImportSignInFromMacClient: Bool {
        guard let macClientDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: macClientDirectory.appending(path: "config/loginusers.vdf").path
        )
    }

    struct NoMacClientError: LocalizedError {
        var errorDescription: String? = String(localized: "No signed-in Steam for macOS was found, so there's no session to import. Sign in to the normal Steam app first, or use text-mode sign-in.")
    }

    /// Copies the session out of the Mac's own Steam install and into the container.
    ///
    /// The client's login window is a *transparent* one — the webhelper log says
    /// "Browser requested transparent background, but it is not supported" every time it makes
    /// one — and Wine has no transparent windows, so it comes up black however well the rest
    /// of the stack is working. The main client window isn't transparent. So the way past this
    /// is to arrive already signed in, rather than to keep attacking the window.
    ///
    /// Steam keeps the session in `config/` and `userdata/`, in the same format on macOS and
    /// on Windows. Steam Guard may still challenge the container as a new device, in which
    /// case this doesn't help and ``openTextClient()`` is the fallback — but it costs one
    /// directory copy to find out.
    static func importSignInFromMacClient() async throws {
        guard let macClientDirectory, canImportSignInFromMacClient else { throw NoMacClientError() }

        let container = try await ensureContainer()
        let destination = container.url.appending(path: "drive_c/Program Files (x86)/Steam")

        // A running client would rewrite these on exit, undoing the import.
        try? await quitClient()

        for item in ["config", "userdata"] {
            let source = macClientDirectory.appending(path: item)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }

            let copy: Process = .init()
            copy.executableURL = .init(filePath: "/bin/cp")
            copy.arguments = ["-Rf", source.path, destination.path]
            _ = try await copy.runWrapped()
        }

        if let account = mostRecentAccount(inLoginUsersAt: macClientDirectory.appending(path: "config/loginusers.vdf")) {
            for (name, value) in [("AutoLoginUser", account), ("RememberPassword", "1")] {
                let process: Process = .init()
                process.arguments = ["reg", "add", #"HKCU\Software\Valve\Steam"#,
                                     "/v", name, "/t", "REG_SZ", "/d", value, "/f"]
                Wine.transformProcess(process, containerURL: container.url)
                _ = try? await process.runWrapped()
            }
            log.notice("Imported a Steam session and set it to sign in automatically.")
        } else {
            log.notice("Imported Steam session files; couldn't tell which account was most recent.")
        }
    }

    /// The account name Steam last signed in as, read out of `loginusers.vdf`.
    private static func mostRecentAccount(inLoginUsersAt url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // Blocks look like `"7656…" { "AccountName" "…" … "MostRecent" "1" }`. Preferring the
        // one marked most recent matters on a Mac with more than one account on it.
        let blocks = contents.components(separatedBy: "}")
        let preferred = blocks.first { $0.contains("\"MostRecent\"") && $0.contains("\"1\"") } ?? blocks.first

        guard let preferred,
              let match = try? Regex(#""AccountName"\s*"([^"]+)""#).firstMatch(in: preferred),
              let name = match.last?.substring else { return nil }
        return String(name)
    }

    /// Starts Steam's text-mode client, which has no browser UI at all.
    ///
    /// `steam.exe -textclient` is a console Steam: `login <name>` prompts for the password and
    /// the Steam Guard code in its own window, and the session it writes is the one the
    /// graphical client reads. Wine draws ordinary Win32 windows here perfectly well — the
    /// updater, the error dialogs and the recovery dialog all render correctly — so this is a
    /// way in that doesn't depend on the part that's broken.
    ///
    /// Mythic deliberately doesn't collect the credentials itself and pass them along.
    /// `steam.exe` accepts `-login <user> <password>`, and putting a password on a command
    /// line, where it sits in a process list, is not an improvement worth making.
    @discardableResult
    static func openTextClient() async throws -> Process {
        try await Preflight.requireEngineAndRosetta()
        let container = try await ensureContainer()
        guard isClientInstalled else { throw NotInstalledError() }

        // A running graphical client owns the session, and a second `steam.exe` hands over to
        // it and exits rather than starting a console. So the client goes down first.
        try? await quitClient()

        try await ensureClientRegistryConfiguration(containerURL: container.url)
        try? setBootstrapperUpdateInhibited(isClientFullyInstalled, containerURL: container.url)

        let process: Process = .init()
        process.arguments = [steamExecutableURL(containerURL: container.url).path, "-textclient"]
        process.environment = try Wine.assembleEnvironmentVariables(forContainerAtURL: container.url)
        Wine.transformProcess(process, containerURL: container.url)

        try process.run()
        return process
    }

    // MARK: - Library scanning

    struct InstalledApp: Equatable {
        let appID: String
        let name: String
        let installDirectory: URL
        /// Steam's own `StateFlags` bitmask; bit `4` (`0x4`) means "fully installed".
        let stateFlags: Int
        var isFullyInstalled: Bool { stateFlags & 0x4 != 0 }
    }

    struct LibraryScanError: LocalizedError {
        var errorDescription: String? = String(localized: "Couldn't read Steam's library data. Make sure Steam has been set up and you've signed in at least once.")
    }

    /// Reads `libraryfolders.vdf` to find every Steam library folder (the default one, plus any
    /// additional drives/folders the user added from within Steam), mapped to their location
    /// inside the container's `drive_c`.
    static func libraryFolders() throws -> [URL] {
        guard let containerURL else { throw LibraryScanError() }
        let steamRoot = containerURL.appending(path: "drive_c/Program Files (x86)/Steam")
        var folders: [URL] = [steamRoot] // the default library is Steam's own install folder

        let manifestURL = steamRoot.appending(path: "steamapps/libraryfolders.vdf")
        guard let contents = try? String(contentsOf: manifestURL, encoding: .utf8),
              let (_, root) = try? VDF.parse(contents),
              case .object(let libraries) = root else {
            return folders
        }

        for (_, entry) in libraries {
            guard let path = entry["path"]?.stringValue else { continue }
            folders.append(windowsPath(path, relativeToContainer: containerURL))
        }

        // de-duplicate while preserving order
        var seen: Set<URL> = []
        return folders.filter { seen.insert($0.standardizedFileURL).inserted }
    }

    /// Converts a Windows-style path as Steam wrote it (e.g. `C:\Program Files (x86)\Steam`)
    /// into the corresponding path under the container's `drive_c`.
    /// - Note: `VDF.parse` has already resolved `\\` escape sequences down to single
    ///   backslashes by this point, so this only has ordinary Windows separators to handle.
    private static func windowsPath(_ path: String, relativeToContainer containerURL: URL) -> URL {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.count >= 2, normalized[normalized.index(normalized.startIndex, offsetBy: 1)] == ":" {
            normalized = String(normalized.dropFirst(2)) // strip the drive letter, e.g. "C:"
        }

        // Append component-by-component rather than the raw (possibly leading-"/") string,
        // so this can't be misread as resetting to the filesystem root.
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        return components.reduce(containerURL.appending(path: "drive_c")) { url, component in
            url.appending(path: String(component))
        }
    }

    /// Scans every known library folder for `appmanifest_*.acf` files and parses them.
    static func installedApps() throws -> [InstalledApp] {
        var apps: [InstalledApp] = []

        for folder in try libraryFolders() {
            let steamappsURL = folder.appending(path: "steamapps")
            guard let entries = try? FileManager.default.contentsOfDirectory(at: steamappsURL,
                                                                              includingPropertiesForKeys: nil) else { continue }

            for entry in entries where entry.lastPathComponent.hasPrefix("appmanifest_") && entry.pathExtension == "acf" {
                guard let contents = try? String(contentsOf: entry, encoding: .utf8),
                      let (_, root) = try? VDF.parse(contents),
                      let appID = root["appid"]?.stringValue,
                      let name = root["name"]?.stringValue,
                      let installDir = root["installdir"]?.stringValue else { continue }

                let stateFlags = Int(root["StateFlags"]?.stringValue ?? "0") ?? 0
                let installationURL = steamappsURL.appending(path: "common").appending(path: installDir)

                apps.append(.init(appID: appID, name: name, installDirectory: installationURL, stateFlags: stateFlags))
            }
        }

        return apps
    }

    /// Scans Steam's own installed-app state and returns `SteamGame` instances ready to merge
    /// into `GameDataStore`'s library, matching the shape `GameDataStore.refreshFromStorefronts()`
    /// already expects from other storefronts.
    @MainActor
    static func importInstalledGames() async throws -> [SteamGame] {
        guard let containerURL else { throw NotInstalledError() }

        return try installedApps()
            .filter(\.isFullyInstalled)
            .map { app in
                SteamGame(appID: app.appID,
                          title: app.name,
                          installationState: .installed(location: app.installDirectory, platform: .windows),
                          containerURL: containerURL)
            }
    }

    // MARK: - Diagnostics

    /// Collects everything needed to work out why the Steam client isn't behaving, and
    /// writes it somewhere readable.
    ///
    /// Steam failures inside a Wine container are close to undebuggable from the UI alone —
    /// the client shows a one-line fatal error and exits, while the actual explanation sits
    /// in its own logs inside the container. This gathers those logs plus the state of the
    /// install (which DLLs actually landed, and how big they are) into one folder.
    ///
    /// - Returns: The directory the report was written to.
    @discardableResult
    static func exportDiagnostics() async throws -> URL {
        guard let containerURL else { throw NotInstalledError() }

        let steamRoot = containerURL.appending(path: "drive_c/Program Files (x86)/Steam")
        let fileManager: FileManager = .default

        // FIXME: temporary location. This should offer a save panel once the app has a
        // proper diagnostics/support flow.
        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let destination = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Games/Mythic-Diagnostics/steam-\(timestamp)")
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var summary: [String] = []
        func line(_ text: String = "") { summary.append(text) }

        func describe(_ url: URL) -> String {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                return "MISSING"
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes[.modificationDate] as? Date).map(ISO8601DateFormatter().string(from:)) ?? "?"
            return "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))  (modified \(modified))"
        }

        line("# Steam container diagnostics")
        line("generated: \(Date.now)")
        line("container: \(containerURL.path)")
        line("steam root: \(steamRoot.path)")
        line("engine installed: \(Engine.isInstalled)")
        line("engine version: \(await Engine.installedVersion?.description ?? "unknown")")
        line("bundled wine version: \(Wine.retrieveVersion()?.description ?? "unknown")")

        // The container's *own* runtime, which is what actually runs Steam. Reporting only
        // the bundled engine's version here sent two rounds of debugging at the wrong
        // problem, because the number shown had nothing to do with the binary in use.
        let containerRuntime = Wine.runtime(forContainerAtURL: containerURL)
        line("container runtime: \(containerRuntime.description)")
        line("container runtime path: \(containerRuntime.executableURL.path)")
        line("container runtime can reach prefix: \(await Wine.isPrefixServerCompatible(containerURL: containerURL))")
        line("rosetta present: \(Rosetta.exists)")

        // msync spends a file descriptor per Win32 sync object, so this number decides
        // whether a long Steam session survives. See `ResourceLimits`.
        if let limits = ResourceLimits.openFileLimitDescription {
            line("open file limit: \(limits)")
        }
        line()
        line("## available wine runtimes")
        let runtimes = Runtime.discoverAll()
        if runtimes.isEmpty {
            line("(none discovered)")
        } else {
            for runtime in runtimes {
                line("\(runtime.description)  [\(runtime.origin)]  \(runtime.executableURL.path)")
            }
        }
        line()
        line("client considered installed: \(isClientInstalled)")
        line("launch arguments: \(clientLaunchArguments.joined(separator: " "))")
        line()

        line("## key files")
        for relativePath in [
            "steam.exe",
            "steamui.dll",
            "steamclient.dll",
            "steamclient64.dll",
            "steamwebhelper.exe",
            "bin/cef/cef.win7/steamwebhelper.exe",
            "bin/cef/cef.win7x64/steamwebhelper.exe",
            "tier0_s.dll",
            "vstdlib_s.dll",
            "crashhandler.dll"
        ] {
            line("\(relativePath): \(describe(steamRoot.appending(path: relativePath)))")
        }
        line()

        func listing(of directory: URL, title: String, limit: Int = 250) {
            line("## \(title)")
            guard let contents = try? fileManager.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.fileSizeKey],
                                                                     options: [.skipsHiddenFiles]) else {
                line("(unreadable or absent: \(directory.path))")
                line()
                return
            }
            for entry in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(limit) {
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
                line("\(entry.lastPathComponent)  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
            }
            if contents.count > limit { line("... and \(contents.count - limit) more") }
            line()
        }

        listing(of: steamRoot, title: "steam root")
        listing(of: steamRoot.appending(path: "package"), title: "package")
        listing(of: steamRoot.appending(path: "bin"), title: "bin")
        listing(of: steamRoot.appending(path: "logs"), title: "logs")

        try summary.joined(separator: "\n").write(to: destination.appending(path: "summary.txt"),
                                                  atomically: true,
                                                  encoding: .utf8)

        // Copy Steam's own logs verbatim — the real explanation usually lives here.
        let logsDirectory = steamRoot.appending(path: "logs")
        if let logs = try? fileManager.contentsOfDirectory(at: logsDirectory,
                                                          includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) {
            let logsDestination = destination.appending(path: "logs")
            try? fileManager.createDirectory(at: logsDestination, withIntermediateDirectories: true)
            for log in logs {
                try? fileManager.copyItem(at: log, to: logsDestination.appending(path: log.lastPathComponent))
            }
        }

        // ...as does the bootstrapper's own log, which sits at the Steam root.
        for name in ["bootstrap_log.txt", "GameOverlayRenderer.log", "steamapps/libraryfolders.vdf", "bin/service_log.txt"] {
            let source = steamRoot.appending(path: name)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.copyItem(at: source,
                                          to: destination.appending(path: source.lastPathComponent))
            }
        }

        // The client's captured console output, if a launch has been attempted.
        let clientOutput = clientOutputLogURL(containerURL: containerURL)
        if fileManager.fileExists(atPath: clientOutput.path) {
            try? fileManager.copyItem(at: clientOutput,
                                      to: destination.appending(path: clientOutput.lastPathComponent))
        }

        // Wine's registry hives are plain text. Steam resolves its own install location
        // through `Software\\Valve\\Steam`, so when it reports that it can't determine a
        // download location these are the first thing to check.
        for hive in ["system.reg", "user.reg", "userdef.reg"] {
            let source = containerURL.appending(path: hive)
            guard let contents = try? String(contentsOf: source, encoding: .utf8) else { continue }

            // The hives are large and full of unrelated keys; keep the Valve/Steam blocks
            // and a little context around them.
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            var extracted: [String] = []
            for (index, line) in lines.enumerated() where line.range(of: "Valve", options: .caseInsensitive) != nil {
                let start = max(0, index - 1)
                let end = min(lines.count - 1, index + 12)
                extracted.append(contentsOf: lines[start...end].map(String.init))
                extracted.append("---")
            }

            let output = extracted.isEmpty ? "(no Valve/Steam keys found in \(hive))" : extracted.joined(separator: "\n")
            try? output.write(to: destination.appending(path: "\(hive).valve.txt"),
                              atomically: true,
                              encoding: .utf8)
        }

        log.notice("Steam diagnostics written to \(destination.path, privacy: .public)")
        return destination
    }

    // MARK: - Header art

    /// Steam's CDN serves consistent, predictable artwork URLs keyed only by AppID —
    /// no API key or authentication required for these.
    enum ArtworkKind {
        case library600x900 // vertical/portrait — matches Mythic's `verticalImageURL`
        case libraryHero     // wide banner — matches Mythic's `horizontalImageURL`

        fileprivate var filename: String {
            switch self {
            case .library600x900: "library_600x900.jpg"
            case .libraryHero:     "library_hero.jpg"
            }
        }
    }

    static func artworkURL(appID: String, kind: ArtworkKind) -> URL {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/\(kind.filename)")!
    }
}
