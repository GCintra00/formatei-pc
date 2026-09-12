#!/usr/bin/env bash
# validar-ps1.sh <arquivo.ps1> — as 4 checagens antes de entregar um script ao Gabriel.
f="$1"; [ -f "$f" ] || { echo "uso: $0 arquivo.ps1"; exit 2; }
falhou=0
echo "== validando $(basename "$f") =="

# 1) ENCODING (o pwsh do Linux NAO pega: le como UTF-8 e nao ve problema)
#    O que quebra de verdade e o byte que, lido como CP1252, vira ASPA TIPOGRAFICA
#    (0x91-0x94 = ' ' " ") - o PowerShell aceita essas como delimitador de string.
#    Acento comum (a-til, c-cedilha) nao cai nessa faixa e nunca deu problema.
venen=$(grep -cP '[\x91-\x94]' "$f" || true)
if [ "$venen" != "0" ]; then
  echo "  [FALHA] $venen linha(s) com caractere que vira ASPA em CP1252 (travessao & cia):"
  grep -nP '[\x91-\x94]' "$f" | head -5 | cut -c1-100 | sed 's/^/          /'
  falhou=1
else
  n=$(grep -cP '[^\x00-\x7F]' "$f" || true)
  if [ "$n" != "0" ]; then echo "  [ok] sem caractere perigoso ($n linha(s) com acento comum, seguro)"
  else echo "  [ok] ASCII puro"; fi
fi

# 2) aspa simples orfa — perigosa DENTRO de string de aspas simples; dentro de
#    aspas duplas o e' e inofensivo. O parser (checagem 3) e a autoridade: aqui
#    so apontamos as linhas, para achar o culpado quando o parser reclama.
impar=$(awk "{n=gsub(/'/,\"x\"); if(n%2==1) print NR}" "$f" | head -5)

# 3) parser oficial
r=$(docker run --rm -v "$(cd "$(dirname "$f")" && pwd):/w" mcr.microsoft.com/powershell:latest \
    pwsh -NoProfile -Command "\$e=\$null; [System.Management.Automation.Language.Parser]::ParseFile('/w/$(basename "$f")',[ref]\$null,[ref]\$e); if(\$e){\$e|%{\"L\$(\$_.Extent.StartLineNumber): \$(\$_.Message)\"}} else {'OK'}" 2>/dev/null | tail -5)
if [ "$(echo "$r" | tail -1)" = "OK" ]; then
  echo "  [ok] parser oficial: 0 erros"
  [ -n "$impar" ] && echo "  [--] aspa simples impar nas linhas $(echo $impar | tr '\n' ' ') (parser passou: e' dentro de aspas duplas, ok)"
else
  echo "  [FALHA] parser:"; echo "$r" | sed 's/^/          /'
  [ -n "$impar" ] && echo "          suspeitas de aspa simples orfa: linhas $(echo $impar | tr '\n' ' ')"
  falhou=1
fi

# 4) auto-elevacao + .bat companheiro
if head -3 "$f" | grep -qi "#Requires -RunAsAdministrator"; then
  echo "  [ok] #Requires -RunAsAdministrator: o proprio PowerShell recusa rodar sem admin"
elif grep -q "IsInRole" "$f"; then
  b="${f%.ps1}.bat"
  if [ -f "$b" ]; then echo "  [ok] tem auto-elevacao E .bat companheiro"
  else echo "  [FALHA] pede admin mas NAO tem $(basename "$b"): a elevacao interna sozinha nao basta"; falhou=1; fi
else echo "  [--] nao pede admin"; fi

[ $falhou -eq 0 ] && echo "== PODE ENTREGAR ==" || echo "== NAO ENTREGAR ainda =="
exit $falhou
