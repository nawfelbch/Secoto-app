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

test("iOS couvre la zone de la Dynamic Island sans doubler les marges sûres", async () => {
  const [configRaw, html, css] = await Promise.all([
    source("../capacitor.config.json"),
    source("../index.html"),
    source("../src/index.css"),
  ]);

  const config = JSON.parse(configRaw);

  assert.equal(config.ios?.contentInset, "never");
  assert.equal(config.plugins?.StatusBar?.overlaysWebView, true);
  assert.match(html, /viewport-fit=cover/);
  assert.match(css, /env\(safe-area-inset-top/);
  assert.match(css, /env\(safe-area-inset-bottom/);
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
