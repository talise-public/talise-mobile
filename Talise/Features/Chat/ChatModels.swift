import Foundation

/// Plan 12 — domain model for the AI finance chat tab.
///
/// We deliberately keep the shape narrow: each message is a role +
/// streamed text. Tool calls surface as transient assistant annotations
/// but never live in the persisted transcript (they're transport-level
/// detail). The persisted history is what the next request POSTs back
/// to `/api/chat/stream` so multi-turn context survives an app relaunch.
struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable, Hashable {
        case user
        case assistant
    }

    let id: UUID
    var role: Role
    var content: String

    /// `streaming == true` indicates the assistant is still receiving
    /// SSE token deltas — used by the UI to show a tail caret and skip
    /// "Empty reply" emptiness checks while characters are still flowing.
    var streaming: Bool

    init(id: UUID = UUID(), role: Role, content: String, streaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.streaming = streaming
    }
}

/// SSE frame parsed off the wire. See `/api/chat/stream` for the
/// canonical schema — three event types only: text, tool_use, done.
enum ChatStreamEvent {
    case text(String)
    case toolUse(name: String, args: [String: Any])
    case done

    /// Decode a single JSON object payload. Returns nil for unrecognised
    /// shapes so a noisy frame can't crash the stream loop.
    static func decode(_ json: [String: Any]) -> ChatStreamEvent? {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "text":
            guard let value = json["value"] as? String else { return nil }
            return .text(value)
        case "tool_use":
            let name = (json["tool"] as? String) ?? ""
            let args = (json["args"] as? [String: Any]) ?? [:]
            return .toolUse(name: name, args: args)
        case "done":
            return .done
        default:
            return nil
        }
    }
}

/// Wire payload posted to `/api/chat/stream`.
struct ChatRequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }
    let messages: [Message]
}
