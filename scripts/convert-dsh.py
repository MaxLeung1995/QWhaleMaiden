#!/usr/bin/env python3
"""Build trusted macOS animations from an installed dsh-pet 0.3.7; no downloads/install."""
from pathlib import Path
import concurrent.futures, hashlib,json,subprocess,sys
source=Path(sys.argv[1]);ffmpeg=sys.argv[2]
root=Path(__file__).resolve().parents[1]/'Resources/dsh';out=root/'mov';out.mkdir(exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def convert(p):
    target=out/(p.stem+'.mov')
    subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-c:v','libvpx-vp9','-i',str(p),'-an','-c:v','hevc_videotoolbox','-allow_sw','1','-alpha_quality','0.9','-pix_fmt','bgra','-tag:v','hvc1','-b:v','600k','-movflags','+faststart','-y',str(target)],check=True)
    return {'name':p.stem,'sourceSha256':sha(p),'movSha256':sha(target),'bytes':target.stat().st_size}
files=sorted((source/'assets/webm').glob('*.webm'));results=[]
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    for result in pool.map(convert,files):
        results.append(result)
        if len(results)%10==0:print(f'Converted {len(results)}/{len(files)}',flush=True)
(root/'provenance.json').write_text(json.dumps({'source':'https://github.com/PC2005-cloud/dsh-pet','installedVersion':'0.3.7','license':'MIT, Copyright 2026 PC2005-cloud','conversion':'Local libvpx-vp9 decoder -> Apple VideoToolbox HEVC with alpha, bgra, alpha_quality 0.9, 600 kbps; original geometry and frame rate retained','count':len(results),'files':results},ensure_ascii=False,indent=2)+'\n')
print('Done',len(results),sum(r['bytes'] for r in results),flush=True)
