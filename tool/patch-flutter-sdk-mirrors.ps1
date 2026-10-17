# Adds mainland-China Maven mirrors to the Flutter SDK's own Gradle build.
#
# Why: packages/flutter_tools/gradle is an includeBuild with its own
# settings.gradle.kts that hardcodes google() + mavenCentral() and sets
# FAIL_ON_PROJECT_REPOS, so patching the app project has no effect.
#
# `flutter upgrade` overwrites that file - re-run this script after upgrading.

$ErrorActionPreference = 'Stop'

$sdk = if ($env:FLUTTER_ROOT) { $env:FLUTTER_ROOT } else { 'E:\dev\flutter' }
$target = Join-Path $sdk 'packages\flutter_tools\gradle\settings.gradle.kts'
if (-not (Test-Path $target)) { throw "not found: $target (FLUTTER_ROOT=$sdk)" }

$content = @'
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // Local patch: direct Maven Central / dl.google.com access often stalls
        // in mainland China, so prefer the Aliyun mirrors.
        // `flutter upgrade` overwrites this file; re-run
        // tool/patch-flutter-sdk-mirrors.ps1 afterwards.
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        google()
        mavenCentral()
    }
}
'@

Set-Content -Path $target -Value $content -Encoding UTF8
Write-Host "patched: $target"
