import UIKit

/// True on iPad, false on iPhone. Used to gate features that only make
/// sense with extra screen room — additional buttons, additional
/// dial+fader combos — without touching the iPhone layout at all.
let isPadIdiom = UIDevice.current.userInterfaceIdiom == .pad
