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
  assert.match(yaml, /VITE_APPLE_PAY_MERCHANT_ID/);
  assert.match(yaml, /merchant\.fr\.secoto\.app/);
});

test("iOS utilise un vrai bord à bord tout en conservant les marges sûres", async () => {
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

test("le runtime iOS superpose le fond et protège le contenu par safe area", async () => {
  const runtime = await source("../src/platform/runtime.js");

  assert.match(
    runtime,
    /StatusBar\.setOverlaysWebView\(\{\s*overlay:\s*true\s*\}\)/,
  );
  assert.doesNotMatch(
    runtime,
    /StatusBar\.setOverlaysWebView\(\{\s*overlay:\s*false\s*\}\)/,
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

// App Store Connect ferme un « train » de version dès qu'il est approuvé :
// republier la même version marketing est refusé (STATE_ERROR.VALIDATION_ERROR,
// « The train version X is closed for new build submissions »). Le numéro de
// build, lui, s'incrémente tout seul. Ce test ne fige donc AUCUNE version : il
// vérifie que les trois endroits qui la déclarent disent la même chose, ce qui
// est la seule erreur réellement dangereuse.
test("la version marketing iOS est unique et cohérente partout", async () => {
  const [yaml, plist, project] = await Promise.all([
    source("../codemagic.yaml"),
    source("../ios/App/App/Info.plist"),
    source("../ios/App/App.xcodeproj/project.pbxproj"),
  ]);

  const declared = yaml.match(/IOS_MARKETING_VERSION:\s+"(\d+\.\d+(?:\.\d+)?)"/);
  assert.ok(declared, "codemagic.yaml doit déclarer IOS_MARKETING_VERSION");
  const version = declared[1];
  const escaped = version.replace(/\./g, "\\.");

  assert.match(
    plist,
    new RegExp(`CFBundleShortVersionString[\\s\\S]*?<string>${escaped}</string>`),
    `Info.plist doit annoncer ${version}`,
  );

  const projectVersions = project.match(/MARKETING_VERSION = ([^;]+);/g) || [];
  assert.equal(projectVersions.length, 2, "les deux configurations Xcode doivent porter une version");
  for (const line of projectVersions) {
    assert.equal(line, `MARKETING_VERSION = ${version};`,
      `Xcode doit préparer ${version}, pas ${line}`);
  }

  // Le pipeline doit conserver ses garde-fous de numérotation.
  assert.match(yaml, /Archive IPA SECOTO/);
  assert.match(yaml, /get-latest-testflight-build-number/);
  assert.match(yaml, /get-latest-app-store-build-number/);
  assert.match(yaml, /PROJECT_BUILD_NUMBER/);
  assert.match(yaml, /IOS_BUILD_NUMBER"\s+-lt 21/);

  // Et le contrôle bloquant qui compare l'IPA produite à la version voulue.
  assert.match(yaml, /ERREUR BLOQUANTE/);
});
