# Mac Utility

Una cassetta degli attrezzi per macOS, in stile Norton Utilities ma su misura: pulizia, analisi dello spazio, duplicati, stato del sistema, elementi all'avvio. In arrivo: riordino delle cartelle e un assistente AI che propone cosa eliminare (e chiede sempre prima).

**Regola d'oro: l'app non cancella mai nulla in modo definitivo.** Ogni rimozione passa per il Cestino, dopo una tua conferma, e viene scritta nel registro.

## Avvio

Serve un Mac con macOS 14 (Sonoma) o successivo e Xcode 15 o successivo.

```bash
git clone https://github.com/cirobarone78/Mac-utility.git
cd Mac-utility
open Package.swift      # si apre in Xcode: schema "MacUtility", poi ⌘R
```

Oppure da Terminale: `swift run MacUtility` (finestra) e `swift test` (test del nucleo).

### Accesso completo al disco

Per misurare anche le cartelle protette da macOS (Mail, Messaggi, alcune cache), aggiungi l'app (o Xcode/Terminale, se la lanci da lì) in **Impostazioni di Sistema › Privacy e sicurezza › Accesso completo al disco**. Senza, quelle cartelle vengono semplicemente saltate.

## Struttura

| Cartella | Contenuto |
|---|---|
| `Sources/UtilityCore` | Logica senza interfaccia: regole di sicurezza, scansione del disco, catalogo pulizia, duplicati, Cestino e registro, elementi all'avvio |
| `Sources/MacUtility` | App SwiftUI: barra laterale e una schermata per modulo |
| `Tests/UtilityCoreTests` | Test del nucleo |

File dell'app sul Mac: `~/Library/Application Support/MacUtility/regole.json` (cosa non toccare mai) e `registro.log` (ogni file spostato nel Cestino).

Il piano completo e le idee per le prossime versioni sono in [PIANO.md](PIANO.md).
