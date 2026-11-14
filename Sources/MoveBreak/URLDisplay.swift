import Foundation

/// Privacy-preserving URL formatter for logs, console diagnostics, and probe output.
/// Output is host-only by default; path, port, userinfo, query and fragment appear
/// only with explicit `verbose`, which returns the full URL.
enum URLDisplay {

    /// Formats a URL for display: host only by default, or the full URL
    /// when `verbose` is true.
    static func sanitize(_ url: String?, verbose: Bool = false) -> String {
        guard let url, !url.isEmpty else { return "‹none›" }
        if verbose { return url }

        let comps = URLComponents(string: url) ?? URLComponents(string: "https://" + url)
        guard let components = (comps?.host != nil ? comps : URLComponents(string: "https://" + url)),
              let host = components.host else {
            return "‹unparseable›"
        }

        return host
    }
}
