import Foundation

/// Privacy-preserving URL formatter for logs, console diagnostics, and probe output.
/// Keeps host-level output by default to prevent accidental leakage of sensitive tokens
/// or browsing history, requiring explicit verbose mode for full URLs.
enum URLDisplay {

    /// Formats a URL for display: host + first path segment by default, or the full URL
    /// when `verbose` is true.
    static func sanitize(_ url: String?, verbose: Bool = false) -> String {
        guard let url, !url.isEmpty else { return "‹none›" }
        if verbose { return url }

        let comps = URLComponents(string: url) ?? URLComponents(string: "https://" + url)
        guard let components = (comps?.host != nil ? comps : URLComponents(string: "https://" + url)),
              let host = components.host else {
            return "‹unparseable›"
        }

        let segments = components.path.split(separator: "/")
        let firstSegment = segments.first.map { "/\($0)" } ?? ""
        let ellipsis = segments.count > 1 ? "/…" : ""
        return host + firstSegment + ellipsis
    }
}
