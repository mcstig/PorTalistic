//
//  ArtworkCache.swift
//  PorTalistic
//
//  Created by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2026 Michael Stoian

import Foundation
import AppKit
import ImageIO
import CryptoKit
import OSLog

/**
 Decoded cover art, kept in memory for as long as the app is running.

 `AsyncImage` loads once per view identity and keeps nothing: a `LazyVGrid` recycles its
 cards as you scroll, and switching from Home to the library and back builds every card
 again, so a 136-game library re-fetched and re-decoded its covers on every navigation. The
 visible result was a wall of artwork dissolving back in each time — which reads as an app
 that can't hold onto anything.

 `URLCache` alone doesn't fix it: the bytes come back from disk quickly, but every card
 still pays to decode a 600×800 JPEG on the way to the screen. So this keeps the decoded
 `NSImage`, and it keeps one fetch per URL rather than one per card that happens to want it.
 */
final class ArtworkCache: @unchecked Sendable {
    static let shared: ArtworkCache = .init()

    private static let log: Logger = .custom(category: "ArtworkCache")

    /// `NSCache` is documented thread-safe and evicts under memory pressure by itself, which
    /// is the behaviour wanted here: cover art is worth keeping until something needs the
    /// memory more.
    private let images: NSCache<NSURL, NSImage> = {
        let cache: NSCache<NSURL, NSImage> = .init()
        cache.countLimit = 400
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    /// Grey copies, for games that aren't installed — see ``mutedImage(for:)``.
    ///
    /// Apart from the colour ones, and a quarter of their size: one byte a pixel, since grey
    /// needs no more. A library that is mostly not installed would otherwise hold every cover
    /// twice.
    private let mutedImages: NSCache<NSURL, NSImage> = {
        let cache: NSCache<NSURL, NSImage> = .init()
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// One fetch per URL, however many cards are asking.
    ///
    /// Without this, scrolling a grid where several games share a placeholder URL — or
    /// simply reappearing a card mid-flight — starts the same download again.
    private let lock: NSLock = .init()
    private var inFlight: [URL: Task<NSImage?, Never>] = .init()

    /// No `URLCache`. The downsampled copies below are the persistent cache now, and
    /// `URLCache.shared` would keep a second, larger copy of the same covers on disk — an
    /// OS-shared cache with a modest cap, so unrelated traffic evicts them and they get
    /// refetched, which is the behaviour this replaces.
    private let session: URLSession = {
        let configuration: URLSessionConfiguration = .default
        configuration.urlCache = nil
        return .init(configuration: configuration)
    }()

    // MARK: - On disk

    /// Where downsampled covers live between launches.
    ///
    /// A library's covers change about never, and the bytes were already being kept by
    /// `URLCache.shared` — but the *decode* wasn't, so every launch re-decoded a hundred and
    /// thirty full-size JPEGs, and an OS-shared cache with a small cap meant a good number of
    /// them were refetched as well. What is stored here is the picture at the size a card
    /// actually draws it, which is a fraction of the pixels and nothing else's to evict.
    private let directory: URL? = {
        guard let home = Bundle.appHome else { return nil }

        let directory = home.appending(path: "Artwork")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Named by a digest of the URL, so a game whose cover URL changes gets a new file rather
    /// than the old picture, and nothing has to sanitise a remote path into a filename.
    private func fileURL(for url: URL) -> URL? {
        guard let directory else { return nil }

        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return directory.appending(path: "\(digest.map { String(format: "%02x", $0) }.joined()).jpg")
    }

    private func storedImage(for url: URL) -> NSImage? {
        guard !url.isFileURL, let file = fileURL(for: url),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }

        return Self.downsampled(from: source)
    }

    /// Writes the downsampled cover beside the others. Best-effort: a cover that can't be
    /// written is still on screen, it just costs a fetch next launch.
    private func store(_ image: NSImage, for url: URL) {
        guard !url.isFileURL, let file = fileURL(for: url) else { return }

        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return }

        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)

        if !CGImageDestinationFinalize(destination) {
            Self.log.debug("Couldn't write \(file.lastPathComponent, privacy: .public) to the artwork folder.")
        }
    }

    /// Keeps the folder from growing without limit, oldest first.
    ///
    /// Bounded by size rather than by age: a cover for a game still in the library should not
    /// expire, and one for a game that left should not be kept forever. Size is the measure
    /// that doesn't need to know which is which.
    private static let diskLimit: Int = 256 * 1024 * 1024

    private func prune() {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return }

        let described = files.compactMap { file -> (url: URL, size: Int, modified: Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize else { return nil }

            return (file, size, values.contentModificationDate ?? .distantPast)
        }

        var total = described.reduce(0) { $0 + $1.size }
        guard total > Self.diskLimit else { return }

        for file in described.sorted(by: { $0.modified < $1.modified }) {
            guard total > Self.diskLimit else { break }

            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }

        Self.log.notice("Trimmed the artwork folder to \(total / (1024 * 1024), privacy: .public)MB")
    }

    private init() {
        // Off the launch path: nothing waits on this, and it touches the filesystem.
        Task.detached(priority: .utility) { [self] in prune() }
    }

    /// What's already in memory, for the first frame of a card that has been seen before.
    func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    /// A grey copy already made, for the first frame of a card that has been seen before.
    func cachedMutedImage(for url: URL) -> NSImage? {
        mutedImages.object(forKey: url as NSURL)
    }

    /// The cover in greys and a little darker, for a game that isn't installed.
    ///
    /// Made once per cover, off the main thread, and drawn as an ordinary picture. The obvious
    /// alternative — `.saturation(0)` on the card — is a filter applied again to every
    /// uninstalled cover on every frame of a scroll, and that is most of a library.
    func mutedImage(for url: URL) async -> NSImage? {
        if let cached = cachedMutedImage(for: url) { return cached }
        return await mutedTask(for: url).value
    }

    /// One conversion per URL: a list row asks twice for the same cover — its thumbnail and
    /// the wash behind it — and a card with a glow does too.
    private var mutedInFlight: [URL: Task<NSImage?, Never>] = .init()

    /// Synchronous for the same reason as ``task(for:)``.
    private func mutedTask(for url: URL) -> Task<NSImage?, Never> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = mutedInFlight[url] { return existing }

        let task = Task<NSImage?, Never> { [self] in
            let muted = await image(for: url).flatMap(Self.muted)
            finishMuted(url, with: muted)
            return muted
        }

        mutedInFlight[url] = task
        return task
    }

    private func finishMuted(_ url: URL, with image: NSImage?) {
        if let image {
            mutedImages.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image) / 4)
        }

        lock.lock()
        mutedInFlight[url] = nil
        lock.unlock()
    }

    /// The image, from memory, from the URL cache, or from the network — in that order.
    func image(for url: URL) async -> NSImage? {
        if let cached = cachedImage(for: url) { return cached }
        return await task(for: url).value
    }

    /// The in-flight fetch for this URL, starting one if there isn't one.
    ///
    /// Deliberately synchronous: `NSLock.lock()` is unavailable from an async context — it
    /// blocks a cooperative thread — so the locked section lives in a plain function that
    /// async code calls, rather than inline in ``image(for:)``.
    private func task(for url: URL) -> Task<NSImage?, Never> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = inFlight[url] { return existing }

        let task = Task<NSImage?, Never> { [self] in
            // The folder, then the network. A hit here costs one small decode and no
            // request at all, which is what makes a second launch of the library instant
            // rather than a wall of covers dissolving in.
            var image = storedImage(for: url)

            if image == nil {
                image = await Self.fetch(url, using: session)
                if let image { store(image, for: url) }
            }

            finish(url, with: image)
            return image
        }

        inFlight[url] = task
        return task
    }

    /// Records the result and forgets the fetch. Synchronous, for the same reason.
    private func finish(_ url: URL, with image: NSImage?) {
        if let image {
            images.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        }

        lock.lock()
        inFlight[url] = nil
        lock.unlock()
    }

    private static func fetch(_ url: URL, using session: URLSession) async -> NSImage? {
        // A custom thumbnail the user browsed for is a file on disk, and round-tripping one
        // through `URLSession` to read it is both slower and easier to get wrong.
        if url.isFileURL {
            return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { downsampled(from: $0) }
                ?? NSImage(contentsOf: url)
        }

        do {
            let (data, response) = try await session.data(from: url)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.debug("Artwork at \(url.lastPathComponent, privacy: .public) answered \(http.statusCode).")
                return nil
            }

            return CGImageSourceCreateWithData(data as CFData, nil).flatMap { downsampled(from: $0) }
                ?? NSImage(data: data)
        } catch {
            log.debug("Unable to load artwork: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The longest edge kept, in pixels.
    ///
    /// Covers arrive around 600×800 and are drawn into a tile 200 points wide — 400 pixels
    /// on this display, and 260 at the small card size. Keeping the full-size decode means
    /// Core Animation rescales every visible cover on every frame of a scroll, and holds four
    /// times the memory to do it. 512 is above what any card asks for.
    private static let maximumPixelSize: Int = 512

    /// Decoded once, at the size it will be drawn.
    ///
    /// `kCGImageSourceShouldCacheImmediately` is the point as much as the size is: without
    /// it the decode is deferred to the first draw, which happens on the main thread during
    /// the scroll that wanted the image. Here it happens in the fetch task instead.
    private static func downsampled(from source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(cgImage: image, size: .init(width: image.width, height: image.height))
    }

    /// Greys at one byte a pixel, darkened a little so an uninstalled game steps back rather
    /// than only losing its colour.
    private static func muted(_ image: NSImage) -> NSImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        guard let context = CGContext(data: nil,
                                      width: source.width,
                                      height: source.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }

        // A dark ground first, for the rare cover with transparency — a custom PNG — which a
        // context without alpha would otherwise turn black wherever it had nothing.
        context.setFillColor(gray: 0.12, alpha: 1)
        context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(source, in: bounds)

        context.setFillColor(gray: 0, alpha: 0.25)
        context.fill(bounds)

        guard let muted = context.makeImage() else { return nil }
        return NSImage(cgImage: muted, size: image.size)
    }

    /// Roughly the decoded size, so `totalCostLimit` means something.
    private static func cost(of image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 1 }
        return representation.pixelsWide * representation.pixelsHigh * 4
    }
}
