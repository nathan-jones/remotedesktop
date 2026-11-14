import CoreImage
import CoreVideo
import UIKit

/// A small picture of each saved Mac's screen as it looked at the end of the
/// last session, kept in the caches folder and shown on its card.
enum Thumbnails {
    private static let context = CIContext()

    private static func url(for id: UUID) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(id.uuidString).jpg")
    }

    static func image(for id: UUID) -> UIImage? {
        url(for: id).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    static func save(_ frame: CVPixelBuffer, for id: UUID) {
        guard let url = url(for: id) else { return }
        var image = CIImage(cvPixelBuffer: frame)
        let scale = min(1, 720 / image.extent.width)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = context.createCGImage(image, from: image.extent),
              let data = UIImage(cgImage: rendered).jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete(for id: UUID) {
        if let url = url(for: id) { try? FileManager.default.removeItem(at: url) }
    }
}
