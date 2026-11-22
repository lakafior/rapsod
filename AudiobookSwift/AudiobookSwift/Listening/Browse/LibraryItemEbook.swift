import SwiftUI

extension AudiobookshelfClient.LibraryItem {
    /// Książka bez plików audio, z samym e-bookiem — główną akcją jest „Czytaj”, nie „Odtwarzaj”.
    var isEbookOnly: Bool { !isPodcast && (media.numTracks ?? 1) == 0 && media.ebookFormat != nil }
}
