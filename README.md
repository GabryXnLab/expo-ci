# expo-ci

Workflow GitHub Actions riusabili per progetti Expo (Android, arm64-v8a).

> Controparte **desktop**: [`GabryXnLab/desktop-ci`](https://github.com/GabryXnLab/desktop-ci)
> (build Tauri multi-OS/arch). Stesso pattern thin-wrapper + reusable `@main`.

## Workflow disponibili

### `expo-build.yml` — Build APK Android

Supporta build locale su self-hosted runner ARM64 (`nexus-core`) e build cloud EAS.

**Inputs:**

| Input | Tipo | Default | Descrizione |
|---|---|---|---|
| `app_name` | string | — | Nome app (es. `WarpMobile`, `Ascend`) |
| `build_target` | string | — | `local` = nexus-core \| `eas` = cloud Expo |
| `build_profile` | string | `preview` | `development` (assembleDebug, APK) \| `preview` (assembleRelease, APK) \| `production` (bundleRelease, AAB per gli store — usare con `build_target=eas`) |
| `clear_cache` | boolean | `false` | Svuota tutte le cache (node_modules/gradle/ccache/.cxx/metro) |
| `run_prebuild` | boolean | `true` | `true`: `expo prebuild --clean` (rigenera `android/`). `false`: riusa `android/` del run precedente, preservata via checkout `clean=false`. Se `android/` manca comunque, il prebuild parte in automatico (no fail). |
| `has_submodules` | boolean | `false` | Checkout con `submodules: recursive` |
| `has_google_services` | boolean | `false` | Scrive `google-services.json` dal secret |
| `signing_keystore` | string | `''` | Nome del keystore con cui firmare la build **locale**: cercato in `/home/ubuntu/secrets/<nome>.jks` + `.properties` sul runner, o nei secret `ANDROID_KEYSTORE_BASE64`/`ANDROID_KEYSTORE_PROPERTIES`. Vuoto = firma di debug. Dichiarato ma introvabile = build in errore |
| `codegen_tasks` | string | `''` | Task Gradle spazio-separati per pre-generare codegen artifacts |
| `expo_updates_channel` | string | `preview` | Valore `EXPO_UPDATES_CHANNEL` passato a `expo prebuild` |
| `prepare_command` | string | `''` | Comando dopo `pnpm install` e prima di prebuild/upload EAS; riceve `GITHUB_TOKEN` e può materializzare artefatti nativi esterni |

**Secrets:** `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `EXPO_TOKEN`, `GOOGLE_SERVICES_JSON`, `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PROPERTIES`

### `expo-update.yml` — EAS Update (OTA)

Pubblica un aggiornamento OTA senza ricompilare l'APK (solo cambi JS/TS/asset).

**Inputs:**

| Input | Tipo | Default | Descrizione |
|---|---|---|---|
| `app_name` | string | — | Nome app |
| `update_target` | string | — | `local` \| `eas` |
| `branch` | string | — | Canale: `auto` \| `development` \| `preview` \| `production` \| `both` |
| `build_workflow_name` | string | `Manual Build` | Workflow di build interrogato da `branch=auto` |
| `message` | string | `''` | Messaggio update (default: prima riga commit) |
| `clear_cache` | boolean | `false` | Svuota node_modules/.expo/metro cache |
| `skip_typecheck` | boolean | `false` | Salta TypeScript type-check |
| `has_submodules` | boolean | `false` | Checkout con `submodules: recursive` |

**Secrets:** `EXPO_TOKEN`, `SUBMODULES_TOKEN`

**Scelta canale (`branch`):** `auto` = canale dell'ultima build riuscita (dedotto dal `run-name`
del workflow di build); `both` = pubblica su `development` + `preview`; o canale esplicito.
Il wrapper deve concedere `permissions: actions: read` (serve a `branch=auto`) e impostare un
`run-name` contenente la parola del profilo nel proprio workflow di build. Dettagli in `CLAUDE.md`.

## Utilizzo nei progetti

```yaml
# .github/workflows/manual-eas-build.yml
name: Manual Build
on:
  workflow_dispatch:
    inputs:
      build_target: { required: true, default: local, type: choice, options: [local, eas] }
      # ... altri input specifici del progetto

jobs:
  build:
    uses: GabryXnLab/expo-ci/.github/workflows/expo-build.yml@main
    with:
      app_name: MyApp
      build_target: ${{ inputs.build_target }}
      build_profile: preview
      has_submodules: false
      has_google_services: true
      codegen_tasks: ':my-package:generateCodegenArtifactsFromSchema'
      prepare_command: 'bash scripts/prepare-native-artifacts.sh'
    # ⚠️ NON usare `secrets: inherit`: propaga i secret SOLO se il repo chiamante
    # è nella STESSA org/account della reusable workflow. Da un altro owner i secret
    # arrivano VUOTI e la build fallisce (es. "google-services.json not found").
    # Passa sempre i secret esplicitamente per nome — funziona in ogni caso:
    secrets:
      GOOGLE_SERVICES_JSON: ${{ secrets.GOOGLE_SERVICES_JSON }}
      EXPO_TOKEN: ${{ secrets.EXPO_TOKEN }}
      TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
      TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
```

### Firma delle build locali (`signing_keystore`)

`expo prebuild` genera sempre un `debug.keystore` e il buildType `release` lo eredita: una
build locale "release" esce firmata con l'**impronta di debug**, quella pubblica del template.
Per la maggior parte delle app non cambia nulla — ma per Google Sign-In (e per ogni servizio
che verifica *package + SHA-1* del chiamante) quell'impronta **è** l'identità dell'app: con
quella sbagliata il login risponde `DEVELOPER_ERROR` anche se client id, secret e backend sono
perfetti, e l'artefatto non si distingue a occhio da uno giusto.

Con `signing_keystore: <nome>` il job locale firma con il keystore vero, tenendo la build sul
runner privato:

- il keystore sta sul runner in `/home/ubuntu/secrets/<nome>.jks`, con accanto
  `<nome>.properties` (`storePassword`, `keyAlias`, `keyPassword`), entrambi `chmod 600` —
  così **non passa dai secret di GitHub** e non lascia la macchina;
- in alternativa (runner cloud) si usano i secret `ANDROID_KEYSTORE_BASE64` (il `.jks` in
  base64) e `ANDROID_KEYSTORE_PROPERTIES` (le tre righe del `.properties`);
- la firma passa dalle proprietà `-Pandroid.injected.signing.*` di AGP: nessuna modifica a
  `build.gradle`, che il prebuild rigenera comunque a ogni run;
- **dichiarato ma introvabile è un errore**, non un ritorno silenzioso alla firma di debug: un
  fallback qui produrrebbe proprio l'artefatto che sembra buono e fallisce sul dispositivo;
- dopo la build l'impronta dell'APK viene **confrontata** con quella del keystore (`apksigner`
  contro `keytool`): se non coincidono il job fallisce.

Per usare lo stesso keystore di EAS (stessa identità d'app fra build locali e cloud) lo si
esporta una volta sola con `eas credentials` → *Download keystore*.

### google-services su EAS cloud (`build_target: eas`)

EAS archivia per default **solo i file tracciati da git**. Se `google-services.json`
è in `.gitignore`, lo step che lo scrive in CI non basta: il file non finisce nel
tarball inviato ai server EAS. Soluzioni:

- **`eas secret:create --scope project --name GOOGLE_SERVICES_JSON --type file --value ./google-services.json`** (consigliato), oppure
- un `.easignore` che includa esplicitamente `!google-services.json`.

Sul runner **locale** (`build_target: local`) questo problema non esiste: il file
viene scritto e letto dallo stesso filesystem durante `expo prebuild`.

Lo stesso vincolo vale per file prodotti da `prepare_command`: se sono ignorati da Git e la
build usa EAS cloud, il progetto consumatore deve reincluderli esplicitamente in `.easignore`.

## Infrastruttura

- Runner self-hosted: `nexus-core` (ARM64 Linux, OCI)
- Android SDK: `/opt/android-sdk`
- NDK: `27.3.13750724` a `/opt/android-sdk/ndk/27.3.13750724`
- cmake ARM64 nativo: `/home/ubuntu/cmake-native`
- Java: OpenJDK 17 ARM64
