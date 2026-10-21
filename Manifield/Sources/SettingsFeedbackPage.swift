import SwiftUI
import ManifieldDiagnostics

/// Settings → Feedback. The same form the Help menu opens, in the place people look when
/// they are not reporting a crash — which is most of the time.
///
/// Defaults to Idea rather than Bug: a bug already has its own door (Help → "Report a
/// Bug…", where something has just gone wrong and the log should go with it), so the one
/// reached by browsing Settings is more often someone who wants to suggest something. The
/// picker is the first control on the page either way.
struct SettingsFeedbackPage: View {
    var body: some View {
        FeedbackView(kind: .idea)
    }
}
