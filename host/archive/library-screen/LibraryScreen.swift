// Portalistic — the Library (the app's home screen): the game at the top, the header,
// notices, and the grid of covers.

import AppKit
import SwiftUI

struct LibraryScreen: View {
    @ObservedObject var model: LibraryModel
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 196), spacing: 22, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if let g = model.featured {
                    Featured(game: g, model: model)
                }
                LibraryHeader(model: model)
                LibraryNotice(model: model)
                if !model.shown.isEmpty {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(model.shown) { g in
                            GameTile(game: g, model: model)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .background(Rectangle().fill(Palette.backdrop))
    }
}

/// The game running, else the last one played: its cover, and the same cover blurred behind it.
struct Featured: View {
    let game: Game
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            Color.clear
                .frame(width: 168, height: 252)
                .overlay(CoverArt(game: game, model: model))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)
            VStack(alignment: .leading, spacing: 8) {
                Text(game.name)
                    .font(.system(size: 34, weight: .heavy).width(.expanded))
                    .foregroundColor(Palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                Text(model.status(game) ?? model.played(game))
                    .font(.system(size: 14))
                    .foregroundColor(Palette.muted)
                if let t = model.playtime(game) {
                    Text(t)
                        .font(.system(size: 14))
                        .foregroundColor(Palette.muted)
                }
                HStack(spacing: 12) {
                    PlayButton(title: model.isRunning(game) ? "Back to Game" : "Play", big: true) { model.onPlay?(game) }
                    Button("Properties") { model.onOpen?("steam://gameproperties/\(game.appid)") }
                        .controlSize(.large)
                }
                .padding(.top, 10)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 308, alignment: .leading)
        .background(FeaturedBackdrop(game: game, model: model).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct FeaturedBackdrop: View {
    let game: Game
    @ObservedObject var model: LibraryModel

    var body: some View {
        ZStack {
            Palette.panel
            if let img = model.image(for: game) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 46)
                    .saturation(1.25)
                    .opacity(0.9)
            }
            LinearGradient(colors: [Palette.ink.opacity(0.35), Palette.ink.opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }
}

struct LibraryHeader: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Your games")
                .font(.system(size: 22, weight: .heavy).width(.expanded))
                .foregroundColor(Palette.text)
            Text("\(model.games.count)")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Palette.muted)
            Spacer()
            TextField("Search games", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Picker("Sort", selection: $model.sort) {
                ForEach(LibraryModel.Sort.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            if model.reading {
                ProgressView().controlSize(.small).frame(width: 28)
            } else {
                Button { model.onRefresh?() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Read the games from the bottle again")
                    .frame(width: 28)
            }
        }
    }
}

/// Reading, empty, nothing found, or what to do first.
struct LibraryNotice: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        if model.needsUpdate {
            NoticeRow(text: "The bottle needs an update before your games can show up here.",
                      action: "Update the Bottle") { model.onUpdate?() }
        } else if model.games.isEmpty && model.reading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading your games…").foregroundColor(Palette.muted)
            }
        } else if let m = model.message, model.games.isEmpty {
            NoticeRow(text: "Couldn't read your games: \(m)", action: "Try Again") { model.onRefresh?() }
        } else if model.games.isEmpty {
            NoticeRow(text: "No games installed yet. Install them in Steam and they show up here.",
                      action: "Show Steam") { model.onShowSteam?() }
        } else if model.shown.isEmpty {
            Text("No games match “\(model.search)”.").foregroundColor(Palette.muted)
        }
    }
}

struct NoticeRow: View {
    let text: String
    let action: String
    let run: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(text).foregroundColor(Palette.text)
            Button(action, action: run)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
    }
}
