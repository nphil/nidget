import SwiftUI

// MARK: - SectionHeader
//
// Themed section label used above card groups and inside custom lists — NOT a List section
// header. Applies the theme's label casing and tracking so "editorial" themes read all-caps
// wide-tracked while quieter themes keep natural case. An optional trailing accessory (e.g. a
// "See All" button) sits on the same baseline.

struct SectionHeader: View {
    private let title: String
    private let trailing: (() -> AnyView)?

    @Environment(\.theme) private var theme

    init(_ title: String, trailing: (() -> AnyView)? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textSecondary)
                .textCase(theme.typography.labelCase)
                .tracking(theme.typography.labelTracking)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: theme.layout.spacing)
            if let trailing {
                trailing()
            }
        }
    }
}
