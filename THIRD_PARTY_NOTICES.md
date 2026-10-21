# Third-party notices

Manifield itself is licensed under the GNU General Public License v3.0 (see
[`LICENSE`](LICENSE)).
It redistributes the third-party components listed below, each under its own license. Every
component that is linked or combined into the program is GPLv3-compatible; the bundled maths
fonts are separately-licensed data files the program merely aggregates (GPLv3 §5). None of the
notices below alter the terms under which Manifield as a whole is offered.

| Component | Version | License | Where it lives |
|---|---|---|---|
| [KaTeX](https://katex.org) | 0.17.0 | MIT | `Manifield/Resources/web/vendor/katex/` |
| [marked](https://github.com/markedjs/marked) | 18.0.5 | MIT | `Manifield/Resources/web/vendor/marked.min.js` |
| [DOMPurify](https://github.com/cure53/DOMPurify) | 3.2.7 | Apache-2.0 **or** MPL-2.0 | `Manifield/Resources/web/vendor/purify.min.js` |
| [d3-force](https://d3js.org/d3-force) | 3.0.0 | ISC | `Manifield/Resources/web/vendor/d3-force.min.js` |
| [d3-dispatch](https://d3js.org/d3-dispatch) | 3.0.1 | ISC | `Manifield/Resources/web/vendor/d3-dispatch.min.js` |
| [d3-quadtree](https://d3js.org/d3-quadtree) | 3.0.1 | ISC | `Manifield/Resources/web/vendor/d3-quadtree.min.js` |
| [d3-timer](https://d3js.org/d3-timer) | 3.0.1 | ISC | `Manifield/Resources/web/vendor/d3-timer.min.js` |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 1.7.3 | MIT | Swift package dependency, linked into the app |
| SwiftMath bundled maths fonts | 12 `.otf` files | SIL OFL 1.1 (9), STIX Font License (1), GUST/LPPL 1.3c (2) | `Manifield.app/Contents/Resources/SwiftMath_SwiftMath.bundle/…/mathFonts.bundle/` |
| [Sparkle](https://sparkle-project.org) | 2.10.0 | MIT (plus the external licenses below) | Swift package dependency, embedded as `Sparkle.framework` |

The seven web libraries are vendored into the repository and copied into the built `.app` bundle.
[`Manifield/Resources/web/vendor/licenses/`](Manifield/Resources/web/vendor/licenses/) holds ten
unmodified upstream license files: one for each of those seven, SwiftMath's, Sparkle's, and SIL OFL
1.1 for the bundled maths fonts. That directory is a folder reference in
[`project.yml`](project.yml), so everything in it is copied into the `.app` verbatim and a
distributed build carries its own attribution. The web library versions are pinned in
[`Scripts/fetch_web_assets.sh`](Scripts/fetch_web_assets.sh), which re-fetches those assets and
their license files together — **update this file whenever you bump a version there.** That script
rebuilds only the files it fetches, so `sparkle-LICENSE.txt`, `swiftmath-LICENSE.txt` and
`OFL-1.1.txt` survive a re-run untouched; it warns on stderr if any of the three has gone missing.

SwiftMath and Sparkle are not vendored as code; they are resolved by Swift Package Manager at
build time, which is why their notices are reproduced here too. SwiftMath is linked into the
binary, and its `mathFonts.bundle` resource — 12 maths fonts plus their own license files — is
copied into `Manifield.app/Contents/Resources/`. Sparkle is embedded whole as
`Manifield.app/Contents/Frameworks/Sparkle.framework`, including its `Autoupdate` helper,
`Updater.app` and two XPC services; that framework carries **no** copy of its own license, which
is why one is vendored alongside the web libraries as described above.

---

## KaTeX 0.17.0

Copyright (c) 2013-2020 Khan Academy and other contributors

Full text: [`Manifield/Resources/web/vendor/licenses/katex-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/katex-LICENSE.txt)

```
The MIT License (MIT)

Copyright (c) 2013-2020 Khan Academy and other contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The bundled KaTeX fonts (`vendor/katex/fonts/*.woff2`) are part of the KaTeX
distribution and are covered by the same MIT license.

---

## marked 18.0.5

Copyright (c) 2018+, MarkedJS (https://github.com/markedjs/)
Copyright (c) 2011-2018, Christopher Jeffrey (https://github.com/chjj/)

Full text: [`Manifield/Resources/web/vendor/licenses/marked-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/marked-LICENSE.txt)

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

marked's license file additionally carries the original Markdown license
(Copyright © 2004, John Gruber, BSD 3-clause style); it is reproduced in full in
the bundled license file linked above.

---

## d3-force, d3-dispatch, d3-quadtree, d3-timer

Copyright 2010-2021 Mike Bostock

These four packages back the graph view's force-directed layout: `d3-force` is the
simulation itself, and `d3-dispatch`/`d3-quadtree`/`d3-timer` are its runtime
dependencies. All are released under the same ISC terms by the same author.

Full text: [`d3-force-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/d3-force-LICENSE.txt),
[`d3-dispatch-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/d3-dispatch-LICENSE.txt),
[`d3-quadtree-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/d3-quadtree-LICENSE.txt),
[`d3-timer-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/d3-timer-LICENSE.txt)

All four upstream `LICENSE` files are byte-identical; this is that text verbatim.

```
Copyright 2010-2021 Mike Bostock

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE.
```

---

## DOMPurify 3.2.7

Copyright 2025 Dr.-Ing. Mario Heiderich, Cure53

DOMPurify is dual-licensed; you may use it under **either** the Apache License
Version 2.0 **or** the Mozilla Public License Version 2.0. Both are GPLv3-compatible.

Because Apache-2.0 §4(a) and MPL-2.0 §3.1 require the license text to travel with
redistributed copies, the complete dual-license text ships unmodified at
[`Manifield/Resources/web/vendor/licenses/dompurify-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/dompurify-LICENSE.txt)
rather than being excerpted here.

```
DOMPurify
Copyright 2025 Dr.-Ing. Mario Heiderich, Cure53

DOMPurify is free software; you can redistribute it and/or modify it under the
terms of either:

a) the Apache License Version 2.0, or
b) the Mozilla Public License Version 2.0
```

DOMPurify is redistributed unmodified.

---

## SwiftMath 1.7.3

Copyright (c) 2023 Computer Inspirations

Resolved as a Swift Package Manager dependency (see [`project.yml`](project.yml), which floors it
at 1.6.0; 1.7.3 is what [`Package.resolved`](Manifield.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
pins) and linked into the shipped application. SwiftMath is licensed under the MIT license. The
canonical text is at <https://github.com/mgriebling/SwiftMath/blob/main/LICENSE> and an unmodified
copy ships at
[`Manifield/Resources/web/vendor/licenses/swiftmath-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/swiftmath-LICENSE.txt).

```
MIT License

Copyright (c) 2023 Computer Inspirations

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## SwiftMath bundled maths fonts

SwiftMath ships a `mathFonts.bundle` resource containing 12 OpenType maths fonts, one per entry of
its `MathFont` enum. Swift Package Manager copies that resource bundle whole into
`Manifield.app/Contents/Resources/SwiftMath_SwiftMath.bundle/Contents/Resources/mathFonts.bundle/`,
so all 12 are redistributed even though Manifield renders with SwiftMath's default font only
(`ItemNameText.swift` builds an `MTMathImage` and does not select a font). They are unmodified
runtime data files, not part of the program: nothing here derives from them or alters them.

Licenses and copyright notices below were read out of each font's own `name` table (IDs 0, 13 and
14) in the built bundle, not taken from upstream documentation:

| Font | License | Copyright |
|---|---|---|
| `Asana-Math.otf` | SIL OFL 1.1 | © 2007-2019 Apostolos Syropoulos; © 2000 Young Ryu; © 1997, 1999 Claudio Beccari |
| `Euler-Math.otf` | SIL OFL 1.1 | © 1997, 2009 American Mathematical Society; © 2009, 2021 Khaled Hosny; © 2022-2024 Daniel Flipo |
| `FiraMath-Regular.otf` | SIL OFL 1.1 | © 2018-2020 Xiangdong Zeng |
| `Garamond-Math.otf` | SIL OFL 1.1 | Copyleft © 2018-2022 Yuansheng Zhao and Xiangdong Zeng |
| `KpMath-Light.otf` | SIL OFL 1.1 | © 2007-2018 Christophe Caignaert, RFN "Kp"; © 2019-2024 Daniel Flipo, RFN "KpMath-Light" |
| `KpMath-Sans.otf` | SIL OFL 1.1 | © 2007-2018 Christophe Caignaert, RFN "Kp"; © 2019-2024 Daniel Flipo, RFN "KpMath-Sans" |
| `LeteSansMath.otf` | SIL OFL 1.1 | © 2024 Chenjing Bu, Daniel Flipo |
| `LibertinusMath-Regular.otf` | SIL OFL 1.1 | © 2012-2024 The Libertinus Project Authors |
| `NotoSansMath-Regular.otf` | SIL OFL 1.1 | © 2022 Google LLC |
| `xits-math.otf` | STIX Font License | © 2001-2011 the STI Pub Companies |
| `latinmodern-math.otf` | GUST Font License (LPPL 1.3c or later) | © 2012-2014 B. Jackowski, P. Strzelczyk and P. Pianowski, on behalf of TeX users groups |
| `texgyretermes-math.otf` | GUST Font License (LPPL 1.3c or later) | © 2012-2014 B. Jackowski, P. Strzelczyk and P. Pianowski, on behalf of TeX users groups |

SwiftMath's bundle already ships three license files beside the fonts, all verified present in
`build/export/Manifield.app`: `OFL.txt` — which is the **STIX** Font License, covering `xits-math`,
despite the filename — `GUST-FONT-LICENSE.txt`, covering the two GUST e-foundry fonts, and
`LICENSE` (MIT, © 2013 MathChat), covering the bundle's metadata plists and helper script.

That leaves the nine SIL OFL fonts. Only `Asana-Math.otf` and `LeteSansMath.otf` embed the full OFL
text in their `name` tables; the other seven carry the one-line notice and a URL. Since OFL 1.1 §2
asks for the license itself to accompany each copy, the canonical text — from
<https://openfontlicense.org/documents/OFL.txt> — is vendored at
[`Manifield/Resources/web/vendor/licenses/OFL-1.1.txt`](Manifield/Resources/web/vendor/licenses/OFL-1.1.txt)
and ships with every build. The per-font copyright notices its header calls for are the table above.

The two GUST/LPPL fonts are the only redistributed files here that the FSF classes as
GPL-incompatible. They are unmodified data files the program reads at runtime, so their presence in
the same bundle is mere aggregation under GPLv3 §5 and does not affect Manifield's own license.
LPPL 1.3c permits verbatim redistribution; nothing in the pipeline alters them.

---

## Sparkle 2.10.0

Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.

Resolved as a Swift Package Manager dependency (see [`project.yml`](project.yml)) and
embedded in the application bundle as `Sparkle.framework`. Sparkle is under the MIT license
and bundles four components under their own permissive licenses, reproduced in full below as
Sparkle's own `LICENSE` file does. The canonical text is at
<https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE>. The built framework contains no
copy of it, so an unmodified copy ships at
[`Manifield/Resources/web/vendor/licenses/sparkle-LICENSE.txt`](Manifield/Resources/web/vendor/licenses/sparkle-LICENSE.txt);
the block below is byte-identical to it.

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```
