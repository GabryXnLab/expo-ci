# CLAUDE.md — expo-ci

Reusable GitHub Actions workflows per build APK e update OTA di app Expo (React Native).
Centralizza la CI/CD condivisa tra più progetti (**WarpMobile**, **Ascend**, …).
Vedi anche `README.md` per l'overview d'uso.

## ⚠️ Impatto delle modifiche: @main è live per tutti

I progetti richiamano questi workflow come reusable via `uses: GabryXnLab/expo-ci/...@main`.
**Ogni push su `main` ha effetto immediato su TUTTI i progetti** al loro prossimo run.
Non esiste pinning per SHA lato consumatori: una modifica rotta qui rompe tutti i progetti.
→ Mantenere gli input **retrocompatibili** (nuovi input con `default`, mai rimuovere/rinominare
input esistenti senza aggiornare ogni wrapper). Validare lo YAML prima di pushare.

## Workflow

### `expo-build.yml` — build Android (APK arm64-v8a / AAB)
- `build_target`: `local` (self-hosted nexus-core ARM64, Gradle nativo) | `eas` (cloud).
- `build_profile`: `development` (`assembleDebug` + dev client, APK) | `preview` (`assembleRelease`,
  APK) | `production` (`bundleRelease`, **AAB** per gli store). Per `production` usare
  `build_target=eas`: la firma usa il keystore gestito da Expo (il `bundleRelease` locale è
  firmato col keystore del prebuild → ok per ispezione, NON per upload sullo store).
- `expo_updates_channel`: valore passato a `expo prebuild` → **determina il channel OTA che
  l'APK ascolterà**. Deve combaciare col branch su cui si pubblicheranno gli update.
- `codegen_tasks`: pre-genera artifact codegen Fabric prima di `assembleRelease` (race tra
  `:app:configureCMake` e `generateCodegenArtifacts` in release; in debug non serve).
- Cose non ovvie del job locale: patch NDK aarch64 nativo (evita QEMU, ~1h→~15min), Hermes
  forzato a `linux64-bin` su aarch64, notifica Telegram **best-effort** (non fallisce il job).

### `expo-update.yml` — EAS Update OTA (JS/TS-only)
Non ricompila nativo. Input `branch`: `auto | development | preview | production | both`.

## Risoluzione canale (`branch`) — job `resolve`

La logica di scelta canale è **centralizzata qui** (job `resolve` + matrix), non nei wrapper,
così è coerente tra tutti i progetti.

- `both` → matrix `["development","preview"]`.
- esplicito → matrix con quel solo canale.
- `auto` → deduce il canale dall'**ultima build riuscita** del repo chiamante, leggendone il
  `run-name` (`displayTitle`). Match su `*preview*` / `*development*` / `*production*`;
  fallback a `preview` se non deducibile.
  - Il nome del workflow di build da interrogare è l'input `build_workflow_name` (default
    `Manual Build`).

### ⚠️ Insidie scoperte su `auto`

1. **`gh run list --workflow <name> --status success` è inaffidabile**: in alcune versioni di
   `gh` ritornava vuoto. Soluzione adottata: scaricare la lista piena
   (`--json workflowName,conclusion,displayTitle`) e **filtrare lato client con `jq`**
   (`select(.workflowName==... and .conclusion=="success")`). Più robusto.
2. **Il `run-name` lo deve impostare il wrapper**, non il reusable: un reusable non può
   impostare il `run-name` del run top-level. Documentare nei progetti consumatori che il loro
   workflow di build deve avere un `run-name` contenente la parola del profilo, altrimenti
   `auto` cade sempre nel fallback `preview`.
3. Il job `resolve` richiede `permissions: actions: read`, e il **wrapper** deve concederlo
   (`permissions: actions: read` a livello di workflow chiamante).

## Coerenza build ↔ update (regola per i consumatori)

Un APK ascolta il channel = `build_profile` con cui è stato buildato; un update lo raggiunge solo
se pubblicato sul **branch omonimo** e con **runtimeVersion** combaciante (policy `appVersion`).
Cambi nativi/SDK ⇒ nuova **build**, non update. (Lato app, ricordare che con
`checkAutomatically: "NEVER"` il check va invocato a mano: vedi i consumatori.)

## Convenzioni

- Package manager **pnpm** (mai npm/yarn). Node 22, pnpm 10.33.0. Lock file committati.
- Build locali **arm64-v8a only**.
- Secret passati **per nome** dai wrapper (non `inherit`, inaffidabile cross-repo).
- `SUBMODULES_TOKEN`: PAT org-wide read-only Contents per submodule privati cross-repo
  (il `GITHUB_TOKEN` di default è scoped al solo repo in build). Fallback a `github.token`.
