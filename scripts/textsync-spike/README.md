# Próba synchronizacji tekstu z audio (etap 11)

Wyniki i wnioski: `ROADMAP.md`, „Tekst zsynchronizowany z audio”.

```bash
swiftc -O transcribe.swift -o /tmp/transcribe
/tmp/transcribe książka.m4b words.tsv            # czasy słów, DictationTranscriber pl-PL
python3 -I epub_sentences.py książka.epub sentences.json
python3 -I align.py sentences.json words.tsv aligned.json
```

Kod próbny, nie część aplikacji.
