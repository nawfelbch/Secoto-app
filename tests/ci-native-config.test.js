import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

async function source(path) {
  return readFile(new URL(path, import.meta.url), "utf8");
}

test("le workflow iOS utilise le projet SPM réel, Node 24 et Xcode 26", async () => {
  const yaml = await source("../codemagic.yaml");
  assert.match(yaml, /XCODE_PROJECT:\s+ios\/App\/App\.xcodeproj/);
  assert.match(yaml, /node:\s+24/);
  assert.match(yaml, /xcode:\s+26\.0/);
  assert.doesNotMatch(yaml, /pod install|--workspace|App\.xcworkspace/);
  assert.match(yaml, /submit_to_testflight:\s+true/);
});

test("iOS place la WebView sous la barre d’état et conserve les marges sûres", async () => {
  const [configRaw, html, css] = await Promise.all([
    source("../capacitor.config.json"),
    source("../index.html"),
    source("../src/index.css"),
  ]);

  const config = JSON.parse(configRaw);

  assert.equal(config.ios?.contentInset, "never");
  assert.equal(config.plugins?.StatusBar?.overlaysWebView, false);
  assert.match(html, /viewport-fit=cover/);
  assert.match(css, /env\(safe-area-inset-top/);
  assert.match(css, /env\(safe-area-inset-bottom/);
});

test("le runtime iOS empêche la barre d’état de recouvrir la WebView", async () => {
  const runtime = await source("../src/platform/runtime.js");

  assert.match(
    runtime,
    /StatusBar\.setOverlaysWebView\(\{\s*overlay:\s*false\s*\}\)/,
  );
  assert.doesNotMatch(
    runtime,
    /StatusBar\.setOverlaysWebView\(\{\s*overlay:\s*true\s*\}\)/,
  );
  assert.match(
    runtime,
    /StatusBar\.setStyle\(\{\s*style:\s*Style\.Light\s*\}\)/,
  );
});

test("le workflow Android prouve tests, lint, APK debug et AAB release sans publication automatique", async () => {
  const yaml = await source("../codemagic.yaml");
  assert.match(yaml, /testDebugUnitTest lintDebug assembleDebug/);
  assert.match(yaml, /\.\/gradlew bundleRelease/);
  assert.match(yaml, /android\/app\/build\/outputs\/\*\*\/\*\.aab/);
  assert.doesNotMatch(yaml, /google_play:|track:\s+internal/);
});

test("les identifiants natifs et les liens Auth restent cohérents", async () => {
  const [manifest, plist, entitlements] = await Promise.all([
    source("../android/app/src/main/AndroidManifest.xml"),
    source("../ios/App/App/Info.plist"),
    source("../ios/App/App/App.entitlements"),
  ]);
  assert.match(manifest, /android:scheme="secoto"/);
  assert.doesNotMatch(manifest, /READ_MEDIA_IMAGES/);
  assert.match(plist, /<string>secoto<\/string>/);
  assert.match(entitlements, /aps-environment/);
});

test("la branche SECOTO 1.3 ne peut produire aucune IPA 1.2", async () => {
  const [yaml, plist, project] = await Promise.all([
    source("../codemagic.yaml"),
    source("../ios/App/App/Info.plist"),
    source("../ios/App/App.xcodeproj/project.pbxproj"),
  ]);

  assert.match(yaml, /IOS_MARKETING_VERSION:\s+"1\.3"/);
  assert.match(yaml, /Archive IPA SECOTO 1\.3/);
  assert.match(yaml, /get-latest-testflight-build-number/);
  assert.match(yaml, /PROJECT_BUILD_NUMBER/);
  assert.match(yaml, /IOS_BUILD_NUMBER"\s+-lt 21/);
  assert.match(plist, /CFBundleShortVersionString[\s\S]*?<string>1\.3<\/string>/);

  const projectVersions = project.match(/MARKETING_VERSION = 1\.3;/g) || [];
  assert.equal(projectVersions.length, 2);

  assert.doesNotMatch(yaml, /IOS_MARKETING_VERSION:\s+"1\.2"/);
  assert.doesNotMatch(project, /MARKETING_VERSION = 1\.2;/);
});
