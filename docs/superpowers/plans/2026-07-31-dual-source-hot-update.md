# DreamMangaReader Dual-Source Hot Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Gitee-first, GitHub-fallback in-app updater for Windows and Android, plus safe local scripts that package both platforms and publish only to the authorized Gitee Release repository.

**Architecture:** Split the current updater into pure release/manifest models, source-specific API clients, a dual-source resolver, a resumable verified downloader, and narrow platform installers. Local scripts and GitHub Actions emit the same manifest and attachment contract; local publishing writes only Gitee, while the author retains GitHub publishing control.

**Tech Stack:** Flutter 3.44, Dart 3.12, Dio, SharedPreferences, Kotlin platform channels, Inno Setup 6, PowerShell 7, Gitee API v5, GitHub Actions.

---

## File Structure

- `lib/core/update/update_models.dart`: source, release, asset and manifest models.
- `lib/core/update/update_release_client.dart`: GitHub/Gitee API adapters and parsers.
- `lib/core/update/update_resolver.dart`: source ordering, fallback and version selection.
- `lib/core/update/update_asset_selector.dart`: Windows installer and Android ABI selection.
- `lib/core/update/update_downloader.dart`: resume, size/SHA-256 verification and cache cleanup.
- `lib/core/update/android_abi.dart`: injected ABI provider and Android method channel.
- `lib/core/update/update_installer.dart`: platform installer launch behavior only.
- `lib/core/update/update_service.dart`: UI facade and update dialog.
- `Scripts/Release.Common.ps1`: pure release-contract helpers.
- `Scripts/检查发布环境.ps1`: read-only prerequisite checks.
- `Scripts/打包新版本.ps1`: Windows/Android packaging.
- `Scripts/发布到Gitee.ps1`: safe Gitee-only publishing.
- `Scripts/打包并发布Gitee.ps1`: composed daily entrypoint.

## Task 1: Pure Update Models and Manifest Validation

**Files:**
- Create: `lib/core/update/update_models.dart`
- Create: `test/update_models_test.dart`
- Modify: `lib/core/update/update_installer.dart`
- Modify: `lib/core/update/update_service.dart`

- [ ] **Step 1: Write the failing manifest tests**

```dart
import 'dart:convert';
import 'package:dream_manga_reader/core/update/update_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const remote = [RemoteAsset(
    name: 'DreamMangaReader-windows-x64-setup.exe',
    url: 'https://example/setup.exe',
    size: 42,
  )];

  test('validates manifest and resolves URL by basename', () {
    final manifest = UpdateManifest.fromJson(jsonDecode('''
      {"schemaVersion":1,"appId":"DreamMangaReader","version":"1.3.1",
       "channel":"stable","releaseNotes":"notes","requiresRestart":true,
       "assets":[{"platform":"windows","arch":"x64","kind":"installer",
       "fileName":"DreamMangaReader-windows-x64-setup.exe",
       "sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
       "sizeBytes":42}]}
    ''') as Map<String, dynamic>);
    expect(manifest.resolve(remote).single.url, 'https://example/setup.exe');
  });

  test('rejects path traversal, wrong app and unsupported schema', () {
    Map<String, dynamic> validAsset(String name) => {
      'platform': 'windows', 'arch': 'x64', 'kind': 'installer',
      'fileName': name, 'sha256': 'a' * 64, 'sizeBytes': 42,
    };
    expect(() => UpdateManifest.fromJson({
      'schemaVersion': 1, 'appId': 'DreamMangaReader', 'version': '1.3.1',
      'channel': 'stable', 'assets': [validAsset('../setup.exe')],
    }), throwsFormatException);
    expect(() => UpdateManifest.fromJson({
      'schemaVersion': 2, 'appId': 'DreamMangaReader', 'version': '1.3.1',
      'channel': 'stable', 'assets': [validAsset('setup.exe')],
    }), throwsFormatException);
  });
}
```

- [ ] **Step 2: Run `flutter test test/update_models_test.dart`**

Expected: FAIL because `update_models.dart` does not exist.

- [ ] **Step 3: Implement the pure contracts and strict parser**

```dart
enum UpdateSource { gitee, github }
enum UpdateIntegrity { manifest, legacy }
enum UpdatePlatform { windows, android }

extension UpdateSourceInfo on UpdateSource {
  String get displayName => this == UpdateSource.gitee ? 'Gitee' : 'GitHub';
  UpdateSource get fallback =>
      this == UpdateSource.gitee ? UpdateSource.github : UpdateSource.gitee;
}

class RemoteAsset {
  const RemoteAsset({required this.name, required this.url, required this.size});
  final String name;
  final String url;
  final int size;
}

class RemoteRelease {
  const RemoteRelease({required this.source, required this.tag,
    required this.pageUrl, required this.notes, required this.prerelease,
    required this.assets});
  final UpdateSource source;
  final String tag;
  final String pageUrl;
  final String notes;
  final bool prerelease;
  final List<RemoteAsset> assets;
}
```

Add `ManifestAsset`, `ResolvedUpdateAsset` and `UpdateManifest`. Require schema 1,
`appId == DreamMangaReader`, semantic version, safe basename, positive size and 64 hex SHA-256.
`resolve` matches names case-insensitively and requires equal remote size. Move the current
`UpdateAsset` concept from `update_installer.dart` and adapt call sites so compilation remains green.

- [ ] **Step 4: Run focused tests**

```powershell
flutter test test/update_models_test.dart test/update_version_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/update/update_models.dart lib/core/update/update_installer.dart lib/core/update/update_service.dart test/update_models_test.dart
git commit -m "refactor: add validated update manifest models"
```

## Task 2: GitHub and Gitee Release Clients

**Files:**
- Create: `lib/core/update/update_release_client.dart`
- Create: `test/update_release_client_test.dart`

- [ ] **Step 1: Write failing parser tests**

```dart
test('parses GitHub release assets', () {
  final release = GitHubReleaseClient.parseRelease({
    'tag_name': 'v1.3.1', 'html_url': 'https://github.com/release',
    'body': 'notes', 'draft': false, 'prerelease': false,
    'assets': [{'name': 'a.apk', 'size': 12,
      'browser_download_url': 'https://example/a.apk'}],
  });
  expect(release.source, UpdateSource.github);
  expect(release.assets.single.size, 12);
});

test('parses Gitee release plus attach_files', () {
  final release = GiteeReleaseClient.parseRelease({
    'id': 7, 'tag_name': 'v1.3.1', 'body': 'notes', 'prerelease': false,
  }, [{'name': 'a.apk', 'size': 12,
    'browser_download_url': 'https://gitee.com/a.apk'}]);
  expect(release.source, UpdateSource.gitee);
  expect(release.pageUrl, contains('/releases/tag/v1.3.1'));
});
```

Also assert GitHub drafts are dropped and malformed attachments are ignored.

- [ ] **Step 2: Run `flutter test test/update_release_client_test.dart`**

Expected: FAIL because the clients do not exist.

- [ ] **Step 3: Implement one interface and two injected-Dio clients**

```dart
abstract interface class UpdateReleaseClient {
  UpdateSource get source;
  Future<List<RemoteRelease>> listReleases();
  Future<UpdateManifest> fetchManifest(RemoteRelease release);
}
```

GitHub uses `GET https://api.github.com/repos/TypeDreamMoon/DreamMangaReader/releases?per_page=20`.
Gitee uses `GET https://gitee.com/api/v5/repos/TypeDreamMoon/DreamMangaReader/releases?per_page=20`
and fetches `/releases/{id}/attach_files?per_page=100` only for candidate releases. Public reads
use no Token. Both clients have 12-second timeouts, validate status, parse `browser_download_url`,
and throw `UpdateSourceException` on transport/parse errors instead of returning an empty list.
`fetchManifest` downloads `dream-manga-reader-update.json` and resolves it against the same Release.

- [ ] **Step 4: Run tests and analysis**

```powershell
flutter test test/update_release_client_test.dart
dart analyze lib/core/update/update_models.dart lib/core/update/update_release_client.dart
```

Expected: PASS with no findings.

- [ ] **Step 5: Commit**

```powershell
git add lib/core/update/update_release_client.dart test/update_release_client_test.dart
git commit -m "feat: add GitHub and Gitee release clients"
```

## Task 3: Dual-Source Resolver and Legacy Compatibility

**Files:**
- Create: `lib/core/update/update_resolver.dart`
- Create: `test/update_resolver_test.dart`
- Modify: `lib/core/update/update_service.dart`
- Modify: `test/update_version_test.dart`

- [ ] **Step 1: Write failing fake-client tests**

```dart
test('same version prefers Gitee', () async {
  final result = await fakeResolver(gitee: candidate('1.3.1'),
      github: candidate('1.3.1')).resolve(
    currentVersion: '1.3.0', preferred: UpdateSource.gitee);
  expect(result!.source, UpdateSource.gitee);
});

test('higher GitHub version wins even when Gitee is preferred', () async {
  final result = await fakeResolver(gitee: candidate('1.3.1'),
      github: candidate('1.3.2')).resolve(
    currentVersion: '1.3.0', preferred: UpdateSource.gitee);
  expect(result!.version, '1.3.2');
});

test('fallback survives preferred source failure', () async {
  final result = await fakeResolver(giteeError: sourceError(UpdateSource.gitee),
      github: candidate('1.3.1')).resolve(
    currentVersion: '1.3.0', preferred: UpdateSource.gitee);
  expect(result!.source, UpdateSource.github);
  expect(result.warnings.single, contains('Gitee'));
});

test('both source failures are not reported as up to date', () async {
  expect(() => fakeResolver(giteeError: sourceError(UpdateSource.gitee),
      githubError: sourceError(UpdateSource.github)).resolve(
    currentVersion: '1.3.0', preferred: UpdateSource.gitee),
    throwsA(isA<UpdateResolutionException>()));
});
```

Also cover stable/prerelease filtering and a legacy GitHub Release without a manifest.

- [ ] **Step 2: Run `flutter test test/update_resolver_test.dart`**

Expected: FAIL because `UpdateResolver` does not exist.

- [ ] **Step 3: Implement deterministic resolution**

Create `UpdateCandidate` containing source, version, tag, page URL, notes, prerelease, assets,
integrity and warnings. Call preferred then fallback; keep usable results despite the other source
failing; choose the higher semantic version and preferred source on ties. Return `null` only when
at least one source succeeded and neither has a newer candidate. Throw a combined exception when
both failed. Historical GitHub Releases may synthesize `UpdateIntegrity.legacy` candidates from
the existing `-universal.apk` and `setup.exe` names.

Move semantic comparison into pure `UpdateVersion`, retaining forwarding static methods on
`UpdateService` until existing tests/callers are migrated.

- [ ] **Step 4: Replace networking in `UpdateService.check`**

```dart
static Future<UpdateCheckResult> check({
  bool includeBeta = false,
  UpdateSource preferredSource = UpdateSource.gitee,
});
```

`UpdateCheckResult` has explicit `updateAvailable`, `upToDate`, and `failed` states so a network
failure can never become the current “latest” null result.

```dart
enum UpdateCheckState { updateAvailable, upToDate, failed }

class UpdateCheckResult {
  const UpdateCheckResult(this.state, {this.candidate, this.error});
  final UpdateCheckState state;
  final UpdateCandidate? candidate;
  final UpdateResolutionException? error;
}
```

- [ ] **Step 5: Run update-core tests**

```powershell
flutter test test/update_version_test.dart test/update_models_test.dart test/update_release_client_test.dart test/update_resolver_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add lib/core/update/update_resolver.dart lib/core/update/update_service.dart test/update_resolver_test.dart test/update_version_test.dart
git commit -m "feat: resolve updates across Gitee and GitHub"
```

## Task 4: Persist and Display the Preferred Source

**Files:**
- Modify: `lib/app/library_store.dart`
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/features/shell/home_shell.dart`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hant.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`
- Create: `test/update_settings_test.dart`

- [ ] **Step 1: Write failing persistence tests**

```dart
test('defaults to Gitee and persists GitHub preference', () async {
  SharedPreferences.setMockInitialValues({});
  final store = LibraryStore();
  await store.load();
  expect(store.updateSource, UpdateSource.gitee);
  store.updateSource = UpdateSource.github;
  final prefs = await SharedPreferences.getInstance();
  expect(prefs.getString('lib.updateSource'), 'github');
});

test('unknown source migrates to Gitee', () async {
  SharedPreferences.setMockInitialValues({'lib.updateSource': 'retired'});
  final store = LibraryStore();
  await store.load();
  expect(store.updateSource, UpdateSource.gitee);
});
```

- [ ] **Step 2: Run `flutter test test/update_settings_test.dart`**

Expected: FAIL because `updateSource` does not exist.

- [ ] **Step 3: Add key, field, load/export/import and setter paths**

Persist `lib.updateSource` as enum name. Missing/invalid values resolve to Gitee. Include the value
in existing settings backup/sync paths, matching current update settings behavior.

- [ ] **Step 4: Add the source selector and all translations**

Insert an `AppSelectRow` in the Update section. Add these semantic keys to all four ARB files:

```json
"set_updateSource": "更新源",
"set_updateSourceSub": "首选 {source}，不可用时自动切换备用源",
"set_updateSourceGitee": "Gitee / 国内默认源",
"set_updateSourceGitHub": "GitHub / 备用源"
```

Provide natural English, Traditional Chinese and Japanese translations, then run
`flutter gen-l10n`; do not hand-edit generated Dart.

- [ ] **Step 5: Pass preference at both call sites**

```dart
final result = await UpdateService.check(
  includeBeta: lib.updateIncludeBeta,
  preferredSource: lib.updateSource,
);
```

Manual checks show an error for `failed`, latest only for `upToDate`, and dialog only for
`updateAvailable`.

- [ ] **Step 6: Run tests**

```powershell
flutter gen-l10n
flutter test test/update_settings_test.dart test/l10n_test.dart test/widget_test.dart
```

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add lib/app/library_store.dart lib/features/settings/settings_page.dart lib/features/shell/home_shell.dart lib/l10n test/update_settings_test.dart
git commit -m "feat: default update checks to Gitee"
```

## Task 5: Platform Asset Selection and Android ABI Bridge

**Files:**
- Create: `lib/core/update/android_abi.dart`
- Create: `lib/core/update/update_asset_selector.dart`
- Create: `test/update_asset_selector_test.dart`
- Modify: `android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/MainActivity.kt`

- [ ] **Step 1: Write failing selector tests**

```dart
test('Windows selects installer, never portable ZIP', () async {
  final selected = await selector.select(platform: UpdatePlatform.windows,
    assets: [portableZip, windowsSetup]);
  expect(selected, windowsSetup);
});

test('Android follows supported ABI order', () async {
  final selected = await selector.select(platform: UpdatePlatform.android,
    assets: [armV7, arm64, universal],
    supportedAbis: ['arm64-v8a', 'armeabi-v7a']);
  expect(selected, arm64);
});

test('Android uses universal only when no ABI asset matches', () async {
  final selected = await selector.select(platform: UpdatePlatform.android,
    assets: [universal], supportedAbis: ['arm64-v8a']);
  expect(selected, universal);
});
```

- [ ] **Step 2: Run `flutter test test/update_asset_selector_test.dart`**

Expected: FAIL because selector contracts do not exist.

- [ ] **Step 3: Implement pure manifest-metadata selection**

Windows requires `platform=windows`, `arch=x64`, `kind=installer`. Android iterates normalized
`supportedAbis`, then accepts `arch=universal` only as fallback. Return null rather than guessing.

- [ ] **Step 4: Implement the narrow Android method channel**

```kotlin
class MainActivity : FlutterActivity() {
    private val channelName = "dream_manga_reader/platform"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "supportedAbis" -> result.success(Build.SUPPORTED_ABIS.toList())
                    else -> result.notImplemented()
                }
            }
    }
}
```

Define injectable `AndroidAbiProvider` and `MethodChannelAndroidAbiProvider` in Dart. Unexpected
values become an empty list, permitting only universal fallback.

- [ ] **Step 5: Run tests and Android compilation**

```powershell
flutter test test/update_asset_selector_test.dart
flutter build apk --debug
```

Expected: PASS and a debug APK.

- [ ] **Step 6: Commit**

```powershell
git add lib/core/update/android_abi.dart lib/core/update/update_asset_selector.dart android/app/src/main/kotlin/com/dreammoon/dream_manga_reader/MainActivity.kt test/update_asset_selector_test.dart
git commit -m "feat: select Android updates by device ABI"
```

## Task 6: Resumable Download, Size and SHA-256 Verification

**Files:**
- Create: `lib/core/update/update_downloader.dart`
- Create: `test/update_downloader_test.dart`
- Modify: `lib/core/update/update_installer.dart`
- Modify: `lib/core/update/update_service.dart`

- [ ] **Step 1: Write failing verifier and resume tests**

```dart
test('accepts matching size and SHA-256', () async {
  final file = File('${temp.path}/package.bin')..writeAsBytesSync([1, 2, 3]);
  await UpdateFileVerifier.verify(file, expectedSize: 3,
    expectedSha256: '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81');
});

test('deletes corrupt download', () async {
  final file = File('${temp.path}/package.download')..writeAsBytesSync([1, 2, 3]);
  await expectLater(UpdateFileVerifier.verify(file, expectedSize: 4,
    expectedSha256: '0' * 64), throwsA(isA<UpdateIntegrityException>()));
  expect(file.existsSync(), isFalse);
});
```

Use a fake Dio `HttpClientAdapter` for two more cases: a 206 response appends after sending the
correct Range header; a 200 response to a resume attempt truncates and restarts from byte zero.

- [ ] **Step 2: Run `flutter test test/update_downloader_test.dart`**

Expected: FAIL because the downloader does not exist.

- [ ] **Step 3: Implement bounded verified downloading**

`UpdateDownloader.download` accepts a resolved asset, progress callback and `CancelToken`. Store
`<file>.download`; send `Range: bytes=<length>-` for valid partials; append only on 206; restart on
200; reject other statuses. Stream SHA-256 with `crypto.sha256.bind(file.openRead())`, then atomically
rename. Keep only the newest two completed updater packages plus active paths, and enumerate only
the updater-owned cache directory.

- [ ] **Step 4: Narrow installer to installation only**

```dart
static Future<void> install(
  File package, {
  Future<void> Function()? onBeforeExit,
})
```

Retain current Android `OpenFilex.open` and Windows Inno launch/exit behavior. Downloader runs first;
installer is called only after verification.

- [ ] **Step 5: Run updater tests**

```powershell
flutter test test/update_downloader_test.dart test/update_asset_selector_test.dart test/update_models_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add lib/core/update/update_downloader.dart lib/core/update/update_installer.dart lib/core/update/update_service.dart test/update_downloader_test.dart
git commit -m "feat: verify resumable update downloads"
```

## Task 7: Complete the In-App Update Experience

**Files:**
- Modify: `lib/core/update/update_service.dart`
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_zh_Hant.arb`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_ja.arb`
- Create: `test/update_dialog_test.dart`

- [ ] **Step 1: Write failing widget tests**

Pump the dialog with injected fake download/install callbacks. Assert source text shows Gitee or
`GitHub / 备用源`; the primary button starts in-app download rather than `launchUrl`; progress reaches
100%; cancel invokes the token; integrity failure offers retry/manual buttons; no compatible asset
offers manual only. Add stable keys `update-primary`, `update-cancel`, `update-retry`, and
`update-manual`.

- [ ] **Step 2: Run `flutter test test/update_dialog_test.dart`**

Expected: FAIL because the source-aware injected flow is absent.

- [ ] **Step 3: Wire resolver, selector, downloader and installer**

State sequence is `idle -> downloading -> verifying -> launching -> complete/error`. Keep dimensions
stable during changes. Windows flushes `LibraryStore` before exit. Android reports success only after
the system installer opens. Manual link appears only when automatic update is unavailable or failed.

- [ ] **Step 4: Add all updater translations**

Add source, fallback, download, verify, launch, retry, cancel, manual download and combined-source
failure messages to all ARB files; run `flutter gen-l10n` and do not hand-edit generated Dart.

- [ ] **Step 5: Run widget and l10n tests**

```powershell
flutter gen-l10n
flutter test test/update_dialog_test.dart test/widget_test.dart test/l10n_test.dart
```

Expected: PASS.

- [ ] **Step 6: Commit**

```powershell
git add lib/core/update/update_service.dart lib/features/settings/settings_page.dart lib/l10n test/update_dialog_test.dart
git commit -m "feat: complete in-app dual-source updates"
```

## Task 8: Shared Release Contract and Environment Checks

**Files:**
- Create: `Scripts/Release.Common.ps1`
- Create: `Scripts/检查发布环境.ps1`
- Create: `Scripts/Tests/Release.Common.Tests.ps1`
- Modify: `.gitignore`

- [ ] **Step 1: Write failing dependency-free PowerShell tests**

```powershell
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\Release.Common.ps1"
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message Expected=$Expected Actual=$Actual" }
}
Assert-Equal '1.3.1' (Normalize-ReleaseVersion 'v1.3.1') 'version'
Assert-Equal $true (Test-Sha256 ('a' * 64)) 'valid SHA'
Assert-Equal $false (Test-Sha256 '../bad') 'invalid SHA'
Assert-Equal $true (Test-GiteeAttachmentSize -Bytes 99MB) 'under limit'
Assert-Equal $false (Test-GiteeAttachmentSize -Bytes 101MB) 'over limit'
Write-Host 'Release.Common tests passed.'
```

- [ ] **Step 2: Run the test**

```powershell
pwsh -NoProfile -File Scripts/Tests/Release.Common.Tests.ps1
```

Expected: FAIL because the helper file is absent.

- [ ] **Step 3: Implement pure helpers**

Implement `Normalize-ReleaseVersion`, `Test-Sha256`, `Get-FileSha256`,
`Test-GiteeAttachmentSize` with hard ceiling `100MB`, `Assert-SafeFileName`,
`Read-ReleaseVersion`, `Assert-VersionAgreement`, `New-UpdateManifest`, and
`Test-ReleaseAssetSet`. The manifest contains no Token or absolute local path.

- [ ] **Step 4: Implement read-only environment checks**

Report paths/versions for PowerShell 7, Flutter, Dart, Git, Visual Studio C++, Android SDK/JDK,
NuGet and Inno Setup. Report only Token presence. Query the public Gitee repository and default
branch without credentials. Make no installs and no global configuration changes. Return nonzero
for tools required by `-Platform All|Windows|Android` that are absent.

- [ ] **Step 5: Ignore only generated output**

```gitignore
/ReleaseOutput/
/Scripts/*.response.json
```

- [ ] **Step 6: Run helper and Android environment checks**

```powershell
pwsh -NoProfile -File Scripts/Tests/Release.Common.Tests.ps1
pwsh -NoProfile -File Scripts/检查发布环境.ps1 -Platform Android
```

Expected: helper PASS and environment check exposes no credential value.

- [ ] **Step 7: Commit**

```powershell
git add .gitignore Scripts/Release.Common.ps1 Scripts/检查发布环境.ps1 Scripts/Tests/Release.Common.Tests.ps1
git commit -m "build: add release contract and environment checks"
```

## Task 9: Local Windows and Android Packaging

**Files:**
- Create: `Scripts/打包新版本.ps1`
- Modify: `Scripts/Release.Common.ps1`
- Modify: `Scripts/Tests/Release.Common.Tests.ps1`
- Modify: `windows/installer/DreamMangaReader.iss`
- Modify: `android/app/build.gradle`
- Modify: `pubspec.yaml`

- [ ] **Step 1: Add failing version-code and agreement tests**

Create temporary pubspec/AppInfo fixtures. Assert agreement for `1.3.1+13`, rejection when AppInfo
says `1.3.0`, and these bridge calculations:

```powershell
Assert-Equal 10013 (Get-AndroidUniversalBuildNumber -PubspecBuildNumber 13) 'universal code'
Assert-Equal 10013 (Get-AndroidSplitBaseBuildNumber -PubspecBuildNumber 13) 'split base'
```

- [ ] **Step 2: Run helper tests**

Run `pwsh -NoProfile -File Scripts/Tests/Release.Common.Tests.ps1`.

Expected: FAIL on missing version-code helpers.

- [ ] **Step 3: Implement the packaging entrypoint**

```powershell
param(
    [Parameter(Mandatory)][string]$Version,
    [ValidateSet('stable','beta')][string]$Channel = 'stable',
    [ValidateSet('All','Windows','Android')][string]$Platform = 'All',
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\ReleaseOutput'),
    [switch]$SkipTests
)
```

The script must verify version/build consistency; run `flutter pub get`, `flutter analyze`, and
`flutter test`; build Windows Release, VC runtime, portable ZIP and Inno installer; build universal
APK with `10000 + build` and split APKs using the same high base; copy stable filenames; inspect
actual package/version codes and signing certificate; generate hashes/manifests; and reject Gitee
attachments over 100 MiB.

The Android checks must read each packaged APK's actual `versionCode`: the bridge version (桥接版)
universal APK establishes the new high baseline, and every later ABI-specific APK must be strictly
greater so Android never rejects an in-app update as a downgrade.

Write `ReleaseOutput/v<version>/github/` with universal and split APKs, Windows assets, hashes and
manifest. Write `gitee/` with split APKs only plus Windows assets, hashes and its matching manifest.
Neither directory is published by this script.

- [ ] **Step 4: Parameterize Inno paths without changing identity**

Add optional `SourceDir` and `OutputDir` defines. Preserve AppId, publisher, executable, privilege
and install-directory behavior.

- [ ] **Step 5: Verify Android packaging locally**

```powershell
pwsh -NoProfile -File Scripts/打包新版本.ps1 -Version 1.3.1 -Platform Android
```

Expected: all APKs/hashes/manifests; universal only in GitHub folder; all Gitee attachments below
100 MiB; every split version code greater than bridge universal; fixed signing certificate matches.

- [ ] **Step 6: Verify Windows packaging after side-by-side prerequisites exist**

```powershell
pwsh -NoProfile -File Scripts/打包新版本.ps1 -Version 1.3.1 -Platform Windows
```

Expected: setup, ZIP, hashes and manifests. Missing NuGet/Inno Setup produces an actionable stop;
the script does not install or change global PATH.

- [ ] **Step 7: Commit**

```powershell
git add Scripts/打包新版本.ps1 Scripts/Release.Common.ps1 Scripts/Tests/Release.Common.Tests.ps1 windows/installer/DreamMangaReader.iss android/app/build.gradle pubspec.yaml
git commit -m "build: package verified Windows and Android releases"
```

## Task 10: Safe Gitee-Only Release Publishing

**Files:**
- Create: `Scripts/发布到Gitee.ps1`
- Create: `Scripts/打包并发布Gitee.ps1`
- Modify: `Scripts/Release.Common.ps1`
- Modify: `Scripts/Tests/Release.Common.Tests.ps1`

- [ ] **Step 1: Write failing publication-plan tests**

Test `Compare-RemoteAttachments`: missing names are selected for upload; same name/size is complete;
same name/different size throws conflict. Also reject the wrong owner/repository and any file above
100 MiB.

- [ ] **Step 2: Run helper tests**

Run `pwsh -NoProfile -File Scripts/Tests/Release.Common.Tests.ps1`.

Expected: FAIL because publication helpers do not exist.

- [ ] **Step 3: Implement the Gitee-only publisher**

Parameters include `-AssetRoot`, `-Owner TypeDreamMoon`, `-Repository DreamMangaReader`,
`-TargetBranch main`, `-DryRun`, and `-ConfirmPublish`. The script:

1. Resolves `DREAMMANGAREADER_GITEE_TOKEN`, then `GITEE_TOKEN`, without printing it.
2. Validates local manifest and complete asset set.
3. Requires exact public repository identity/default branch.
4. Prints target, tag, channel and names/sizes.
5. Performs no writes in DryRun.
6. Requires `Y` unless composed entrypoint passed `-ConfirmPublish` after its own confirmation.
7. Creates or reuses same-tag Release.
8. Reads `/releases/{id}/attach_files?per_page=100`.
9. Uploads only missing files with `curl.exe --form access_token=... --form file=@...`.
10. Stops on same-name size conflict; never deletes/overwrites.
11. Re-fetches and verifies exact names/sizes.
12. Publicly downloads/parses the remote manifest and prints Release URL.

Response files stay inside the version output and are removed in `finally`. Do not construct a
logged command line containing the Token.

- [ ] **Step 4: Implement composed packaging and publishing**

Run environment check, all-platform packaging, one final artifact summary/confirmation, then
publishing. Stop on any nonzero exit. Never publish one platform from an incomplete `All` build.

- [ ] **Step 5: Exercise DryRun**

```powershell
pwsh -NoProfile -File Scripts/发布到Gitee.ps1 -AssetRoot ReleaseOutput/v1.3.1/gitee -DryRun
```

Expected: exact target/assets, no remote writes, no Token printed.

- [ ] **Step 6: Commit**

```powershell
git add Scripts/发布到Gitee.ps1 Scripts/打包并发布Gitee.ps1 Scripts/Release.Common.ps1 Scripts/Tests/Release.Common.Tests.ps1
git commit -m "build: publish verified releases to Gitee"
```

## Task 11: Align GitHub Actions and Prepare the Bridge Version

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `lib/app/app_info.dart`
- Modify: `pubspec.yaml`
- Modify: `README.md`

- [ ] **Step 1: Confirm the bridge version remains free**

```powershell
git -c http.proxy=http://127.0.0.1:7897 -c https.proxy=http://127.0.0.1:7897 fetch upstream --tags
git tag --list v1.3.1
```

Expected: no upstream `v1.3.1`. If occupied, use the next free patch and increment build number;
apply that version consistently to every later command.

- [ ] **Step 2: Demonstrate missing workflow contract before modification**

```powershell
rg -n "dream-manga-reader-update.json|10000|sha256" .github/workflows/release.yml
```

Expected: manifest/high version-code contract is absent or incomplete.

- [ ] **Step 3: Set bridge metadata and workflow assertions**

Set `AppInfo.version = '1.3.1'` and `pubspec version: 1.3.1+13` when free. Add a job step that requires
tag, AppInfo and pubspec semantic version to match and prints computed universal/split bases.

- [ ] **Step 4: Align all workflow artifacts**

Build universal with `10000 + build`; splits with the same high base; inspect actual package/version
codes and certificate; preserve stable names; compute hashes; generate the GitHub manifest; upload
setup, ZIP, universal, splits, manifest and hash files. Keep the fixed key and Inno AppId. Do not add
Gitee Token or Gitee publishing to Actions.

- [ ] **Step 5: Document the split responsibility**

README in Chinese states: maintainer runs Gitee scripts, author pushes GitHub tag, bridge must be
released on author GitHub, then clients default to Gitee with GitHub fallback. Show commands with
environment-variable names only, never a real credential.

- [ ] **Step 6: Verify project and workflow**

```powershell
flutter pub get
flutter analyze
flutter test
pwsh -NoProfile -File Scripts/Tests/Release.Common.Tests.ps1
```

After pushing the implementation branch to the fork, require GitHub to recognize the workflow:

```powershell
gh workflow view release.yml --repo kirito0000001/DreamMangaReader --yaml
```

Expected: the workflow YAML is returned with exit code 0; all local checks PASS.

- [ ] **Step 7: Commit**

```powershell
git add .github/workflows/release.yml lib/app/app_info.dart pubspec.yaml README.md
git commit -m "chore: prepare dual-source bridge release"
```

## Task 12: Full Verification and Author Handoff

**Files:**
- Create: `docs/release/双源热更新验收记录.md`
- Modify only if evidence requires fixes: files changed in Tasks 1-11

- [ ] **Step 1: Run formatting and static checks**

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
```

Expected: exit 0.

- [ ] **Step 2: Run all Flutter tests**

```powershell
flutter test
```

Expected: all PASS.

- [ ] **Step 3: Run PowerShell checks**

```powershell
pwsh -NoProfile -File Scripts/Tests/Release.Common.Tests.ps1
pwsh -NoProfile -File Scripts/检查发布环境.ps1 -Platform All
```

Expected: helper PASS; environment check either passes or names exact missing prerequisite without
modifying the machine.

- [ ] **Step 4: Build complete bridge assets**

```powershell
pwsh -NoProfile -File Scripts/打包新版本.ps1 -Version 1.3.1 -Platform All
```

Use synchronized version if Task 11 selected another patch. Expected: complete Gitee/GitHub folders,
matching hashes, Gitee sizes below limit, and valid APK codes/signatures.

- [ ] **Step 5: Run Gitee DryRun**

```powershell
pwsh -NoProfile -File Scripts/发布到Gitee.ps1 -AssetRoot ReleaseOutput/v1.3.1/gitee -DryRun
```

Expected: exact summary and no write.

- [ ] **Step 6: Perform controlled behavior tests**

Verify Gitee success, Gitee timeout to GitHub fallback, corrupt package rejection, Windows setup only
after hash verification, and Android arm64 selection/system installer. Use fake endpoints for failure
paths and public APIs for read-only paths. Do not publish a real Gitee Release until the user supplies
the Token and explicitly authorizes that version.

- [ ] **Step 7: Write the Chinese acceptance record**

Record date, branch/commit, commands and results, artifact names/sizes/hashes, actual Android version
codes, blockers, and author handoff: merge PR, push bridge tag, verify GitHub attachments, test upgrade
from `v1.3.0` on Windows/Android, then publish the next Gitee version for migration proof.

- [ ] **Step 8: Commit evidence**

```powershell
git add docs/release/双源热更新验收记录.md
git commit -m "docs: record dual-source updater verification"
```

- [ ] **Step 9: Confirm clean repository and no tracked secrets/artifacts**

```powershell
git status --short --branch
git log --oneline --decorate -12
git ls-files | rg "ReleaseOutput|\.apk$|setup\.exe$|response\.json$"
```

Expected: clean `codex/gitee-hot-update`; implementation commits present; final command has no output;
no Token, APK, installer, generated output or response file is tracked.
