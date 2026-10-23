#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1
BASE="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -eq 0 ]; then QW_BUILD_MODE=release "$BASE/scripts/build.sh"; fi
SOURCE_APP="${1:-$BASE/build/release/QWhaleMaiden.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_APP/Contents/Info.plist")"
mkdir -p "$BASE/dist" "$BASE/build/verification"
OUTPUT="$BASE/dist/QWhaleMaiden-$VERSION-macOS-arm64.pkg"
STAGE="$(mktemp -d "$BASE/build/pkg-XXXXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
python3 - "$SOURCE_APP" "$STAGE/root/QWhaleMaiden.app" <<'PY'
# -*- coding: utf-8 -*-
from pathlib import Path
import os,shutil,sys
src,dst=map(Path,sys.argv[1:]);(dst/'Contents/Resources').mkdir(parents=True)
def copy_runtime(source,target):
 shutil.copyfile(source,target);os.chmod(target,source.stat().st_mode & 0o777)
for name in ['Info.plist','MacOS/QWhaleMaiden','Helpers/starbud-event']:
 target=dst/'Contents'/name;target.parent.mkdir(parents=True,exist_ok=True);copy_runtime(src/'Contents'/name,target)
for name in ['index.html','settings.html','app.css','pet.css','pet.js','settings.js','dsh-renderer.js','chatter.json','AppIcon.icns','settings-avatar.png']:
 copy_runtime(src/'Contents/Resources'/name,dst/'Contents/Resources'/name)
(dst/'Contents/Resources/bridges/dsh').mkdir(parents=True)
copy_runtime(src/'Contents/Resources/bridges/dsh/index.mjs',dst/'Contents/Resources/bridges/dsh/index.mjs')
(dst/'Contents/Resources/sounds').mkdir()
for name in ['focus.wav','rest.wav','water.wav']:
 copy_runtime(src/'Contents/Resources/sounds'/name,dst/'Contents/Resources/sounds'/name)
dsh=src/'Contents/Resources/dsh';target=dst/'Contents/Resources/dsh';target.mkdir()
for name in ['LICENSE.txt','provenance.json','catalog.js','poster.png']:
 copy_runtime(dsh/name,target/name)
(target/'mov').mkdir()
for f in dsh.glob('mov/*.mov'):copy_runtime(f,target/'mov'/f.name)
assert len(list((target/'mov').glob('*.mov')))==106
for file in ['MacOS/QWhaleMaiden','Helpers/starbud-event']:
 data=(dst/'Contents'/file).read_bytes()
 assert b'verifyView' not in data and b'STARBUD_SMOKE_DIR' not in data,'Use a release build, not a development binary'
for file in ['pet.js','settings.js','dsh-renderer.js']:
 data=(dst/'Contents/Resources'/file).read_text()
 assert not any(name in data for name in ['uiDiagnostics','settingsDiagnostics','petDiagnostics','diagnostics(){'])
PY
xattr -cr "$STAGE/root/QWhaleMaiden.app"
codesign --force --sign - "$STAGE/root/QWhaleMaiden.app"
codesign --verify --strict "$STAGE/root/QWhaleMaiden.app"
codesign --verify --strict "$STAGE/root/QWhaleMaiden.app/Contents/Helpers/starbud-event"
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist"
python3 - "$STAGE/components.plist" <<'PY'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f:components=plistlib.load(f)
assert len(components)==1
components[0].update(BundleIsRelocatable=False,BundleHasStrictIdentifier=True,BundleIsVersionChecked=False,BundleOverwriteAction='upgrade')
with open(p,'wb') as f:plistlib.dump(components,f)
PY
pkgbuild --root "$STAGE/root" --component-plist "$STAGE/components.plist" --identifier com.local.starbud-pet.pkg --version "$VERSION" --install-location /Applications --ownership recommended "$OUTPUT"
pkgutil --expand-full "$OUTPUT" "$STAGE/expanded"
python3 - "$STAGE" "$OUTPUT" "$BASE/build/verification/pkg-report.json" <<'PY'
# -*- coding: utf-8 -*-
from pathlib import Path
import hashlib,json,plistlib,sys,xml.etree.ElementTree as ET
stage,pkg,report=map(Path,sys.argv[1:]);src=stage/'root/QWhaleMaiden.app'
apps=list((stage/'expanded').rglob('QWhaleMaiden.app'));assert len(apps)==1,apps
app=apps[0]
expected={str(f.relative_to(src)):hashlib.sha256(f.read_bytes()).hexdigest() for f in src.rglob('*') if f.is_file()}
actual={str(f.relative_to(app)):hashlib.sha256(f.read_bytes()).hexdigest() for f in app.rglob('*') if f.is_file()}
assert expected==actual,'Expanded payload differs from clean stage'
assert not any(x.endswith(('.log','.sqlite','.sqlite-wal','.sqlite-shm','.py','.swift')) or any(v in x.lower() for v in ['example-pack','verification','test','fixture','screenshot','__pycache__','.ds_store']) for x in actual)
assert not any(p.name=='Scripts' for p in (stage/'expanded').rglob('*'))
package_infos=list((stage/'expanded').rglob('PackageInfo'));assert len(package_infos)==1
info=ET.parse(package_infos[0]).getroot();assert info.attrib['install-location']=='/Applications'
assert not (app.parent/'Library').exists()
sha=hashlib.sha256(pkg.read_bytes()).hexdigest()
result={'package':str(pkg),'version':info.attrib['version'],'installLocation':'/Applications/QWhaleMaiden.app','payloadFileCount':len(actual),'animationCount':106,'onlyApplicationPayload':True,'testDataIncluded':False,'developerCodeIncluded':False,'logsIncluded':False,'examplePackIncluded':False,'installerScriptsIncluded':False,'relocatable':False,'installerSigned':False,'notarized':False,'appSignature':'ad-hoc','expandedPayloadMatchesCleanStage':True,'bytes':pkg.stat().st_size,'sha256':sha,'files':actual}
report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
pkg.with_suffix('.pkg.sha256').write_text(sha+'  '+pkg.name+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='files'},ensure_ascii=False,indent=2))
PY
codesign --verify --strict "$STAGE/expanded/Payload/QWhaleMaiden.app"
echo "$OUTPUT"
