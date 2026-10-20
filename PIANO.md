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
| Pulizia disco (cache, log, Download vecchi, Xcode, simulatori, Gradle, npm) | fatto |
| Duplicati (dimensione → impronta parziale → SHA-256; una copia resta sempre) | fatto |
| Stato del sistema (uptime, temperatura, processi più pesanti) | fatto |
| Elementi all'avvio (LaunchAgents/Daemons, sola lettura) | fatto |
| Regole di sicurezza (modificabili dall'app) + registro | fatto |
| Riordina cartelle | v0.2 |
| Assistente AI | v0.3 |

## v0.2 – Riordino cartelle

- Regole del tipo «in Download: PDF → Documenti/PDF, immagini → Immagini/AAAA-MM, `.dmg` più vecchi di 30 giorni → Cestino».
- **Anteprima** di tutti gli spostamenti in una tabella (da → a), deselezionabili uno per uno.
- **Annulla l'ultimo riordino**: ogni spostamento viene salvato nel registro con origine e destinazione.
- Regole pronte per i tuoi casi: cartella OmniNeo (mettere da parte `.claude/worktrees`, `site_backup_*`, gli zip di deploy vecchi), cartella Download, Scrivania.

## v0.3 – Assistente AI (Claude)

- Scegli una cartella. L'app prepara un elenco con percorso relativo, tipo, dimensione, data di creazione, data di ultima apertura e numero di copie. **Non legge il contenuto**, salvo un interruttore esplicito per i singoli file.
- L'AI restituisce proposte strutturate: *elimina / sposta in… / tieni*, ciascuna con un motivo («installer già usato», «copia di …», «export vecchio di 2 anni»).
- Le proposte compaiono come la Pulizia: caselle da spuntare, niente preselezionato per le voci rischiose, conferma finale, Cestino.
- Le regole di sicurezza vengono applicate **prima** di inviare i dati e **di nuovo** prima di agire: un file protetto non può essere proposto né toccato.
- La chiave API sta nel Portachiavi di macOS. Un tetto di spesa per ogni analisi.

## Idee per le versioni successive (da scegliere)

- **Icona nella barra dei menu**: spazio libero e memoria sempre visibili, pulizia rapida.
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
