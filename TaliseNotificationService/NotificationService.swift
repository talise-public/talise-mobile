import UserNotifications

/// Talise Notification Service Extension.
///
/// iOS owns the notification banner chrome — an app cannot color or restyle
/// it. The one supported way to put Talise's look INTO a notification is a
/// rich-media attachment: when a push carries `mutable-content: 1`, iOS hands
/// it to this extension BEFORE display, and we attach a branded mint card
/// (rendered server-side at /api/notify/card) so the expanded / long-pressed
/// notification shows our theme — amount in mint on the dark Talise field.
///
/// Contract: this MUST be fast and MUST always deliver. The clean text-only
/// notification (title/body the server already composed) is the floor — if
/// the image is missing, slow, or fails to download, we deliver the text as
/// is. A notification is never dropped because the decoration failed.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        self.bestAttempt = mutable

        guard
            let content = mutable,
            let urlString = request.content.userInfo["talise-image"] as? String,
            let url = URL(string: urlString),
            url.scheme == "https"
        else {
            // No image (or non-https) — deliver the clean text notification.
            contentHandler(request.content)
            return
        }

        // Download the branded card. Short timeout: APNs gives the extension
        // only a few seconds, and a credit notification must surface promptly
        // either way — so we never let the image fetch hold it up.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        session.downloadTask(with: url) { [weak self] tempURL, _, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            if let tempURL,
               let attachment = Self.makeAttachment(from: tempURL) {
                content.attachments = [attachment]
            }
            // Whether or not the image landed, deliver our best attempt.
            (self.contentHandler ?? contentHandler)(content)
        }.resume()
    }

    /// iOS is about to kill the extension — ship whatever we have (text at
    /// minimum). Never let the notification get swallowed by a timeout.
    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    /// Move the downloaded file to a uniquely-named temp path with a `.png`
    /// extension so iOS recognises the media type, then wrap it as an
    /// attachment. Returns nil on any IO failure (caller falls back to text).
    private static func makeAttachment(from tempURL: URL) -> UNNotificationAttachment? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("talise-credit.png")
            try fm.moveItem(at: tempURL, to: dest)
            return try UNNotificationAttachment(
                identifier: "talise-card",
                url: dest,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"]
            )
        } catch {
            return nil
        }
    }
}
