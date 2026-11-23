#!/bin/zsh
# Sprawdza, że każdy identyfikator ze spisu (część 1.3) występuje w tabeli przejścia (część 5) dokładnie raz.
cd "${0:A:h}"
doc=../ustawienia-nowy-uklad.md
spis=$(awk '/^### 1.3/,/^### 1.4/' $doc | grep -oE '^\| [A-Z]{1,2}[0-9]+ \|' | tr -d '| ' | sort)
przejscie=$(awk '/^## 5\./,/^## 6\./' $doc | grep -oE '^\| [A-Z]{1,2}[0-9]+ \|' | tr -d '| ' | sort)
echo "Spis: $(echo $spis | wc -l | tr -d ' ') pozycji, tabela przejścia: $(echo $przejscie | wc -l | tr -d ' ') wierszy"
brak=$(comm -23 <(echo $spis | uniq) <(echo $przejscie | uniq))
nadmiar=$(comm -13 <(echo $spis | uniq) <(echo $przejscie | uniq))
dupl=$(echo $przejscie | uniq -d)
[[ -n $brak ]] && echo "Brak w tabeli przejścia: $brak"
[[ -n $nadmiar ]] && echo "W tabeli, a nie w spisie: $nadmiar"
[[ -n $dupl ]] && echo "Powtórzone w tabeli: $dupl"
[[ -z $brak$nadmiar$dupl ]] && echo "OK: każda pozycja dokładnie raz."
