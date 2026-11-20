#!/bin/sh
# Uruchamia cloudflared jako proces potomny aplikacji i pilnuje, żeby nie przeżył aplikacji.
#
# Użycie: /bin/sh tunnel-watch.sh <cloudflared> <argumenty…> run
#
# Stdin to potok od aplikacji. Pierwsza linia to token tunelu — trafia do cloudflared
# przez `--token-file /dev/stdin`, więc nie ma go w argumentach (`ps`) ani w środowisku.
# Potem aplikacja trzyma potok otwarty. Gdy aplikacja go zamknie albo zniknie (także po
# SIGKILL), jądro zamyka potok, strażnik dostaje EOF i kończy cloudflared. Sam cloudflared
# nie reaguje na zamknięcie stdin, stąd ten pośrednik (macOS nie ma PR_SET_PDEATHSIG).

IFS= read -r token || exit 64
[ -n "$token" ] || exit 64

# Kopia stdin dla strażnika: w nieinteraktywnej powłoce zadania w tle dostają /dev/null
# zamiast stdin, ale jawnie przekazany deskryptor zostaje.
exec 3<&0

printf '%s' "$token" | "$@" --token-file /dev/stdin 3<&- &
child=$!
token=

(
    while IFS= read -r _ <&3; do :; done
    kill -TERM "$child" 2>/dev/null
    sleep 5
    kill -KILL "$child" 2>/dev/null
) &
watcher=$!
exec 3<&-

wait "$child"
status=$?
kill "$watcher" 2>/dev/null
exit "$status"
