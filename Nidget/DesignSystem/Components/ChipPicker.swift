import SwiftUI

// MARK: - ChipPicker
//
// Horizontal scrolling capsule chips (month picker, account filters). The selected chip is an
// accent capsule that slides between chips via matchedGeometryEffect; unselected chips sit on
// the palette's subtle fill. Selection ticks the haptic engine and auto-centers the chosen chip.

struct ChipPicker<T: Hashable>: View {
    private let items: [T]
    @Binding private var selection: T
    private let label: (T) -> String

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var chipNamespace

    init(items: [T], selection: Binding<T>, label: @escaping (T) -> String) {
        self.items = items
        self._selection = selection
        self.label = label
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.layout.spacing * 0.6) {
                    ForEach(items, id: \.self) { item in
                        chip(item)
                            .id(item)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 2)
            }
            .scrollTargetBehavior(.viewAligned)
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, newValue in
                withAnimation(reduceMotion ? nil : theme.motion.snappy) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private func chip(_ item: T) -> some View {
        let isSelected = item == selection
        return Button {
            guard !isSelected else { return }
            Haptics.tick()
            if reduceMotion {
                selection = item
            } else {
                withAnimation(theme.motion.snappy) {
                    selection = item
                }
            }
        } label: {
            Text(label(item))
                .font(theme.font(.subheadline))
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .foregroundStyle(isSelected ? theme.palette.onAccent : theme.palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(theme.palette.accent)
                            .matchedGeometryEffect(id: "chip.selection", in: chipNamespace)
                    } else {
                        Capsule()
                            .fill(theme.palette.fill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
