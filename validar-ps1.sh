#!/usr/bin/env bash
# validar-ps1.sh <arquivo.ps1> — as 4 checagens antes de entregar um script ao Gabriel.
f="$1"; [ -f "$f" ] || { echo "uso: $0 arquivo.ps1"; exit 2; }
falhou=0
echo "== validando $(basename "$f") =="

# 1) NAO-ASCII  (o pwsh do Linux NAO pega isto: e bug de encoding no Windows)
n=$(grep -cP '[^\x00-\x7F]' "$f" || true)
if [ "$n" != "0" ]; then
  echo "  [FALHA] $n linha(s) com caractere nao-ASCII:"
  grep -nP '[^\x00-\x7F]' "$f" | head -5 | sed 's/^/          /'
  echo "          Os venenosos sao – (U+2013) e — (U+2014): em CP1252 o 3o byte"
  echo "          vira \" ou \", que o PowerShell ACEITA como aspas -> string sem fim."
  falhou=1
else echo "  [ok] ASCII puro"; fi

# 2) aspa simples orfa (fecha string no meio)
o=$(awk "{n=gsub(/'/,\"x\"); if(n%2==1) print NR}" "$f" | head -5)
if [ -n "$o" ]; then echo "  [FALHA] aspa simples impar nas linhas: $(echo $o | tr '\n' ' ')"; falhou=1
else echo "  [ok] aspas simples balanceadas"; fi

# 3) parser oficial
r=$(docker run --rm -v "$(cd "$(dirname "$f")" && pwd):/w" mcr.microsoft.com/powershell:latest \
    pwsh -NoProfile -Command "\$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile('/w/$(basename "$f")',[ref]\$null,[ref]\$e); if(\$e){\$e|%{\"L\$(\$_.Extent.StartLineNumber): \$(\$_.Message)\"}} else {'OK'}" 2>/dev/null | tail -5)
if [ "$(echo "$r" | tail -1)" = "OK" ]; then echo "  [ok] parser oficial: 0 erros"
else echo "  [FALHA] parser:"; echo "$r" | sed 's/^/          /'; falhou=1; fi

# 4) auto-elevacao + .bat companheiro
if grep -q "IsInRole" "$f"; then
  b="${f%.ps1}.bat"
  if [ -f "$b" ]; then echo "  [ok] tem auto-elevacao E .bat companheiro"
  else echo "  [FALHA] pede admin mas NAO tem $(basename "$b") — a elevacao interna sozinha nao basta"; falhou=1; fi
else echo "  [--] nao pede admin"; fi

[ $falhou -eq 0 ] && echo "== PODE ENTREGAR ==" || echo "== NAO ENTREGAR ainda =="
exit $falhou
