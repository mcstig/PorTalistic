# The Library screen (archived)

The app's own home screen from Oct 8, 2026: installed games as covers (SwiftUI), Play,
right-click Properties / Uninstall, and a Library | Steam toolbar switch. Taken out of the app on
Oct 9 in favour of Steam's Big Picture, which already does all of that (and more) itself.

These files aren't built (they're outside host/Portalistic/). To bring the screen back, move
them into host/Portalistic/ and restore the hooks they used in AppDelegate (the toolbar, the
`showing` state, `readLibrary` after a connection); `bottle library --copy` still produces the
data they read.
