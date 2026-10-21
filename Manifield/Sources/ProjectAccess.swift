import Foundation

/// Telling "macOS will not let this app look" apart from every other reason opening a
/// project can fail.
///
/// The distinction is load-bearing. Manifield is not sandboxed, but macOS still guards
/// `~/Documents` through TCC, and that grant is keyed to the app's code signature: it can
/// be refused at the first-launch prompt, revoked in System Settings, reset when the
/// signature changes, or simply absent on a new Mac. Choosing a folder in `NSOpenPanel`
/// hands the app a per-path grant of its own, independent of the Documents grant — which
/// is why "Open Project…" keeps working on the very folder a click in Recent projects
/// fails on.
///
/// So a denial is the one open failure the app can talk its way out of, by sending the
/// user back through the panel. Every other failure must keep its own message: offering to
/// "grant access" for a corrupt `project.json` would be worse than saying nothing.
enum ProjectAccess {

    /// Whether `error` is the system refusing access, rather than the file being absent,
    /// malformed, or anything else.
    ///
    /// Pure, and deliberately so. TCC cannot be revoked from a test, so the judgement
    /// itself is the only part of this that can be checked — against errors built by hand.
    static func isPermissionDenied(_ error: Error, depth: Int = 0) -> Bool {
        let nsError = error as NSError
        switch nsError.domain {
        case NSCocoaErrorDomain where nsError.code == NSFileReadNoPermissionError:
            return true
        case NSPOSIXErrorDomain where nsError.code == Int(EACCES) || nsError.code == Int(EPERM):
            return true
        default:
            break
        }
        // Foundation carries the errno it got under `NSUnderlyingErrorKey`, and not every
        // layer restates it as a Cocoa code on the way up. One step down is where a denial
        // that arrived as `EPERM` from `open(2)` is still recognisable. Bounded, because
        // the chain is data and a cycle in it must not become a hang.
        guard depth < 4, let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isPermissionDenied(underlying, depth: depth + 1)
    }

    /// What to tell the user when the folder is walled off.
    ///
    /// The raw Cocoa sentence — *The file "project.json" couldn't be opened because you
    /// don't have permission to view it.* — names a file the user never chose and offers
    /// nothing to do about it. This says which folder, and what the next button will do.
    static func permissionMessage(for url: URL) -> String {
        """
        Manifield doesn't have permission to read "\(url.lastPathComponent)".

        macOS grants an app access to a folder when you choose that folder yourself, and \
        opening a recent project never asks. Choose this folder to grant access, and \
        Manifield will open it.
        """
    }

    /// Whether a remembered project is genuinely gone — the only reason to drop it from
    /// Recent projects.
    ///
    /// `FileManager.fileExists` answers `false` both for "the folder was moved or deleted"
    /// and for "macOS will not let this app look", and those must not be treated alike. A
    /// folder that is only walled off is one open-panel click from working again, and
    /// silently removing its row would take away the only route back to a project the user
    /// has opened before. `checkResourceIsReachable` reports *why* it cannot see the
    /// folder, which is what keeps the two cases apart.
    static func isMissing(_ url: URL) -> Bool {
        do {
            return try url.checkResourceIsReachable() == false
        } catch {
            return !isPermissionDenied(error)
        }
    }
}
