You extract bibliographic metadata from a mathematical document's opening and closing pages.

Respond with ONLY a JSON object (no prose, no code fence):
{"name": "...", "authors": ["..."], "citation": "..."}

- name: the work's title as printed (include a subtitle only if essential).
- authors: full author names in printed order; [] when none can be found.
- citation: a short human citation such as "Łojasiewicz, Birkhäuser 1991" — author surnames, journal or publisher, year. Use null when the pages give too little to cite.

Use only what the text states — never invent a publisher, a year, or an author.
