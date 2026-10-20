import SwiftUI

@main
struct OmniToolsiOSApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                LibraryScreen()
                    .tabItem { Label("Foto", systemImage: "photo.stack") }
                FoldersScreen()
                    .tabItem { Label("Cartelle", systemImage: "folder") }
                InfoScreen()
                    .tabItem { Label("Info", systemImage: "info.circle") }
            }
            .tint(Theme.accent)
        }
    }
}

/// Colori di OmniNeo, con variante chiara e scura.
enum Theme {
    static let accent = Color(light: 0x0F766E, dark: 0x2DD4C8)
    static let background = Color(light: 0xEEF2F6, dark: 0x04070F)
    static let card = Color(light: 0xFFFFFF, dark: 0x0C1628)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct InfoScreen: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Cosa fa") {
                    Text("**Foto**: trova la stessa foto salvata più volte e le foto molto simili (copie di WhatsApp, raffiche, versioni ridimensionate) nel rullino e in iCloud Foto.")
                    Text("**Cartelle**: doppioni e riordino per anno e mese in una cartella di File o di iCloud Drive che scegli tu.")
                }
                Section("Sicurezza") {
                    Text("Nulla viene eliminato senza la tua conferma. Le foto eliminate restano in «Eliminati di recente» di Foto per 30 giorni; i file in «Eliminati di recente» dell'app File.")
                    Text("L'analisi usa le miniature già sul telefono: non scarica gli originali da iCloud e non invia nulla a nessuno.")
                }
                Section("WhatsApp") {
                    Text("iOS non permette a nessuna app di leggere i file di WhatsApp. Per liberare spazio lì: WhatsApp › Impostazioni › Spazio e dati › Gestisci spazio. Le foto che WhatsApp salva nel rullino invece le trova la sezione Foto.")
                }
            }
            .navigationTitle("OmniTools")
        }
    }
}

/// Etichetta colorata piccola.
struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Riferimento debole passabile ai thread in background (per i messaggi di avanzamento).
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// Miniatura quadrata selezionabile, comune alle due sezioni.
struct SelectableTile: View {
    let image: UIImage?
    let isBest: Bool
    let isSelected: Bool
    let caption: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary).overlay(ProgressView())
                    }
                }
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.red : (isBest ? Theme.accent : .clear), lineWidth: 3))
                .opacity(isSelected ? 0.55 : 1)

                Image(systemName: isSelected ? "trash.circle.fill" : (isBest ? "star.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundStyle(isSelected ? .red : (isBest ? Theme.accent : .white))
                    .shadow(radius: 2)
                    .padding(5)
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 104)
        .contentShape(Rectangle())
    }
}
