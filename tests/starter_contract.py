from pathlib import Path
import re
def statements(s):
 start=i=0; quote=None
 while i<len(s):
  if quote:
   if s.startswith(quote,i):
    i+=len(quote)
    if quote in ["'",'"'] and s.startswith(quote,i): i+=len(quote);continue
    quote=None
   else:i+=1
   continue
  if s.startswith('--',i):
   end=s.find('\n',i);i=len(s) if end<0 else end+1;continue
  if s.startswith('/*',i):
   end=s.find('*/',i+2);i=len(s) if end<0 else end+2;continue
  m=re.match(r'\$[A-Za-z_0-9]*\$',s[i:])
  if m:quote=m.group();i+=len(quote);continue
  if s[i] in "'\"":quote=s[i];i+=1;continue
  if s[i]==';':yield s[start:i+1];start=i+1
  i+=1
 if s[start:].strip():yield s[start:]

root = Path(__file__).resolve().parents[1]
for path in (root / "db/migrations").glob("*.sql"):
    for statement in (() if path.name in {"20261014000025_seed_number_series.sql"} else statements(path.read_text())):
        bare = re.sub(r"--[^\n]*", "", statement).strip()
        assert not re.match(r"(INSERT|UPDATE|DELETE|SELECT|WITH|TRUNCATE)\b", bare, re.I), path.name
        if re.match(r"DO\b", bare, re.I):
            assert not re.search(r"(?:INSERT INTO|UPDATE|DELETE FROM) finance\.", bare, re.I), path.name
    assert "setup_tokens" not in path.read_text(), path.name
example = (root / ".env.example").read_text().splitlines()
assert all(re.fullmatch(r"[A-Z_]+=", line) for line in example if line)
assert (root / "LICENSE").exists() and "MIT License" in (root / "LICENSE").read_text()
assert not (root / "dashboard/node_modules").exists()
for path in (root / "skills").glob("*/SKILL.md"):
    assert path.read_text().startswith("---\nname:"), path
print("Starter contract checks passed.")
