import SwiftUI

/// Step 1 of the cross-border flow: pick WHERE the money lands (country /
/// currency) and WHO receives it. Destination chips are gated against the
/// live corridor registry — bookable routes are tappable, "coming soon"
/// ones render disabled so the catalogue reads honestly.
struct CrossBorderRecipientView: View {
    @Bindable var draft: CrossBorderDraft
    var onNext: () -> Void
    var onCancel: () -> Void

    /// Bookable destination country codes from `/api/corridors`. Empty
    /// until the registry loads; we fall back to the static catalogue's
    /// own status hints so the picker is never blank.
    @State private var bookable: Set<String> = []
    @State private var registryLoaded = false

    @State private var resolving = false
    @State private var resolveTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    originRow
                    destinationSection
                    recipientSection
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }

            nextButton
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
        }
        .background(TaliseColor.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { Task { await loadRegistry() } }
        .onDisappear { resolveTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(TaliseColor.surfaceGlass))
            }
            Spacer()
            MicroLabel(text: "Send abroad", color: TaliseColor.fgDim).kerning(1.5)
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    // MARK: - Origin

    private var originRow: some View {
        HStack(spacing: 10) {
            RoundedFlag(code: draft.origin.code, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(text: "You pay from")
                Text("\(draft.origin.name) · \(draft.origin.currencyCode)")
                    .font(TaliseFont.body(14, weight: .regular))
                    .foregroundStyle(TaliseColor.fg)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taliseGlass(cornerRadius: 18)
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Recipient gets paid in")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(destinations) { country in
                    destinationChip(country)
                }
            }
        }
    }

    /// Destinations the catalogue knows, minus the sender's own country
    /// (a cross-border send to the same country isn't this rail).
    private var destinations: [CrossBorderCountry] {
        CrossBorderCatalogue.destinations.filter { $0.code != draft.origin.code }
    }

    private func destinationChip(_ country: CrossBorderCountry) -> some View {
        let isBookable = canBook(country)
        let isSelected = draft.destination?.code == country.code
        return Button {
            guard isBookable else { return }
            draft.destination = country
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 8) {
                RoundedFlag(code: country.code, size: 30, dimmed: !isBookable)
                VStack(alignment: .leading, spacing: 1) {
                    Text(country.name)
                        .font(TaliseFont.body(13, weight: .regular))
                        .foregroundStyle(isBookable ? TaliseColor.fg : TaliseColor.fgDim)
                        .lineLimit(1)
                    if isBookable {
                        Text(country.currencyCode)
                            .font(TaliseFont.mono(9, weight: .light))
                            .foregroundStyle(TaliseColor.fgMuted)
                    } else {
                        Text("Soon")
                            .font(TaliseFont.mono(9, weight: .light))
                            .foregroundStyle(TaliseColor.fgDim)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? TaliseColor.accent.opacity(0.16) : TaliseColor.surfaceGlass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? TaliseColor.accent : TaliseColor.line, lineWidth: isSelected ? 1 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isBookable)
        .opacity(isBookable ? 1 : 0.55)
    }

    /// A destination is bookable if the live registry says so. Before the
    /// registry loads we optimistically allow everything (the quote call
    /// is the authoritative gate and surfaces NOT_BOOKABLE cleanly).
    private func canBook(_ country: CrossBorderCountry) -> Bool {
        guard registryLoaded else { return true }
        return bookable.contains(country.code)
    }

    // MARK: - Recipient

    private var recipientSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "To")
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    "alice / 0x6487… / @handle",
                    text: $draft.recipientInput
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .textContentType(.username)
                .keyboardType(.asciiCapable)
                .font(TaliseFont.body(17, weight: .regular))
                .foregroundStyle(TaliseColor.fg)
                .tint(TaliseColor.accent)
                .focused($inputFocused)
                .onChange(of: draft.recipientInput) { _, new in
                    scheduleResolve(new)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .taliseGlass(cornerRadius: 18)

            resolveStatus
        }
    }

    @ViewBuilder
    private var resolveStatus: some View {
        if resolving {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(TaliseColor.fgDim)
                MicroLabel(text: "Resolving…", color: TaliseColor.fgDim)
                Spacer()
            }
            .padding(.horizontal, 4)
        } else if let r = draft.resolved {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TaliseColor.accent)
                Text(r.displayName ?? r.address)
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.accent)
                Text(shortAddress(r.address))
                    .font(TaliseFont.mono(10, weight: .light))
                    .foregroundStyle(TaliseColor.fgDim)
                Spacer()
            }
            .padding(.horizontal, 4)
        } else if draft.recipientInput.count >= 3 {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(TaliseColor.danger)
                Text("No match yet for \"\(draft.recipientInput)\"")
                    .font(TaliseFont.mono(11, weight: .light))
                    .foregroundStyle(TaliseColor.danger)
                Spacer()
            }
            .padding(.horizontal, 4)
        } else {
            Color.clear.frame(height: 14)
        }
    }

    // MARK: - Next

    private var nextButton: some View {
        Button(action: {
            guard canAdvance else { return }
            inputFocused = false
            onNext()
        }) {
            Text("Next")
                .font(TaliseFont.heading(16, weight: .medium))
                .foregroundStyle(TaliseColor.bg)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(canAdvance ? TaliseColor.fg : TaliseColor.fg.opacity(0.35))
                .clipShape(Capsule())
        }
        .disabled(!canAdvance)
    }

    private var canAdvance: Bool {
        draft.destination != nil && draft.resolved != nil
    }

    // MARK: - Resolve

    private func scheduleResolve(_ input: String) {
        resolveTask?.cancel()
        draft.resolved = nil
        let q = input.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { resolving = false; return }
        if let addr = SuiAddress(q) {
            draft.resolved = RecipientResolution(
                address: addr.raw,
                displayName: addr.short,
                display: nil,
                source: "address"
            )
            resolving = false
            return
        }
        resolving = true
        resolveTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            do {
                let encoded = q.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed
                ) ?? q
                let r: RecipientResolution = try await APIClient.shared.get(
                    "/api/recipient/resolve?q=\(encoded)"
                )
                if Task.isCancelled { return }
                draft.resolved = r
            } catch {
                if Task.isCancelled { return }
                draft.resolved = nil
            }
            resolving = false
        }
    }

    // MARK: - Registry

    private func loadRegistry() async {
        do {
            let reg = try await CrossBorderAPI.corridors()
            // A destination country is bookable when ANY corridor INTO it
            // from the sender's origin is bookable. We key on the
            // origin→destination pair so e.g. SG→PH lights up only when
            // the sender pays from SG.
            var set: Set<String> = []
            for c in reg.corridors where c.fromCountry == draft.origin.code && c.isBookable {
                set.insert(c.toCountry)
            }
            bookable = set
            registryLoaded = true
        } catch {
            // Soft-fail: leave the picker optimistic. The quote call is
            // the hard gate (returns NOT_BOOKABLE / UNKNOWN_CORRIDOR).
            registryLoaded = false
        }
    }

    private func shortAddress(_ a: String) -> String {
        guard a.count > 14 else { return a }
        return String(a.prefix(8)) + "…" + String(a.suffix(6))
    }
}
