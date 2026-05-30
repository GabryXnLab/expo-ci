# expo-ci

Workflow GitHub Actions riusabili per progetti Expo (Android, arm64-v8a).

## Workflow disponibili

### `expo-build.yml` — Build APK Android

Supporta build locale su self-hosted runner ARM64 (`nexus-core`) e build cloud EAS.

**Inputs:**

| Input | Tipo | Default | Descrizione |
|---|---|---|---|
| `app_name` | string | — | Nome app (es. `WarpMobile`, `Ascend`) |
| `build_target` | string | — | `local` = nexus-core \| `eas` = cloud Expo |
| `build_profile` | string | `preview` | `development` (assembleDebug) \| `preview` (assembleRelease) |
| `clear_cache` | boolean | `false` | Svuota tutte le cache (node_modules/gradle/ccache/.cxx/metro) |
| `run_prebuild` | boolean | `true` | Esegui `expo prebuild --clean` |
| `has_submodules` | boolean | `false` | Checkout con `submodules: recursive` |
| `has_google_services` | boolean | `false` | Scrive `google-services.json` dal secret |
| `codegen_tasks` | string | `''` | Task Gradle spazio-separati per pre-generare codegen artifacts |
| `expo_updates_channel` | string | `preview` | Valore `EXPO_UPDATES_CHANNEL` passato a `expo prebuild` |

**Secrets:** `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `EXPO_TOKEN`, `GOOGLE_SERVICES_JSON`

### `expo-update.yml` — EAS Update (OTA)

Pubblica un aggiornamento OTA senza ricompilare l'APK (solo cambi JS/TS/asset).

**Inputs:**

| Input | Tipo | Default | Descrizione |
|---|---|---|---|
| `app_name` | string | — | Nome app |
| `update_target` | string | — | `local` \| `eas` |
| `branch` | string | — | Branch EAS Update (`development`, `preview`, `production`) |
| `message` | string | `''` | Messaggio update (default: prima riga commit) |
| `clear_cache` | boolean | `false` | Svuota node_modules/.expo/metro cache |
| `skip_typecheck` | boolean | `false` | Salta TypeScript type-check |
| `has_submodules` | boolean | `false` | Checkout con `submodules: recursive` |

**Secrets:** `EXPO_TOKEN`

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
    uses: GabryXn/expo-ci/.github/workflows/expo-build.yml@main
    with:
      app_name: MyApp
      build_target: ${{ inputs.build_target }}
      build_profile: preview
      has_submodules: false
      has_google_services: true
      codegen_tasks: ':my-package:generateCodegenArtifactsFromSchema'
    secrets: inherit
```

## Infrastruttura

- Runner self-hosted: `nexus-core` (ARM64 Linux, OCI)
- Android SDK: `/opt/android-sdk`
- NDK: `27.3.13750724` a `/opt/android-sdk/ndk/27.3.13750724`
- cmake ARM64 nativo: `/home/ubuntu/cmake-native`
- Java: OpenJDK 17 ARM64
