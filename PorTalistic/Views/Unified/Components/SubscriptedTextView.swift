//
//  SubscriptedTextView.swift
//  Mythic
//
//  Created by vapidinfinity (esi) on 20/3/2024.
//

// Copyright © 2023-2025 vapidinfinity

import SwiftUI

struct SubscriptedTextView: View {
    init(_ text: String) {
        self.text = text
    }
    
    var text: String = .init()
    
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 5)
            .background( // based on .buttonStyle(.accessoryBarAction)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.tertiary)
            )
            .compositingGroup()
            // These sit in a card's label strip under a `.lineLimit(1)`, in whatever width
            // is left over beside the title and the buttons, so "Recent" routinely renders
            // as "Re...". SwiftUI puts no tooltip on truncated text of its own accord, and
            // a badge you can't read is just noise. Unconditional rather than
            // only-when-truncated: there's no reliable way to ask a `Text` whether it
            // truncated, and a tooltip that repeats text you can already read costs nothing.
            .help(text)
    }
}

#Preview {
    SubscriptedTextView("Test Text")
        .padding()
}
