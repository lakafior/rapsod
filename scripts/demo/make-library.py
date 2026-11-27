#!/usr/bin/env python3
"""Biblioteka demonstracyjna do zrzutów w README (wymyślone książki i podcasty).

Użycie:
    python3 scripts/demo/make-library.py <folder wyjściowy>

Tworzy <folder>/Audiobooki/<Autor>/[<Seria>/]<Tytuł>/ z `metadata.json` (format
audiobookshelf), `cover.jpg` i jednym plikiem `.m4b` z rozdziałami, oraz
<folder>/Podcasty/<Podcast>/ z okładką, `metadata.json` i odcinkami `.m4a`.
Okładki rysuje `covers.swift` (CoreGraphics), dane są w `catalog.json`.

Nagrania są długie (godziny, jak prawdziwe audiobooki), ale prawie całe ciche:
krótka zapowiedź z `say -v Zosia` na początku, potem cisza AAC 8 kHz sklejana
bez ponownego kodowania — książka ma ok. 1–2 MB, a odtwarzanie w trakcie zrzutów
nic nie gra w głośnikach. Potrzebne: ffmpeg/ffprobe w PATH, `say`, `swift`.
"""
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def ffmeta_escape(text):
    for ch in "\\=;#\n":
        text = text.replace(ch, "\\" + ch)
    return text


def encode_speech(text, path, work):
    aiff = os.path.join(work, "say.aiff")
    run("say", "-v", "Zosia", "-o", aiff, text)
    run("ffmpeg", "-y", "-i", aiff, "-ar", "8000", "-ac", "1", "-c:a", "aac", "-b:a", "8k", path)


def assemble(parts, out, work, chapters=None, tags=None):
    """Skleja pliki AAC (ten sam format) bez kodowania; opcjonalnie rozdziały i tagi."""
    listing = os.path.join(work, "list.txt")
    with open(listing, "w") as f:
        for part in parts:
            f.write(f"file '{part}'\n")
    args = ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", listing]
    if chapters or tags:
        meta = os.path.join(work, "meta.txt")
        with open(meta, "w") as f:
            f.write(";FFMETADATA1\n")
            for key, value in (tags or {}).items():
                f.write(f"{key}={ffmeta_escape(str(value))}\n")
            for start, end, title in chapters or []:
                f.write(f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={int(start * 1000)}\nEND={int(end * 1000)}\ntitle={ffmeta_escape(title)}\n")
        args += ["-i", meta, "-map", "0:a", "-map_metadata", "1", "-map_chapters", "1"]
    args += ["-c", "copy", "-f", "mp4", out]
    run(*args)


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path],
                         check=True, capture_output=True, text=True).stdout
    return float(out.strip())


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = os.path.abspath(sys.argv[1])
    catalog = json.load(open(os.path.join(HERE, "catalog.json")))
    work = tempfile.mkdtemp(prefix="rapsod-demo-")
    covers = os.path.join(work, "covers")
    run("swift", os.path.join(HERE, "covers.swift"), os.path.join(HERE, "catalog.json"), covers)

    # Minuta ciszy w tym samym formacie co zapowiedzi.
    silence = os.path.join(work, "silence.m4a")
    run("ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono", "-t", "60", "-c:a", "aac", "-b:a", "8k", silence)
    minute = duration(silence)

    books_root = os.path.join(root, "Audiobooki")
    for index, book in enumerate(catalog["books"]):
        rng = random.Random(book["title"])
        folder = os.path.join(books_root, book["author"])
        if book.get("series"):
            folder = os.path.join(folder, book["series"])
        folder = os.path.join(folder, book["title"])
        os.makedirs(folder, exist_ok=True)
        shutil.copy(os.path.join(covers, f"book-{index}.jpg"), os.path.join(folder, "cover.jpg"))

        intro = os.path.join(work, f"intro-{index}.m4a")
        encode_speech(f"{book['title']}. {book['author']}. Czyta {book['narrator']}.", intro, work)
        intro_length = duration(intro)
        parts, chapters, position = [intro], [], 0.0
        count = book["chapters"]
        for n in range(count):
            minutes = max(4, round(book["minutes"] * rng.uniform(0.7, 1.3)))
            parts += [silence] * minutes
            length = minutes * minute + (intro_length if n == 0 else 0)
            if n == 0 and count > 6 and "Dla dzieci" not in book["genres"]:
                title = "Prolog"
            elif n == count - 1 and count > 6 and "Dla dzieci" not in book["genres"]:
                title = "Epilog"
            else:
                title = f"Rozdział {n if count > 6 and 'Dla dzieci' not in book['genres'] else n + 1}"
            chapters.append((position, position + length, title))
            position += length
        tags = {"title": book["title"], "artist": book["author"], "album": book["title"], "composer": book["narrator"],
                "genre": book["genres"][0], "date": book["year"]}
        assemble(parts, os.path.join(folder, f"{book['title']}.m4b"), work, chapters, tags)

        metadata = {
            "tags": [], "chapters": [],
            "title": book["title"], "subtitle": None,
            "authors": [book["author"]], "narrators": [book["narrator"]],
            "series": [f"{book['series']} #{book['seq']}"] if book.get("series") else [],
            "genres": book["genres"], "publishedYear": str(book["year"]), "publishedDate": None,
            "publisher": book["publisher"], "description": book["description"],
            "isbn": None, "asin": None, "language": "pl", "explicit": False, "abridged": False,
        }
        json.dump(metadata, open(os.path.join(folder, "metadata.json"), "w"), ensure_ascii=False, indent=2)
        print(f"książka {index + 1}/{len(catalog['books'])}: {book['title']} ({position / 3600:.1f} h)", flush=True)

    podcasts_root = os.path.join(root, "Podcasty")
    for index, podcast in enumerate(catalog["podcasts"]):
        folder = os.path.join(podcasts_root, podcast["title"])
        os.makedirs(folder, exist_ok=True)
        shutil.copy(os.path.join(covers, f"podcast-{index}.jpg"), os.path.join(folder, "cover.jpg"))
        metadata = {
            "tags": [], "title": podcast["title"], "author": podcast["author"], "description": podcast["description"],
            "releaseDate": None, "genres": podcast["genres"], "feedURL": None, "imageURL": None, "itunesPageURL": None,
            "itunesId": None, "itunesArtistId": None, "explicit": False, "language": "pl", "type": "episodic",
        }
        json.dump(metadata, open(os.path.join(folder, "metadata.json"), "w"), ensure_ascii=False, indent=2)
        for number, episode in enumerate(podcast["episodes"], start=1):
            intro = os.path.join(work, f"episode-{index}-{number}.m4a")
            encode_speech(f"{podcast['title']}. {episode['title']}.", intro, work)
            tags = {"title": episode["title"], "artist": podcast["author"], "album": podcast["title"], "date": episode["date"],
                    "comment": episode["description"], "description": episode["description"], "genre": "Podcast", "track": number}
            out = os.path.join(folder, f"{episode['date']} {episode['title']}.m4a")
            assemble([intro] + [silence] * episode["minutes"], out, work, tags=tags)
        print(f"podcast {index + 1}/{len(catalog['podcasts'])}: {podcast['title']}", flush=True)

    shutil.rmtree(work)
    print(f"gotowe: {root}")


if __name__ == "__main__":
    main()
