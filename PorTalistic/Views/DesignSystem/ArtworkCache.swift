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

    /// One fetch per URL, however many cards are asking.
    ///
    /// Without this, scrolling a grid where several games share a placeholder URL — or
    /// simply reappearing a card mid-flight — starts the same download again.
    private let lock: NSLock = .init()
    private var inFlight: [URL: Task<NSImage?, Never>] = .init()

    private let session: URLSession = {
        let configuration: URLSessionConfiguration = .default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = .shared
        return .init(configuration: configuration)
    }()

    private init() {}

    /// What's already in memory, for the first frame of a card that has been seen before.
    func cachedImage(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
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
            let image = await Self.fetch(url, using: session)
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
            return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(downsampled(from:))
                ?? NSImage(contentsOf: url)
        }

        do {
            let (data, response) = try await session.data(from: url)

            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log.debug("Artwork at \(url.lastPathComponent, privacy: .public) answered \(http.statusCode).")
                return nil
            }

            return CGImageSourceCreateWithData(data as CFData, nil).flatMap(downsampled(from:))
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

    /// Roughly the decoded size, so `totalCostLimit` means something.
    private static func cost(of image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 1 }
        return representation.pixelsWide * representation.pixelsHigh * 4
    }
}
