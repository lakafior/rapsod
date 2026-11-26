// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Mały skrypt, który po wyjściu aplikacji podmienia jej pakiet na zweryfikowaną kopię
/// i uruchamia aplikację ponownie.
///
/// Kopia leży obok pakietu (ten sam folder, więc ten sam wolumin): podmiana to dwa
/// `rename(2)` — stary pakiet na nazwę zapasową, nowy na miejsce starego — z cofnięciem,
/// gdy drugi się nie uda. Stary pakiet znika dopiero po udanej podmianie. Bez względu na wynik
/// skrypt uruchamia to, co leży pod ścieżką aplikacji, żeby użytkownik nie został bez niej.
///
/// Ścieżki idą jako argumenty pozycyjne (`/bin/sh -c <skrypt> sh <pid> <app> <kopia> <zapas> <log> [argumenty…]`),
/// nie są wklejane w tekst skryptu. Argumenty po logu dostaje ponownie uruchomiona aplikacja
/// (np. `-ABSDataRoot` kopii testowej); `open -n`, bo inna kopia z tym samym identyfikatorem
/// może działać równolegle.
public enum SwapScript {
    /// Ile czekać na zakończenie aplikacji (zatrzymanie serwera trwa zwykle kilka sekund).
    public static let waitSeconds = 120

    public static let text = """
    pid="$1"; app="$2"; staged="$3"; backup="$4"; log="$5"
    shift 5
    exec >>"$log" 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S') podmiana: czekam na zakończenie procesu $pid"
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
      ticks=$((ticks + 1))
      if [ "$ticks" -gt \(waitSeconds * 10) ]; then
        echo "aplikacja nie zakończyła się w czasie — bez podmiany"
        exit 1
      fi
      sleep 0.1
    done
    if [ -d "$staged" ]; then
      rm -rf "$backup"
      if mv "$app" "$backup"; then
        if mv "$staged" "$app"; then
          rm -rf "$backup"
          echo "podmiana: gotowe"
        else
          echo "podmiana: nie udało się wstawić nowej wersji — przywracam poprzednią"
          mv "$backup" "$app"
          rm -rf "$staged"
        fi
      else
        echo "podmiana: nie udało się odsunąć bieżącej wersji"
        rm -rf "$staged"
      fi
    else
      echo "podmiana: brak kopii $staged"
    fi
    if [ "${RAPSOD_SWAP_NO_RELAUNCH:-}" != "1" ]; then
      /usr/bin/open -n "$app" --args "$@"
    fi
    """

    /// Argumenty dla `/bin/sh` (bez samej ścieżki powłoki).
    public static func arguments(pid: Int32, app: URL, staged: URL, backup: URL, log: URL, relaunchArguments: [String] = []) -> [String] {
        ["-c", text, "sh", String(pid), app.path, staged.path, backup.path, log.path] + relaunchArguments
    }

    /// Nazwa kopii nowej wersji obok pakietu, np. `.Rapsod-aktualizacja.app` (ukryta w Finderze).
    public static func stagedURL(for app: URL) -> URL {
        app.deletingLastPathComponent().appending(path: ".\(app.deletingPathExtension().lastPathComponent)-aktualizacja.app", directoryHint: .isDirectory)
    }

    /// Nazwa zapasowa bieżącego pakietu na czas podmiany.
    public static func backupURL(for app: URL) -> URL {
        app.deletingLastPathComponent().appending(path: ".\(app.deletingPathExtension().lastPathComponent)-poprzednia.app", directoryHint: .isDirectory)
    }
}
