import SwiftUI

/// The hairline that sets the panel's bars apart from the history: under the top bar and
/// above the text field. Both use this one definition, so they keep the same color,
/// thickness, and width.
struct PanelDivider: View {
    var body: some View {
        Divider().opacity(0.5)
    }
}
