from pathlib import Path
import hashlib
out=Path(__file__).resolve().parents[1]/'dist'
paths=sorted(p for p in out.iterdir() if p.is_file() and p.stat().st_size and p.name!='SHA256SUMS.txt')
(out/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in paths),encoding='ascii')
print('Release checksums refreshed.')
