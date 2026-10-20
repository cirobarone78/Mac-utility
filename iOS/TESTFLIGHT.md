# OmniTools per iPhone su TestFlight

TestFlight installa l'app sul tuo iPhone senza cavo e la aggiorna da solo. Una build dura 90 giorni: basta caricarne una nuova ogni tanto. Per gli **utenti interni** (tu, e chi aggiungi al tuo team) non serve la revisione di Apple.

## Una volta sola

1. **Xcode collegato al tuo account**: Xcode › Impostazioni › Account › il tuo Apple ID con il team dello sviluppatore (lo stesso di OmniNeo).
2. **Crea l'app su App Store Connect** ([appstoreconnect.apple.com](https://appstoreconnect.apple.com)) › App › **+** › Nuova app:
   - Piattaforma: **iOS**
   - Nome: deve essere unico su tutto l'App Store. «OmniTools» quasi certamente è già preso: usa per esempio **«OmniTools Pulizia»** (si può cambiare in seguito; sul telefono comparirà comunque «OmniTools»).
   - Lingua principale: Italiano
   - ID pacchetto (Bundle ID): **app.omnitools.ios**. Se non compare nell'elenco, lancia prima lo script qui sotto una volta (lo registra lui) oppure crealo in developer.apple.com › Identifiers.
   - SKU: un codice qualsiasi, es. `omnitools-ios`
   - Accesso: Accesso completo
3. **Tester interno**: nell'app appena creata › **TestFlight** › Test interni › **+** › crea un gruppo (es. «Io») e aggiungi il tuo account.
4. **Sull'iPhone** installa l'app **TestFlight** dall'App Store.

## A ogni aggiornamento

```bash
cd ~/Documents/Mac-utility
git pull
./scripts/ios-testflight.sh
```

Lo script:
- genera il progetto, archivia l'app in versione Release con un numero di build sempre nuovo;
- la firma con il tuo team (gestione automatica dei certificati);
- la carica su App Store Connect.

Dopo 5-15 minuti di elaborazione da parte di Apple, la build compare in TestFlight e arriva sull'iPhone.

## Se qualcosa va storto

| Messaggio | Cosa fare |
|---|---|
| `No Accounts` / `No signing certificate` | Xcode › Impostazioni › Account: accedi con il tuo Apple ID e premi «Download Manual Profiles» |
| `No profiles for 'app.omnitools.ios'` | Esegui una volta `./scripts/ios-project.sh` e in Xcode › Signing & Capabilities scegli il Team: Xcode registra l'ID |
| `Error Downloading App Information` / app non trovata | Manca il passo 2: crea l'app su App Store Connect con lo stesso Bundle ID |
| `The bundle version must be higher` | Ricarica: lo script usa data e ora come numero di build |
| La build resta «In elaborazione» | Normale per qualche minuto; Apple manda anche un'email quando è pronta |
| «Informazioni sulla conformità all'esportazione mancanti» | Non dovrebbe comparire (è già dichiarato «nessuna crittografia»); se compare rispondi «No» |
