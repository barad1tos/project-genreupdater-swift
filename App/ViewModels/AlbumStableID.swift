extension AlbumSummary {
    static func makeID(artist: String, name: String) -> String {
        let artistByteCount = artist.utf8.count
        let nameByteCount = name.utf8.count
        return "\(artistByteCount):\(artist)\(nameByteCount):\(name)"
    }
}
