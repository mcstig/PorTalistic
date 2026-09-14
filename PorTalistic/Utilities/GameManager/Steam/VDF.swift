//
//  VDF.swift
//  Mythic
//
//  Created by Claude (Cowork) on 4/9/2026.
//

// Copyright © 2023-2025 vapidinfinity

import Foundation

/// A minimal reader for Valve's VDF ("KeyValues") text format.
///
/// Steam uses this format for both `libraryfolders.vdf` (which library folders exist)
/// and `appmanifest_<appid>.acf` (per-game installation state). Both are simple,
/// non-nested-array, string-keyed trees, so this parser deliberately only supports
/// what those two file kinds actually use:
///
/// ```
/// "AppState"
/// {
///     "appid"         "570"
///     "name"          "Dota 2"
///     "installdir"    "dota 2 beta"
/// }
/// ```
///
/// - Note: This is intentionally forgiving — Steam's own writer is consistent, but we'd
///   rather degrade gracefully (skip a malformed node) than throw and break the whole
///   library scan over one corrupt manifest.
enum VDF {
    indirect enum Node {
        case string(String)
        case object([String: Node])
    }

    struct ParseError: LocalizedError {
        var errorDescription: String? = String(localized: "Unable to parse Steam's VDF-formatted file.")
    }

    /// Parses a VDF document's contents into a single root key and its `Node`.
    static func parse(_ contents: String) throws -> (key: String, value: Node) {
        var tokens = tokenize(contents)[...]
        guard let key = nextToken(&tokens) else { throw ParseError() }
        let value = try parseNode(&tokens)
        return (key, value)
    }

    // MARK: - Tokenizer

    /// Splits the document into quoted-string and brace tokens, skipping `//` comments.
    private static func tokenize(_ contents: String) -> [String] {
        var tokens: [String] = []
        var characters = Substring(contents)

        while let character = characters.first {
            if character == "\"" {
                characters.removeFirst()
                var value = ""
                while let next = characters.first, next != "\"" {
                    if next == "\\", let escaped = characters.dropFirst().first {
                        value.append(escaped)
                        characters.removeFirst(2)
                    } else {
                        value.append(next)
                        characters.removeFirst()
                    }
                }
                if !characters.isEmpty { characters.removeFirst() } // closing quote
                tokens.append(value)
            } else if character == "{" || character == "}" {
                tokens.append(String(character))
                characters.removeFirst()
            } else if character == "/", characters.dropFirst().first == "/" {
                // line comment — skip to newline
                while let next = characters.first, next != "\n" { characters.removeFirst() }
            } else if character.isWhitespace {
                characters.removeFirst()
            } else {
                // unquoted token (Steam's files are consistently quoted, but be lenient)
                var value = ""
                while let next = characters.first, !next.isWhitespace, next != "{", next != "}" {
                    value.append(next)
                    characters.removeFirst()
                }
                tokens.append(value)
            }
        }

        return tokens
    }

    private static func nextToken(_ tokens: inout ArraySlice<String>) -> String? {
        guard let token = tokens.first else { return nil }
        tokens.removeFirst()
        return token
    }

    private static func parseNode(_ tokens: inout ArraySlice<String>) throws -> Node {
        guard let token = nextToken(&tokens) else { throw ParseError() }

        if token == "{" {
            var object: [String: Node] = [:]
            while let peeked = tokens.first, peeked != "}" {
                guard let key = nextToken(&tokens) else { throw ParseError() }
                let value = try parseNode(&tokens)
                object[key] = value
            }
            _ = nextToken(&tokens) // consume "}"
            return .object(object)
        } else {
            return .string(token)
        }
    }
}

extension VDF.Node {
    /// Convenience subscript for walking a parsed object by key.
    subscript(_ key: String) -> VDF.Node? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: VDF.Node]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}
