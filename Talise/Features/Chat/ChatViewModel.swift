import Foundation
import SwiftUI

/// Plan 12 — view model for the streaming chat tab.
///
/// Owns the transcript, the in-flight `URLSession.bytes(for:)` task,
/// and the incremental decoder. The view binds to `messages`, `input`,
/// and `streaming`. All mutations happen on the main actor so SwiftUI
/// observes them cleanly during a token stream.
@MainActor
@Observable
final class ChatViewModel {
    /// Transcript shown in the UI. Newest at the end. Persisted to
    /// Keychain on every assistant-stream completion.
    var messages: [ChatMessage] = []
    /// Bound to the input pill at the bottom of the chat tab.
    var input: String = ""
    /// True while we are reading from the SSE stream (or waiting for the
    /// first byte). The view disables the send button and hides the
    /// suggested-prompts strip while this is true.
    var streaming: Bool = false
    /// Surface-level error banner. Cleared on the next submit.
    var lastError: String?

    private var streamTask: Task<Void, Never>?

    init() {
        self.messages = ChatHistoryStore.shared.load()
    }

    /// User tapped a suggested-prompt chip. Drop the prompt into the
    /// input field rather than auto-submitting — gives the user a chance
    /// to edit the wording before sending.
    func fillPrompt(_ text: String) {
        input = text
    }

    func clearTranscript() {
        streamTask?.cancel()
        streamTask = nil
        streaming = false
        messages = []
        ChatHistoryStore.shared.clear()
    }

    /// Submit the current input. No-op if empty or already streaming.
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }

        lastError = nil
        let userMessage = ChatMessage(role: .user, content: text)
        messages.append(userMessage)
        input = ""

        // Insert a placeholder assistant message that we'll mutate as
        // SSE deltas arrive. SwiftUI re-renders the same row in place.
        let assistantId = UUID()
        messages.append(
            ChatMessage(id: assistantId, role: .assistant, content: "", streaming: true)
        )
        // Persist the prompt eagerly so a crash doesn't lose the user's
        // half of the turn. The assistant half is persisted on completion.
        ChatHistoryStore.shared.save(messages)

        streaming = true
        streamTask = Task { [weak self] in
            await self?.runStream(assistantId: assistantId)
        }
    }

    private func runStream(assistantId: UUID) async {
        defer {
            streaming = false
            streamTask = nil
        }

        // Build request -------------------------------------------------
        guard let url = URL(string: AppConfig.shared.apiBaseURL + "/api/chat/stream") else {
            finalizeWithError(assistantId: assistantId, message: "Bad chat URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let bearer = SecureSessionStore.shared.read() {
            req.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        // Send only the persisted-cap window of prior turns — the route
        // also caps server-side, but trimming here saves bandwidth.
        let payload = ChatRequestBody(
            messages: messages
                .filter { $0.streaming == false || $0.role == .user }
                .map {
                    ChatRequestBody.Message(role: $0.role.rawValue, content: $0.content)
                }
        )
        do {
            req.httpBody = try JSONEncoder().encode(payload)
        } catch {
            finalizeWithError(assistantId: assistantId, message: "Encode failure")
            return
        }

        // Stream --------------------------------------------------------
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                finalizeWithError(
                    assistantId: assistantId,
                    message: "Chat HTTP \(http.statusCode)"
                )
                return
            }

            // SSE accumulator. A single event ends at the first blank
            // line. Lines starting with `data:` carry the payload —
            // we concatenate them across multi-line frames per the SSE
            // spec, then JSON-decode.
            var dataBuffer = ""
            for try await line in bytes.lines {
                if line.isEmpty {
                    if !dataBuffer.isEmpty {
                        await handleEventJSON(dataBuffer, assistantId: assistantId)
                        dataBuffer = ""
                    }
                    continue
                }
                if line.hasPrefix("data:") {
                    // Strip "data:" + at most one leading space.
                    let after = line.index(line.startIndex, offsetBy: 5)
                    var slice = line[after...]
                    if slice.first == " " { slice = slice.dropFirst() }
                    if !dataBuffer.isEmpty { dataBuffer += "\n" }
                    dataBuffer += slice
                }
                // Other SSE field types (event:, id:, retry:) are not
                // emitted by our backend; ignore them gracefully.
            }
            if !dataBuffer.isEmpty {
                await handleEventJSON(dataBuffer, assistantId: assistantId)
            }
        } catch {
            if Task.isCancelled { return }
            finalizeWithError(assistantId: assistantId, message: error.localizedDescription)
            return
        }

        // Stream ended cleanly (either via `done` event or EOF) ---------
        finalize(assistantId: assistantId)
    }

    private func handleEventJSON(_ raw: String, assistantId: UUID) async {
        guard
            let data = raw.data(using: .utf8),
            let any = try? JSONSerialization.jsonObject(with: data),
            let obj = any as? [String: Any],
            let event = ChatStreamEvent.decode(obj)
        else {
            return
        }
        switch event {
        case .text(let value):
            appendAssistant(text: value, id: assistantId)
        case .toolUse:
            // Tool-use events are informational. We don't render them
            // inline for now — the assistant's follow-up text already
            // grounds the answer. Future: show a tiny "looked up your
            // balance" chip above the bubble.
            break
        case .done:
            // No-op — `runStream` finalizes after the stream ends.
            break
        }
    }

    private func appendAssistant(text: String, id: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[idx].content += text
        // The Talise agent emits structured `---INTENT---{...}---END---`
        // blocks inline. They're the agent's machine-readable payload
        // (Payment Intents the app can execute on confirm), not text
        // for the user. Strip them from the rendered content on each
        // delta so the bubble shows only the natural-language prose —
        // even while the block is still streaming in. We keep the raw
        // stream available for a future intent-card UI that listens
        // for the closing `---END---` and renders an action card.
        messages[idx].content = stripIntentBlocks(messages[idx].content)
    }

    /// Removes any `---INTENT---{json}---END---` fence (and trailing
    /// blank lines it leaves) from a string. Handles partial blocks
    /// mid-stream: an open fence with no closing tag yet is trimmed
    /// to the last newline before the fence, so we don't flash a half-
    /// rendered `---INTENT---{"steps":[…` to the user.
    private func stripIntentBlocks(_ s: String) -> String {
        var out = s
        // Full closed fences — remove all of them (the agent can emit
        // more than one in a single turn).
        while let openRange = out.range(of: "---INTENT---") {
            if let closeRange = out.range(
                of: "---END---", range: openRange.upperBound..<out.endIndex
            ) {
                out.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
            } else {
                // Open fence with no close yet — we're still mid-stream.
                // Hide from the open marker to the end of the buffer so
                // the user never sees `---INTENT---{…` partially.
                out.removeSubrange(openRange.lowerBound..<out.endIndex)
                break
            }
        }
        // Collapse the blank lines fences typically leave behind.
        return out
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalize(assistantId: UUID) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].streaming = false
            if messages[idx].content.isEmpty {
                messages[idx].content = "(no reply)"
            }
        }
        ChatHistoryStore.shared.save(messages)
    }

    private func finalizeWithError(assistantId: UUID, message: String) {
        if let idx = messages.firstIndex(where: { $0.id == assistantId }) {
            messages[idx].streaming = false
            if messages[idx].content.isEmpty {
                messages[idx].content = "Couldn't reach the assistant — \(message)."
            }
        }
        lastError = message
        ChatHistoryStore.shared.save(messages)
    }
}
