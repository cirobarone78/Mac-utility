# Piano – OmniTools

## Principi

1. **Mai cancellazioni definitive.** Un solo punto del codice rimuove file (`SafeRemover`) e sposta tutto nel Cestino. Ogni operazione va nel registro.
2. **Prima vedi, poi decidi.** Ogni modulo mostra l'elenco con le dimensioni. Si agisce solo su ciò che hai selezionato, dopo una conferma.
3. **Regole tue, non negoziabili.** `regole.json` elenca cartelle e nomi intoccabili. Sono protetti sempre anche la home e le sue cartelle principali, `/Applications` e il sistema. Valgono anche per l'AI.
4. **L'AI propone, tu approvi.** Non agisce mai da sola.
5. **Privacy.** Niente telemetria. All'AI arrivano solo i metadati dei file, salvo tuo permesso esplicito.

## Versione 0.1 (questo commit)

| Modulo | Stato |
|---|---|
| Panoramica (disco, memoria, CPU, batteria, azioni rapide) | fatto |
| Analisi spazio (cartelle per dimensione, navigazione, file grandi) | fatto |
| Pulizia disco (cache, log, Download vecchi, Xcode, simulatori, Gradle, npm), con spiegazione di ogni voce, avviso app aperte e contenuto delle sottocartelle | fatto |
| Duplicati (dimensione → impronta parziale → SHA-256; una copia resta sempre) | fatto |
| Stato del sistema (uptime, temperatura, processi più pesanti) | fatto |
| Elementi all'avvio (LaunchAgents/Daemons, sola lettura) | fatto |
| Regole di sicurezza (modificabili dall'app) + registro | fatto |
| Foto e cloud: doppioni identici e foto simili (impronta visiva) e riordino per anno/mese in iCloud Drive, Google Drive o qualsiasi cartella, con anteprime | fatto |
| Libreria di Foto (iCloud Foto) tramite PhotoKit: stessa foto e foto simili, album «da controllare» o «Eliminati di recente» | fatto |
| WhatsApp: spazio occupato dai media, doppioni, file grandi | prossimo |
| Cronologia con «Ripristina»: ogni pulizia, eliminazione di duplicati e riordino torna com'era in un clic (anche dal Cestino) | fatto |
| Icona nella barra dei menu (disco, memoria, CPU, batteria, pulizia rapida) | fatto |
| Riordina cartelle (per argomento, tipo o mese; file inutili; annulla) | fatto (v0.2) |
| Assistente AI (Claude: proposte di spostamento ed eliminazione, approvate una per una) | fatto (v0.3) |

## v0.2 – Riordino cartelle (fatto)

Si apre una cartella e si guardano **solo i file sfusi** (le sottocartelle esistenti non si toccano).

- **Per argomento**: una parola presente nel nome di almeno 2 file diventa una cartella («Fattura_Enel», «fattura TIM» → *Fatture*; «Schermata…» e «Screenshot…» → *Screenshot*; «OmniNeo_logo», «omnineo-deploy» → *OmniNeo*). I sinonimi più comuni sono uniti. Le parole presenti in quasi tutti i file vengono ignorate, perché sono l'argomento della cartella stessa. I file senza argomento vanno per tipo.
- **Per tipo** (PDF, Immagini, Video, Documenti, Fogli di calcolo, Installer…) o **per mese** (2026-10).
- **File probabilmente inutili** → Cestino. Preselezionati: copie identiche (si tiene il nome «originale»), file vuoti, download incompleti, file di blocco di Office. Da controllare, non preselezionati: installer più vecchi di 30 giorni, archivi già estratti.
- **Anteprima modificabile**: puoi rinominare ogni cartella proposta e togliere la spunta a singoli file.
- **Annulla l'ultimo riordino**: i file tornano al loro posto e le cartelle create, se vuote, vengono tolte (registro in `Application Support/OmniTools/riordini/`). Ciò che è andato nel Cestino si recupera dal Finder.

Limite: senza AI l'argomento si ricava solo dai nomi dei file. Con la v0.3 l'assistente potrà raggruppare anche nomi diversi con lo stesso significato («preventivo idraulico» e «offerta caldaia» → *Casa*) e proporre nomi di cartella migliori.

## v0.3 – Assistente AI (fatto)

- Scegli una cartella. L'app descrive i file sfusi con **solo metadati**: nome, tipo, dimensione, data di creazione e di ultima apertura, più gli indizi dell'analisi locale («copia identica di…», «file vuoto»). Il contenuto non viene mai letto. Il pulsante **«Vedi cosa invio»** mostra il testo esatto.
- I file protetti dalle regole **non vengono inviati** e, se comparissero comunque in una proposta, vengono scartati prima di agire.
- Claude risponde in JSON vincolato a uno schema (`output_config.format`). Per ogni file propone *sposta in…*, *Cestino* o *lascia*, con un motivo e un livello di fiducia. Raggruppa per significato e non solo per nome («preventivo idraulico» + «offerta caldaia» → *Casa*).
- **Nulla è preselezionato per il Cestino.** C'è un pulsante per spuntare solo le eliminazioni a fiducia alta. Gli spostamenti sono preselezionati ma deselezionabili. Si applica solo dopo conferma, e gli spostamenti si annullano da «Riordina cartelle».
- **Indicazioni personali** salvate (es. «non eliminare nulla che riguardi OmniNeo»).
- **Modello**: Claude Opus 5.5 (predefinito), Sonnet 5.5 oppure Haiku 5.5. Con Opus e Sonnet, in caso di rifiuto, il server riprova da solo su un modello alternativo. Il costo stimato è mostrato a fine analisi. Al massimo 400 file per analisi, a gruppi di 120.
- La chiave API sta nel **Portachiavi di macOS** (oppure nella variabile `ANTHROPIC_API_KEY`).

## Idee per le versioni successive (da scegliere)


- **Disinstallazione completa delle app**: trascini un'app e vedi anche preferenze, cache e supporto che lascia in `~/Library`.
- **Mappa grafica del disco** (a riquadri o a cerchi concentrici) al posto dell'elenco.
- **Pulizia per sviluppatori**: trova e pesa le cartelle `node_modules`, `.build`, `build` e `Pods` nei progetti non toccati da mesi; elimina i simulatori non più disponibili (`xcrun simctl delete unavailable`); cache di Homebrew (`brew cleanup`).
- **Promemoria programmati**: «ogni lunedì dimmi se il disco scende sotto i 50 GB».
- **Controllo backup**: data dell'ultimo backup Time Machine e dell'ultimo `git push` dei progetti indicati.
- **Salute del disco e della batteria**: stato SMART, cicli e capacità residua della batteria.
- **Privacy**: svuota la cronologia dei browser e i file recenti, su richiesta.
- **Esportazione in Markdown** del rapporto («cosa ho liberato questo mese»).

## Personalizzazione

- Nome, icona e colore: in `Sources/OmniTools/AppState.swift` (enum `Brand`). Da decidere.
- Regole per le tue cartelle: dall'app (Regole di sicurezza) o in `regole.json`.

## Progetti open source usati come spunto

Servono come riferimento per le idee, non come codice da copiare. Prima di riusare anche una sola riga, controlla la licenza: con GPL o Commons Clause non si può riusare il codice in un'app chiusa o venduta.

| Progetto | Cosa offre di utile | Licenza |
|---|---|---|
| [exelban/stats](https://github.com/exelban/stats) | Monitor di sistema nella barra dei menu (CPU, GPU, RAM, disco, rete, sensori, batteria) | MIT (da ricontrollare) |
| [alienator88/Pearcleaner](https://github.com/alienator88/Pearcleaner) | Disinstallazione completa delle app, ricerca dei file orfani | Apache 2.0 + Commons Clause: vietato monetizzare |
| [tw93/Mole](https://github.com/tw93/Mole) | Pulizia, disinstallazione e analisi del disco da Terminale | da verificare (indicata MIT) |
| [momenbasel/PureMac](https://github.com/momenbasel/PureMac) | Pulizia nativa SwiftUI, pulizia programmata, cache di Xcode e Homebrew | da verificare (indicata MIT) |
| [vashpan/xcode-dev-cleaner](https://github.com/vashpan/xcode-dev-cleaner) | Pulizia mirata di Xcode (DerivedData, archivi, supporto dispositivi) | da verificare |
| [qarmin/czkawka](https://github.com/qarmin/czkawka) | Duplicati, immagini simili, file vuoti e cartelle vuote (Rust) | nucleo MIT; app da verificare |
| GrandPerspective | Mappa a riquadri dello spazio su disco | GPL |
