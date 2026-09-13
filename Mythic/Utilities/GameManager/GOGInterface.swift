//
//  GOGInterface.swift
//  Mythic
//
//  Created by Claude (Cowork) on 13/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation
import OSLog

/// GOG.com, spoken to directly.
///
/// Epic goes through `legendary` and Steam went through Steam's own client; GOG needs
/// neither. Its games are DRM-free, so there is nothing to keep running and nothing to
/// authorise a launch — once the files are on disk, a GOG game is a folder with an
/// executable in it. What's left is an account: what you own, what it's called, and what it
/// looks like, all of which GOG answers over plain HTTPS with a bearer token.
///
/// - Note: Downloading is deliberately not here yet. GOG's content system serves games as
///   chunked, hashed depots described by build manifests, which is a real piece of work and
///   the reason `gogdl` exists. The library comes first because a library you can see is
///   worth something on its own, and because installing is the part that can be bolted on
///   without moving anything that's already here.
final class GOG {
    static let log: Logger = .custom(category: "GOGInterface")

    /// Where the account lives. Sits beside legendary's `Epic` folder for the same reason.
    static let configurationFolder: URL = Bundle.appHome!.appending(path: "GOG")

    // MARK: - Credentials

    /// GOG Galaxy's own OAuth client.
    ///
    /// Not a secret in any meaningful sense — it ships inside Galaxy, and every third-party
    /// GOG client uses it because GOG issues no others. There is no developer programme to
    /// register with, so this is the only door.
    private enum Client {
        static let id = "46899977096215655"
        static let secret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
        static let redirectURI = "https://embed.gog.com/on_login_success?origin=client"
    }

    /// Where a browser has to end up for us to have an authorisation code.
    static var authorizationURL: URL {
        var components: URLComponents = .init(string: "https://auth.gog.com/auth")!
        components.queryItems = [
            .init(name: "client_id", value: Client.id),
            .init(name: "redirect_uri", value: Client.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "layout", value: "client2")
        ]
        return components.url!
    }

    /// The authorisation code GOG puts in the URL when a sign-in succeeds, if this is that URL.
    ///
    /// GOG signals success by redirecting rather than by rendering anything, so the code is
    /// only ever visible in the address bar of a page that is still loading.
    static func authorizationCode(from url: URL) -> String? {
        guard let components: URLComponents = .init(url: url, resolvingAgainstBaseURL: false),
              components.host == "embed.gog.com",
              components.path.hasPrefix("/on_login_success") else { return nil }

        return components.queryItems?.first { $0.name == "code" }?.value
    }

    // MARK: - Session

    /// One stored credential, in the shape gogdl writes.
    ///
    /// Deliberately gogdl's format rather than a format of Mythic's own. Both sides refresh
    /// tokens — GOG's last an hour — and two stores that each believe they own the account
    /// drift apart within a day: a downloader that's authenticated and a library that isn't,
    /// or the reverse, with no way to tell which is right. So there is one file, either side
    /// may rewrite it, and whoever notices the expiry first does the refresh.
    struct StoredCredentials: Codable {
        let accessToken: String
        let refreshToken: String
        let userID: String
        let expiresIn: Int
        let sessionID: String?
        /// Unix seconds. gogdl's own name for it, and the reason expiry is computed rather
        /// than stored — the two processes don't share a clock reading, only this.
        let loginTime: Double

        var expiry: Date { .init(timeIntervalSince1970: loginTime + Double(expiresIn)) }

        /// A minute short of the deadline, so a request that takes a moment to send doesn't
        /// arrive with a token that expired in flight.
        var isExpired: Bool { Date() >= expiry.addingTimeInterval(-60) }

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case userID = "user_id"
            case expiresIn = "expires_in"
            case sessionID = "session_id"
            case loginTime
        }

        init(from response: TokenResponse) {
            self.accessToken = response.accessToken
            self.refreshToken = response.refreshToken
            self.userID = response.userID
            self.expiresIn = response.expiresIn
            self.sessionID = response.sessionID
            self.loginTime = Date().timeIntervalSince1970
        }
    }

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let userID: String
        let expiresIn: Int
        let sessionID: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case userID = "user_id"
            case expiresIn = "expires_in"
            case sessionID = "session_id"
        }
    }

    /// The file both Mythic and gogdl read and write. gogdl is pointed at it by
    /// `--auth-config-path`.
    static var authConfigURL: URL { configurationFolder.appending(path: "auth.json") }

    /// The file's contents as written, untyped.
    ///
    /// Kept untyped on purpose: gogdl adds its own entries here — a game-scoped token for
    /// every game whose secure download links it fetches — and those don't have the shape of
    /// a sign-in. Decoding the file as a whole would fail on the first one and read as "not
    /// signed in"; rewriting it from a decoded copy would delete them.
    private static func readRawCredentialStore() -> [String: Any] {
        guard let data = try? Data(contentsOf: authConfigURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .init() }

        return root
    }

    /// gogdl keys credentials by client id: the Galaxy client's entry is the sign-in.
    private static func readCredentials(forClientID id: String) -> StoredCredentials? {
        guard let entry = readRawCredentialStore()[id],
              let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }

        return try? JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    static var session: StoredCredentials? { readCredentials(forClientID: Client.id) }

    static var isSignedIn: Bool { session != nil }

    private static func store(_ credentials: StoredCredentials) throws {
        try FileManager.default.createDirectory(at: configurationFolder, withIntermediateDirectories: true)

        var storeContents = readRawCredentialStore()
        storeContents[Client.id] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(credentials))

        try JSONSerialization.data(withJSONObject: storeContents).write(to: authConfigURL, options: [.atomic])

        // Readable only by this user: it's a bearer token for their whole GOG account, and the
        // default for a new file in Application Support is not that.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authConfigURL.path)
    }

    // MARK: - Errors

    struct SignInError: LocalizedError {
        var errorDescription: String? { String(localized: "Couldn't sign in to GOG.") }
        var recoverySuggestion: String? {
            String(localized: "Check your connection and try again. If it keeps failing, sign in at gog.com in a browser first.")
        }
    }

    struct NotSignedInError: LocalizedError {
        var errorDescription: String? { String(localized: "You're not signed in to GOG.") }
        var recoverySuggestion: String? { String(localized: "Sign in from Import Game › GOG.") }
    }

    struct RequestError: LocalizedError {
        let statusCode: Int
        var errorDescription: String? { String(localized: "GOG turned down a request.") }
        var failureReason: String? { "HTTP \(statusCode)" }
    }

    // MARK: - Signing in and out

    /// Exchanges the code a successful sign-in produced for a session.
    @discardableResult
    static func signIn(authorizationCode code: String) async throws -> StoredCredentials {
        var components: URLComponents = .init(string: "https://auth.gog.com/token")!
        components.queryItems = [
            .init(name: "client_id", value: Client.id),
            .init(name: "client_secret", value: Client.secret),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: Client.redirectURI)
        ]

        let credentials = StoredCredentials(from: try await decode(TokenResponse.self, from: .init(url: components.url!)))
        try store(credentials)

        log.notice("Signed in to GOG")
        return credentials
    }

    static func signOut() throws {
        try? FileManager.default.removeItem(at: authConfigURL)
        try? FileManager.default.removeItem(at: cacheURL)
        memoizedCache = nil
        log.notice("Signed out of GOG")
    }

    /// A token that will still be accepted, refreshing first if the stored one won't be.
    ///
    /// GOG's access tokens last an hour and its refresh tokens last far longer, so in practice
    /// this is what keeps an account signed in across weeks of not opening the app.
    static func accessToken() async throws -> String {
        guard let session else { throw NotSignedInError() }
        guard session.isExpired else { return session.accessToken }

        var components: URLComponents = .init(string: "https://auth.gog.com/token")!
        components.queryItems = [
            .init(name: "client_id", value: Client.id),
            .init(name: "client_secret", value: Client.secret),
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: session.refreshToken)
        ]

        do {
            let refreshed = StoredCredentials(from: try await decode(TokenResponse.self, from: .init(url: components.url!)))
            try store(refreshed)
            return refreshed.accessToken
        } catch {
            // A refresh token GOG no longer accepts means the account is signed out, whatever
            // the file on disk says. Saying so beats every later call failing for a reason
            // that looks like a network problem.
            log.warning("GOG refused to refresh the session; signing out. \(error.localizedDescription)")
            try? signOut()
            throw NotSignedInError()
        }
    }

    // MARK: - Library

    /// One entry of `getFilteredProducts`, which is the endpoint GOG's own web library uses.
    ///
    /// Worth preferring over `/user/data/games`: that one answers with a list of ids and
    /// nothing else, which turns a library of two hundred games into two hundred requests.
    struct Product: Decodable {
        let id: Int
        let title: String
        /// A protocol-relative CDN path with no extension, e.g. `//images-2.gog-statics.com/<hash>`.
        let image: String?
        let slug: String?
        let worksOn: Platforms?
        let isGame: Bool?

        struct Platforms: Decodable {
            let windows: Bool?
            let mac: Bool?
            let linux: Bool?

            enum CodingKeys: String, CodingKey {
                case windows = "Windows"
                case mac = "Mac"
                case linux = "Linux"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id, title, image, slug, worksOn, isGame
        }
    }

    private struct ProductsPage: Decodable {
        let page: Int
        let totalPages: Int
        let products: [Product]
    }

    /// Everything on the account, in the order GOG returns it.
    static func getOwnedProducts() async throws -> [Product] {
        var products: [Product] = .init()
        var page = 1

        // GOG pages at 50. It reports the total up front, so this is bounded by the account's
        // size rather than by trusting an empty page to arrive.
        repeat {
            var components: URLComponents = .init(string: "https://embed.gog.com/account/getFilteredProducts")!
            components.queryItems = [
                .init(name: "mediaType", value: "1"), // games, not movies
                .init(name: "page", value: String(page))
            ]

            let result = try await decode(ProductsPage.self, from: try await authorized(components.url!))
            products.append(contentsOf: result.products)

            guard result.page < result.totalPages else { break }
            page += 1
        } while page < 100 // a library this size doesn't exist; a paging bug that loops does

        log.notice("GOG library: \(products.count, privacy: .public) products")
        return products
    }

    /// The owned library as games Mythic can show.
    static func getInstallableGames() async throws -> [GOGGame] {
        let products = try await getOwnedProducts().filter { $0.isGame ?? true }
        cache(products)
        return products.map(GOGGame.init(product:))
    }

    // MARK: - Product cache

    /// What GOG said about a product, kept so a decoded game can answer questions about
    /// itself without the account being reachable.
    ///
    /// A `Game` subclass cannot add anything to what gets persisted — `Game.encode(to:)` is
    /// declared in an extension, so it can't be overridden — which leaves two options for
    /// per-game storefront data: derive it from the id, as ``SteamGame`` does with its AppID,
    /// or keep it beside the account, as legendary does with its metadata. Artwork and
    /// platforms can't be derived from a GOG product id, so this is the second one.
    struct CachedProduct: Codable {
        let imagePath: String?
        let windows: Bool
        let mac: Bool
    }

    static var cacheURL: URL { configurationFolder.appending(path: "products.json") }

    /// Read once, then kept — this is consulted for every card in the library grid.
    private nonisolated(unsafe) static var memoizedCache: [String: CachedProduct]?

    static func cache(_ products: [Product]) {
        var cached: [String: CachedProduct] = .init()

        for product in products {
            cached[String(product.id)] = .init(imagePath: product.image,
                                               windows: product.worksOn?.windows ?? false,
                                               mac: product.worksOn?.mac ?? false)
        }

        memoizedCache = cached

        do {
            try FileManager.default.createDirectory(at: configurationFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(cached).write(to: cacheURL, options: [.atomic])
        } catch {
            // Losing the cache costs artwork until the next refresh, nothing more.
            log.warning("Couldn't cache GOG product data: \(error.localizedDescription)")
        }
    }

    static func cachedProduct(id: String) -> CachedProduct? {
        if memoizedCache == nil {
            memoizedCache = (try? Data(contentsOf: cacheURL))
                .flatMap { try? JSONDecoder().decode([String: CachedProduct].self, from: $0) } ?? .init()
        }

        return memoizedCache?[id]
    }

    // MARK: - Artwork

    /// GOG serves one image per product in a set of named sizes, picked by suffix.
    ///
    /// `image` arrives protocol-relative and extensionless — `//images-2.gog-statics.com/<hash>`
    /// — and the caller appends the variant it wants. These two are the ones that match the
    /// shapes Mythic's cards are cut for; if a variant is ever retired, this is the only place
    /// that needs to know.
    enum ImageVariant: String {
        /// Tall. What the library grid wants.
        case vertical = "_product_card_v2_mobile_slider_639.jpg"
        /// Wide. Used where a game is shown as a banner.
        case horizontal = "_product_tile_extended_432x243.jpg"
    }

    static func imageURL(for product: Product, variant: ImageVariant) -> URL? {
        imageURL(fromCDNPath: product.image, variant: variant)
    }

    static func imageURL(forProductID id: String, variant: ImageVariant) -> URL? {
        imageURL(fromCDNPath: cachedProduct(id: id)?.imagePath, variant: variant)
    }

    static func imageURL(fromCDNPath path: String?, variant: ImageVariant) -> URL? {
        guard let path, !path.isEmpty else { return nil }

        // Protocol-relative, because it's meant for a browser that already has one.
        let absolute = path.hasPrefix("//") ? "https:\(path)" : path
        return URL(string: absolute + variant.rawValue)
    }

    // MARK: - Requests

    private static func authorized(_ url: URL) async throws -> URLRequest {
        var request: URLRequest = .init(url: url)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func decode<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RequestError(statusCode: http.statusCode)
        }

        return try JSONDecoder().decode(type, from: data)
    }
}
