import Foundation

/// Where a report is POSTed.
///
/// One constant, in one file, on purpose — this is the single thing that has to be changed
/// to move the collector.
///
/// `feedback.manifield.net` is a Cloudflare Worker on the maintainer's own domain rather
/// than a form service's URL. Builds handed to alpha testers keep this address compiled in
/// for as long as those copies exist, so the address has to outlive whatever is behind it:
/// pointing the DNS record at a different Worker, or a different collector entirely,
/// re-homes every installed build at once. A provider-specific URL would strand them.
///
/// The URL is public, and meant to be. The repository goes GPLv3, so anything compiled into
/// the app is readable by anyone — this constant included. That makes the address worthless
/// as a secret, and the server must not treat it as one: `Scripts/feedback-worker.js`
/// rate-limits by IP, caps the body size, and rejects anything that is not a well-formed
/// report. Obscurity is not part of the defence, because it cannot be.
public enum FeedbackEndpoint {
    public static let url = URL(string: "https://feedback.manifield.net/report")!

    /// Sent so the collector can tell builds apart in its own logs without parsing the body.
    public static let userAgent = "Manifield-Feedback/1"
}
