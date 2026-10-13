// Portalistic — a game in the Library: its cover, Play button and right-click menu.

import AppKit
import SwiftUI

struct PlayButton: View {
    var title = "Play"
    var big = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "play.fill")
                .font(.system(size: big ? 15 : 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, big ? 24 : 16)
                .padding(.vertical, big ? 10 : 7)
                .background(Capsule().fill(Palette.liquid))
                .shadow(color: Palette.violet.opacity(0.45), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct GameTile: View {
    let game: Game
    @ObservedObject var model: LibraryModel
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(CoverArt(game: game, model: model))
                .overlay(alignment: .topLeading) { badge }
                .overlay(alignment: .bottomLeading) { hoverPlay }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hover ? AnyShapeStyle(Palette.liquid) : AnyShapeStyle(Color.white.opacity(0.07)),
                                  lineWidth: hover ? 2 : 1))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
                .onHover { hover = $0 }
                .onTapGesture(count: 2) { model.onPlay?(game) }
            Text(game.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.text)
                .lineLimit(1)
            Text(model.played(game))
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
                .lineLimit(1)
        }
        .contextMenu { GameMenu(game: game, model: model) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.onPlay?(game) }
    }

    @ViewBuilder private var badge: some View {
        if let b = model.status(game) {
            Text(b)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Palette.text)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Palette.ink.opacity(0.85)))
                .padding(8)
        }
    }

    @ViewBuilder private var hoverPlay: some View {
        if hover {
            PlayButton(title: model.isRunning(game) ? "Back to Game" : "Play") { model.onPlay?(game) }
                .padding(10)
        }
    }
}

struct GameMenu: View {
    let game: Game
    @ObservedObject var model: LibraryModel

    var body: some View {
        Button(model.isRunning(game) ? "Back to Game" : "Play") { model.onPlay?(game) }
        Divider()
        Button("Properties…") { model.onOpen?("steam://gameproperties/\(game.appid)") }
        Button("Show in Steam") { model.onOpen?("steam://nav/games/details/\(game.appid)") }
        Button("Check Game Files") { model.onOpen?("steam://validate/\(game.appid)") }
        Divider()
        Button("Uninstall…") { model.onOpen?("steam://uninstall/\(game.appid)") }
    }
}

/// The cover Steam cached in the VM; a wide header centred over a blurred copy of itself; the
/// store's cover; or the game's name.
struct CoverArt: View {
    let game: Game
    @ObservedObject var model: LibraryModel

    var body: some View {
        if let img = model.image(for: game) {
            if game.coverKind == "wide" {
                ZStack {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).blur(radius: 18).opacity(0.7)
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
            } else {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            }
        } else {
            AsyncImage(url: model.storeCoverURL(game)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    NameCard(name: game.name)
                }
            }
        }
    }
}

struct NameCard: View {
    let name: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Palette.panel
            Rectangle().fill(Palette.liquid.opacity(0.28))
            Text(name)
                .font(.system(size: 17, weight: .heavy).width(.expanded))
                .foregroundColor(Palette.text)
                .lineLimit(4)
                .padding(12)
        }
    }
}
