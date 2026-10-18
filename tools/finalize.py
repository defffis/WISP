from pathlib import Path
import json
root=Path(__file__).resolve().parents[1]
version=(root/'src/VERSION').read_text(encoding='ascii').strip()
p=root/f'dist/wisp-{version}-validation.json'
j=json.loads(p.read_text(encoding='utf-8'))
for name in ['panel','ui','auth','service','clients','remove','removal-package']:
    checks=json.loads((root/f'work/{name}-results.json').read_text(encoding='utf-8'))
    assert all(x['result']=='PASS' for x in checks)
    j[name+'_checks']=checks
hardware=root/f'docs/hardware-results-{version}.json'
if hardware.exists(): j['recorded_device_evidence']=json.loads(hardware.read_text(encoding='utf-8'))
p.write_text(json.dumps(j,ensure_ascii=False,indent=2),encoding='utf-8')
print('Validation report finalized; live device evidence is explicitly separate from CI checks.')
