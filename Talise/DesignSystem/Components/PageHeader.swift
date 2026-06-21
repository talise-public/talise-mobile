import SwiftUI

/// Matches the web `<PageIntro>` rhythm — eyebrow + 22-26pt title.
struct PageHeader: View {
    let eyebrow: String
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: eyebrow)
                Text(title)
                    .font(TaliseFont.heading(26, weight: .semibold))
                    .kerning(-0.5)
                    .foregroundStyle(TaliseColor.fg)
            }
            Spacer()
            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, TaliseSpacing.xl)
        .padding(.top, TaliseSpacing.xl)
        .padding(.bottom, TaliseSpacing.lg)
    }
}

// NOTE: the section eyebrow is now the shared generic `SectionHeader<Trailing>`
// in TopGlow.swift (string title + optional trailing slot). The old
// non-generic `SectionHeader { title; right }` lived here and was removed —
// it had no remaining callers and collided with the new type.
