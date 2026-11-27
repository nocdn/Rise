#!/usr/bin/env python3
"""Build the desktop synonym index from Princeton's wn3.1.dict.tar.gz."""
import sys
import tarfile
from collections import Counter, defaultdict
from pathlib import Path

output = Path(sys.argv[2])
with tarfile.open(sys.argv[1], "r:gz") as archive:
    def lines(name):
        with archive.extractfile("dict/" + name) as source:
            yield from (line.decode("ascii") for line in source)

    usage = Counter()
    for line in lines("index.sense"):
        key, _, _, frequency = line.split()
        usage[key.split("%", 1)[0]] += int(frequency)

    synsets = {}
    for pos in ("noun", "verb", "adj", "adv"):
        for line in lines("data." + pos):
            if not line[0].isdigit():
                continue
            offset, _, kind, count, *fields = line.partition("|")[0].split()
            word_end = 2 * int(count, 16)
            words = fields[:word_end:2]
            words = [word.split("(", 1)[0].lower() for word in words]
            pointers = fields[word_end+1:word_end+1+4*int(fields[word_end])]
            head = next((pointers[i+1] for i in range(0, len(pointers), 4)
                         if kind == "s" and pointers[i] == "&"), None)
            synsets[(pos, offset)] = (words, head)

    related = defaultdict(dict)
    for (pos, _), (words, head) in synsets.items():
        head_words = synsets.get((pos, head), ([], None))[0]
        for word in words:
            for candidate in set(words + head_words) - {word}:
                rank = 1 if candidate in words else 0
                related[word][candidate] = max(rank, related[word].get(candidate, 0))

    # Include WordNet's irregular inflections if they have no entry of their own.
    for pos in ("noun", "verb", "adj", "adv"):
        for line in lines(pos + ".exc"):
            inflection, *lemmas = line.split()
            if inflection not in related:
                for lemma in lemmas:
                    if related.get(lemma):
                        related[inflection].update(related[lemma])

    with output.open("w", encoding="utf-8", newline="\n") as index:
        for word, matches in sorted(related.items(), key=lambda item: item[0].replace("_", " ")):
            ranked = sorted(matches, key=lambda candidate: (-usage[candidate], -matches[candidate], candidate))
            if ranked:
                index.write(word.replace("_", " ") + "\t" + ", ".join(term.replace("_", " ") for term in ranked[:5]) + "\n")
