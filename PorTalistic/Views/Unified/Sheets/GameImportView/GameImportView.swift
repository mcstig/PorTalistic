//
//  GameImportView.swift
//  PorTalistic
//
//  Created by vapidinfinity (esi) on 29/9/2023.
//  Rebuilt by Claude Opus 5 on 14/9/2026.
//

// Copyright © 2023-2025 vapidinfinity
// Copyright © 2026 Michael Stoian

import SwiftUI
import OSLog

/**
 Import Game: a storefront on the left, its importer on the right.

 This was a `TabView` with `.tabViewStyle(.sidebarAdaptable)`, and it did not work. The
 sidebar drew as an empty rounded panel with no rows and no header, and the GOG tab appeared
 completely blank — its "Refresh Library" and "Sign Out" buttons were laid out at y = −1598,
 sixteen hundred points above the top of the sheet. The content was never missing: the
 adaptable tab style proposed an enormous height to the tab's contents, the `Spacer()` above
 that tab's footer expanded to fill it, and everything above the spacer was pushed out of the
 sheet. Only the footer — pinned to the bottom — was ever visible.

 A rail and a switch propose ordinary sizes, so a `Spacer()` means what it says. It also
 gives the sheet a definite size rather than inheriting whatever its content asks for, which
 is what left the Local tab rendering "Otherwise, browse for a thumbnail file:" as six
 wrapped lines in a seventy-point column.
 */
struct GameImportView: View {
    @Binding var isPresented: Bool

    /// Which storefront to open on. Passed in from the library you asked from, so importing
    /// into a particular library doesn't begin by asking which storefront you meant.
    @State private var selection: Game.Storefront

    init(isPresented: Binding<Bool>, storefront: Game.Storefront? = nil) {
        self._isPresented = isPresented
        // A hidden storefront asked for by name still can't be opened on.
        let requested = storefront.flatMap { $0.isAvailable ? $0 : nil }
        self._selection = .init(initialValue: requested ?? .epicGames)
    }

    var body: some View {
        HStack(spacing: 0) {
            rail

            Divider()

            importer
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Import Game")
        .sheetSurface(minWidth: 860, idealWidth: 920, minHeight: 460, idealHeight: 500)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text("STOREFRONT")
                .font(Theme.Text.heroEyebrow)
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.bottom, Theme.Spacing.xsmall)

            ForEach(Game.Storefront.available, id: \.self) { storefront in
                Button {
                    selection = storefront
                } label: {
                    Label(storefront.description, systemImage: storefront.symbolName)
                }
                .buttonStyle(PortalRailButtonStyle(isSelected: selection == storefront))
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 184)
        .background(Theme.Palette.panel)
    }

    @ViewBuilder
    private var importer: some View {
        switch selection {
        case .epicGames:    EpicGamesGameImportView(isPresented: $isPresented)
        case .gog:          GOGGameImportView(isPresented: $isPresented)
        case .steam:        SteamGameImportView(isPresented: $isPresented)
        case .local:        LocalGameImportView(isPresented: $isPresented)
        }
    }
}

#Preview {
    GameImportView(isPresented: .constant(true))
}
