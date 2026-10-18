#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
denylist="${SCAN_DENYLIST_FILE:-$root/scripts/scan-denylist.local.txt}"
if [[ ! -f "$denylist" ]]; then
  if [[ -n "${SCAN_DENYLIST_FILE:-}" ]]; then
    printf 'Arquivo de denylist não encontrado.\n' >&2
    exit 1
  fi
  denylist="$root/scripts/scan-denylist.example.txt"
  printf 'Usando padrões genéricos; configure a denylist local antes do primeiro push.\n' >&2
fi
# Only report filenames, never matching values. Private scan inputs are not targets.
python3 - "$root" "$denylist" <<'PYSCAN'
import os
from pathlib import Path
import subprocess
import sys
root, denylist = map(Path, sys.argv[1:])
patterns = [line for line in denylist.read_text().splitlines()
            if line.strip() and not line.lstrip().startswith('#')]
if not patterns:
    sys.exit('Denylist vazia.')
excluded_dirs = {'.git', 'node_modules', '.next', '.agents', '.aws', '.codex', '.vercel', 'coverage'}
files = set()
if subprocess.run(['git', 'rev-parse', '--is-inside-work-tree'], stdout=subprocess.DEVNULL,
                  stderr=subprocess.DEVNULL).returncode == 0:
    output = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'])
    files.update(root / os.fsdecode(name) for name in output.split(b'\0') if name)
else:
    for directory, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in excluded_dirs]
        files.update(Path(directory) / name for name in names)
# Always include the scanner, including when ignored by a local Git configuration.
files.add(root / 'scripts/scan-secrets.sh')
failed = False
for file in sorted(files):
    if file.resolve() == denylist.resolve() or file.name == 'scan-denylist.local.txt':
        continue
    # Never open private environment files, even when accidentally tracked.
    if file.name.startswith('.env') and file.name != '.env.example':
        print(f'Arquivo de ambiente privado presente: {file.relative_to(root)}', file=sys.stderr)
        failed = True
        continue
    if not file.exists():  # Tracked file deleted in the working tree.
        continue
    result = subprocess.run(['grep', '-Eiq', '-f', '-', '--', str(file)],
                            input='\n'.join(patterns).encode(), stderr=subprocess.DEVNULL)
    if result.returncode != 1:
        label = 'Conteúdo proibido' if result.returncode == 0 else 'Falha na varredura'
        print(f'{label}: {file.relative_to(root)}', file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
print('Varredura limpa.')
PYSCAN
