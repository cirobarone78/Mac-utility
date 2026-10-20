import SwiftUI
import UtilityCore

/// Accesso comune a Claude per tutte le schermate (modello scelto e chiave nel Portachiavi).
enum AIEnv {
    static var model: AIModel {
        AIModel(rawValue: UserDefaults.standard.string(forKey: "ai.model") ?? "") ?? .opus
    }
    static var hasKey: Bool { Keychain.readKey()?.isEmpty == false }
    static func client() -> ClaudeClient { ClaudeClient(model: model, apiKey: Keychain.readKey() ?? "") }
}

/// «Chiedi all'AI cos'è»: una sola finestra condivisa, aperta da qualsiasi tasto destro.
@MainActor
final class ExplainCenter: ObservableObject {
    static let shared = ExplainCenter()

    struct Question: Identifiable {
        let id = UUID()
        let subject: String
        var answer: String?
        var error: String?
        var cost: Double = 0
    }

    @Published var current: Question?

    func ask(_ subject: String, context: String) {
        current = Question(subject: subject)
        guard AIEnv.hasKey else {
            current?.error = "Per usare l'AI inserisci la chiave API nella schermata «Assistente AI»."
            return
        }
        let client = AIEnv.client()
        Task {
            do {
                let reply = try await AIExplain.explain(subject, context: context, client: client)
                current?.answer = reply.text
                current?.cost = reply.costUSD
            } catch {
                current?.error = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Aggiunge al menu del tasto destro la voce «Chiedi all'AI cos'è».
    func explainMenu(_ subject: String, context: String) -> some View {
        contextMenu {
            Button("Chiedi all'AI cos'è", systemImage: "sparkles") {
                ExplainCenter.shared.ask(subject, context: context)
            }
        }
    }
}

struct ExplainSheet: View {
    let question: ExplainCenter.Question
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(question.subject, systemImage: "sparkles").font(.headline).foregroundStyle(Brand.accent)
            Group {
                if let a = question.answer {
                    ScrollView { Text(a).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                } else if let e = question.error {
                    Text(e).foregroundStyle(.orange)
                } else {
                    HStack { ProgressView().controlSize(.small); Text("Chiedo a Claude…").foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 80)
            HStack {
                if question.cost > 0 {
                    Text(String(format: "Costo: %.4f $", question.cost)).font(.caption).foregroundStyle(.secondary)
                }
                Text("Le risposte dell'AI possono sbagliare: verifica prima di eliminare.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Chiudi") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 220)
    }
}
