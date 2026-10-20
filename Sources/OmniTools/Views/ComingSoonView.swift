import SwiftUI

struct ComingSoonView: View {
    let module: Module

    private var text: String {
        switch module {
        case .organize:
            "Riordina una cartella secondo regole tue (per tipo, per data, per progetto). Prima mostra l'anteprima di ogni spostamento, poi agisce solo su conferma. Ogni riordino si può annullare."
        case .assistant:
            "L'assistente AI guarda nomi, tipi, dimensioni e date dei file (non il contenuto, salvo tuo permesso) e propone cosa eliminare o spostare, spiegando perché. Non agisce mai da solo: approvi tu ogni voce, e tutto va nel Cestino."
        default: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModuleHeader(module: module, subtitle: "Prossima versione")
            Text(text).font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(20)
            Spacer()
        }
    }
}
