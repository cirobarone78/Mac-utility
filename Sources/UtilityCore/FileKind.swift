import Foundation

/// Famiglia di un file, ricavata dall'estensione.
public enum FileKind: String, CaseIterable, Sendable {
    case pdf = "PDF"
    case images = "Immagini"
    case video = "Video"
    case audio = "Audio"
    case documents = "Documenti"
    case spreadsheets = "Fogli di calcolo"
    case presentations = "Presentazioni"
    case ebooks = "Libri"
    case archives = "Archivi"
    case installers = "Installer"
    case code = "Codice"
    case other = "Altro"

    static let table: [FileKind: Set<String>] = [
        .pdf: ["pdf"],
        .images: ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "svg", "raw", "cr2", "nef", "dng", "psd"],
        .video: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv"],
        .audio: ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg", "opus"],
        .documents: ["doc", "docx", "pages", "rtf", "txt", "md", "odt"],
        .spreadsheets: ["xls", "xlsx", "numbers", "csv", "ods", "tsv"],
        .presentations: ["ppt", "pptx", "key", "odp"],
        .ebooks: ["epub", "mobi", "azw", "azw3"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
        .installers: ["dmg", "pkg", "mpkg", "apk", "aab", "ipa", "exe", "msi"],
        .code: ["swift", "js", "ts", "py", "php", "html", "css", "json", "xml", "sh", "java", "kt", "c", "h", "cpp", "sql", "yml", "yaml"],
    ]

    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        return table.first { $0.value.contains(ext) }?.key ?? .other
    }
}
