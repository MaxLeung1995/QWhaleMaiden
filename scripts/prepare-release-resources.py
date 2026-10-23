#!/usr/bin/env python3
"""Exclude developer snapshot diagnostics from staged release resources only."""
from pathlib import Path
import sys
root=Path(sys.argv[1])
for name,prefix in [('pet.js','window.uiDiagnostics='),('settings.js','window.settingsDiagnostics=')]:
 p=root/name;lines=p.read_text().splitlines();assert sum(line.startswith(prefix) for line in lines)==1
 p.write_text('\n'.join(line for line in lines if not line.startswith(prefix))+'\n')
p=root/'dsh-renderer.js';s=p.read_text();a=s.index('  diagnostics(){');b=s.index('\n  }\n };',a)+len('\n  }')
s=s[:a]+s[b:];s=s.replace('window.petDiagnostics=()=>DSHPet.diagnostics();','');p.write_text(s)
