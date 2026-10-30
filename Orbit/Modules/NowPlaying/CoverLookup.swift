import AppKit

/// Some players hand Now Playing a small cover (a browser passes on the page's thumbnail), which turns
/// to mush on a big widget. This finds the same song in Apple's catalog and takes its cover, large.
/// Only the title and artist go out, and only when the cover that came is small.
enum CoverLookup {
    /// Pixels across below which a cover is worth replacing: a 190 pt cover on a Retina screen is 380.
    static let minimumSide = 500

    static func isSmall(_ image: NSImage) -> Bool {
        let side = image.representations.map { min($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        return side > 0 && side < minimumSide
    }

    static func sharper(title: String, artist: String, album: String) async -> NSImage? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        // The user's own store first, which has local songs under their own names (Korea's only
        // answers for "musicTrack"); then the US one, which has nearly everything.
        let region = Locale.current.region?.identifier ?? "US"
        for (country, entity) in [(region, "musicTrack"), ("US", "song")] {
            if let url = await artwork(title: title, artist: artist, album: album, country: country, entity: entity),
               let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) {
                return image
            }
            if country == "US" { break }
        }
        return nil
    }

    private static func artwork(title: String, artist: String, album: String, country: String, entity: String) async -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [
            URLQueryItem(name: "term", value: "\(clean(artist)) \(clean(title))"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country),
        ]
        guard let url = c.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let results = (try? JSONDecoder().decode(Response.self, from: data))?.results else { return nil }
        let t = key(title), a = key(artist), al = key(album)
        let matches = results.filter { r in
            let rt = key(r.trackName ?? ""), ra = key(r.artistName ?? "")
            return !rt.isEmpty && !ra.isEmpty && (rt == t || t.hasPrefix(rt) || rt.hasPrefix(t))
                && (ra.contains(a) || a.contains(ra))
        }
        // The same album first: a single and the album it's on can have different covers.
        guard let best = matches.first(where: { !al.isEmpty && key($0.collectionName ?? "") == al }) ?? matches.first,
              let small = best.artworkUrl100 else { return nil }
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb"))
    }

    private struct Response: Decodable { let results: [Result] }
    private struct Result: Decodable {
        let trackName, artistName, collectionName, artworkUrl100: String?
    }

    /// The title without what video sites add: "(Official Video)", "[MV]", "- Remastered 2011".
    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .components(separatedBy: " - ").first ?? s
    }

    /// Lowercased letters and digits only, for comparing names written slightly differently.
    private static func key(_ s: String) -> String {
        String(clean(s).lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
