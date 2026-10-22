# OmniTools

Una cassetta degli attrezzi per macOS, in stile Norton Utilities ma su misura: pulizia, analisi dello spazio, riordino delle cartelle, duplicati, stato del sistema, elementi all'avvio e un assistente AI (Claude) che propone cosa spostare o eliminare e chiede sempre prima.

**Regola d'oro: l'app non cancella mai nulla in modo definitivo.** Ogni rimozione passa per il Cestino, dopo una tua conferma, e viene scritta nel registro.

## Installazione

Serve un Mac con macOS 14 (Sonoma) o successivo e gli strumenti di sviluppo Apple (Xcode, oppure solo `xcode-select --install`).

```bash
cd ~/Documents
git clone -b claude/elegant-clarke-f2mj1a https://github.com/cirobarone78/Mac-utility.git
cd Mac-utility
./scripts/build-app.sh --install
```

Lo script compila, crea `OmniTools.app` con la sua icona, la firma localmente, la copia in **Applicazioni** e la apre. Per aggiornarla: `git pull` e di nuovo `./scripts/build-app.sh --install`.

Per sviluppare: `open Package.swift` (si apre in Xcode, schema «OmniTools», poi ⌘R) e `swift test` per i test.

### Assistente AI

Serve una chiave API di Anthropic (console.anthropic.com → API Keys): la si inserisce nella schermata «Assistente AI» e resta nel Portachiavi del Mac. In alternativa, la variabile `ANTHROPIC_API_KEY` impostata nello schema di Xcode. All'AI arrivano solo i metadati dei file (nome, tipo, dimensione, date), mai il contenuto.

### Protezione (senza antivirus)

- **Disinstalla app**: toglie l'app con i file che lascia nella Libreria (preferenze, cache, contenitori, avvio automatico) e trova gli avanzi di app già cancellate. Le app di Apple e l'Xcode in uso non si toccano.
- **Aggiornamenti**: confronta le versioni installate con App Store, aggiornamenti delle app (Sparkle), Homebrew e macOS. Non installa nulla da solo.
- **Backup**: controlla Time Machine (ultimo backup, backup automatici, cartelle escluse, spazio sul disco).
- **Privacy**: chi ha fotocamera, microfono, schermo e Accesso completo al disco, con il pulsante per togliere il permesso; cronologia e cookie dei browser, sito per sito (il browser va chiuso; i file originali vanno nel Cestino, quindi «Ripristina» funziona).
- **Seconda opinione**: confronta l'impronta di un file con VirusTotal (circa 70 antivirus). Serve una chiave gratuita; il file non lascia il Mac.
- **Furti di dati**: controlla una password con Have I Been Pwned (gratis e anonimo) e, con la chiave a pagamento, il tuo indirizzo email.

- **Fotocamera e microfono**: notifica quando si accendono, simbolo accanto all'icona nella barra dei menu e registro di chi li ha usati.
- **Cassaforte**: immagine disco cifrata AES-256 (strumento `hdiutil` di macOS) con password; OmniTools non la conserva.

### Altri strumenti

- **Rete e Wi-Fi**: segnale, rumore, canale, banda, protezione, velocità del collegamento al router, traffico in tempo reale, IP, router, DNS, VPN e proxy; test di velocità con `networkQuality` di Apple (download, upload, latenza, reattività), latenza e pacchetti persi verso router e internet, tempo del DNS, cronologia; reti vicine e affollamento dei canali; app collegate a internet e dispositivi sulla rete; consigli. Il nome della rete richiede il permesso Localizzazione (regola di macOS).
- **Batteria**: capacità massima, cicli, condizione, temperatura, potenza, alimentatore e app che consumano di più; stato del limite di carica di macOS (26.4 e successivi), abitudini di carica dell'ultima settimana e consiglio di impostarlo all'80% se il Mac sta quasi sempre collegato.
- **Manutenzione automatica**: ogni giorno, settimana o mese controlla spazio da liberare, aggiornamenti, backup, disco e batteria e manda una notifica. Non cancella e non installa nulla.

Le chiavi di VirusTotal e Have I Been Pwned stanno nel Portachiavi, come quella di Anthropic.

### Accesso completo al disco

Per misurare anche le cartelle protette da macOS (Mail, Messaggi, alcune cache), aggiungi l'app (o Xcode/Terminale, se la lanci da lì) in **Impostazioni di Sistema › Privacy e sicurezza › Accesso completo al disco**. Senza, quelle cartelle vengono semplicemente saltate.

## Icona

L'icona sta in `Assets/`: il disegno vettoriale `AppIcon.svg`, il PNG da 1024 px e la cartella `AppIcon.iconset` con tutte le misure. Quando l'app sarà impacchettata come `.app`, il file `.icns` si crea sul Mac con:

```bash
iconutil -c icns Assets/AppIcon.iconset -o Assets/AppIcon.icns
```

## Struttura

| Cartella | Contenuto |
|---|---|
| `Sources/UtilityCore` | Logica senza interfaccia: regole di sicurezza, scansione del disco, catalogo pulizia, duplicati, Cestino e registro, elementi all'avvio |
| `Sources/OmniTools` | App SwiftUI: barra laterale e una schermata per modulo |
| `Tests/UtilityCoreTests` | Test del nucleo |

File dell'app sul Mac: `~/Library/Application Support/OmniTools/regole.json` (cosa non toccare mai) e `registro.log` (ogni file spostato nel Cestino).

Il piano completo e le idee per le prossime versioni sono in [PIANO.md](PIANO.md).

## App per iPhone

Nella cartella `iOS/`: doppioni e foto simili nel rullino (iCloud Foto) e nelle cartelle di File/iCloud Drive, riordino per anno e mese. Usa lo stesso motore dell'app per Mac (`UtilityCore`).

```bash
./scripts/ios-project.sh     # installa XcodeGen se manca, genera il progetto e lo apre in Xcode
```

In Xcode: collega l'iPhone, sceglilo come destinazione in alto e premi ⌘R. La prima volta, sull'iPhone: Impostazioni › Generali › VPN e gestione dispositivi › autorizza lo sviluppatore, e attiva la Modalità sviluppatore se richiesta.

Per installarla senza cavo e aggiornarla da sola: TestFlight, vedi [iOS/TESTFLIGHT.md](iOS/TESTFLIGHT.md) (`./scripts/ios-testflight.sh`).
