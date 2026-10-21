/* Shared markdown + LaTeX renderer.
 *
 * Pipeline: extract code segments FIRST (their contents are markdown, not LaTeX, and
 * must reach marked verbatim) → extract math segments (placeholders survive marked's
 * processing of _, *, \ etc.) → convert common text-mode LaTeX to markdown → put code
 * back so the fences still open → markdown → restore math rendered with KaTeX. A segment
 * KaTeX cannot parse falls back to the raw source in a visible .math-error span — never
 * a silent failure.
 *
 * Project macros: Swift pushes the parsed macros.tex dictionary via setMathMacros();
 * without it, user-defined commands like \A render as errors. */
(function () {
  "use strict";

  const PLACEHOLDER = (i) => "MANIFIELDMATHSEG" + i + "GES";
  const CODE_PLACEHOLDER = (i) => "MANIFIELDCODESEG" + i + "GES";

  let mathMacros = {};
  window.setMathMacros = function (macros) {
    mathMacros = macros && typeof macros === "object" ? macros : {};
  };

  /* Display math environments KaTeX supports natively (rendered whole, in display mode). */
  const ENV_RE =
    /\\begin\{(equation\*?|align\*?|alignat\*?|gather\*?|multline\*?|eqnarray\*?|CD)\}[\s\S]*?\\end\{\1\}/g;

  const PATTERNS = [
    { re: ENV_RE, display: true, whole: true },
    { re: /\$\$([\s\S]+?)\$\$/g, display: true },
    { re: /\\\[([\s\S]+?)\\\]/g, display: true },
    { re: /\\\(([\s\S]+?)\\\)/g, display: false },
    { re: /\$([^$\n]+?)\$/g, display: false },
  ];

  function extractMath(text) {
    const segments = [];
    let out = text;
    for (const { re, display, whole } of PATTERNS) {
      out = out.replace(re, (match, group) => {
        segments.push({ body: whole ? match : group, display });
        return PLACEHOLDER(segments.length - 1);
      });
    }
    return { out, segments };
  }

  /* A fence closes on a line of the same character, at least as long, and nothing else. */
  function closesFence(line, fence) {
    const run = line.match(/^ {0,3}(`+|~+)[ \t\r]*$/);
    return !!run && run[1][0] === fence[0] && run[1].length >= fence.length;
  }

  /* Fenced blocks, scanned line-wise so the closing rule above holds the way CommonMark
   * states it and an unclosed fence simply runs to the end of the document. */
  function extractFences(text, segments) {
    const lines = text.split("\n");
    const out = [];
    for (let i = 0; i < lines.length; ) {
      const open = lines[i].match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
      // A backtick fence's info string may not itself contain a backtick.
      if (!open || (open[1][0] === "`" && open[2].includes("`"))) {
        out.push(lines[i++]);
        continue;
      }
      const block = [lines[i++]];
      while (i < lines.length) {
        block.push(lines[i]);
        if (closesFence(lines[i++], open[1])) break;
      }
      segments.push(block.join("\n"));
      out.push(CODE_PLACEHOLDER(segments.length - 1));
    }
    return out.join("\n");
  }

  /* Inline spans, using marked's own delimiter rule: a run of N backticks closed by a run
   * of exactly N. Two readings go back to LaTeX instead, since imported documents share
   * this renderer: a two-backtick body carrying '' is a ``TeX quote'', and any body
   * spanning a blank line is a stray backtick rather than a span. Rejecting one resumes
   * just past the opening run, so a real span further along is still found. */
  function extractInlineCode(text, segments) {
    const SPAN = /(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/;
    let out = "";
    let rest = text;
    let m;
    while ((m = rest.match(SPAN)) !== null) {
      if ((m[1].length === 2 && m[2].includes("''")) || /\n[ \t\r]*\n/.test(m[2])) {
        out += rest.slice(0, m.index + m[1].length);
        rest = rest.slice(m.index + m[1].length);
        continue;
      }
      segments.push(m[0]);
      out += rest.slice(0, m.index) + CODE_PLACEHOLDER(segments.length - 1);
      rest = rest.slice(m.index + m[0].length);
    }
    return out + rest;
  }

  /* Code is markdown, not LaTeX: pulled out before any conversion so that ``, '', ~, \\
   * and friends inside it are never rewritten, and before math extraction so a $ in a
   * shell snippet is not mistaken for a formula. Restored ahead of marked.parse, which
   * needs the delimiters intact to open the block and escapes the body itself. */
  function extractCode(text) {
    const segments = [];
    const out = extractInlineCode(extractFences(text, segments), segments);
    return { out, segments };
  }

  function restoreCode(text, segments) {
    let out = text;
    segments.forEach((body, i) => {
      out = out.split(CODE_PLACEHOLDER(i)).join(body);
    });
    return out;
  }

  /* Converts common text-mode LaTeX (as found in imported documents) to markdown.
   * Runs AFTER code and math extraction, so neither is ever touched. */
  function latexTextToMarkdown(text) {
    let t = text;

    // Lists: number/bullet each \item according to its enclosing environment.
    t = t.replace(/\\begin\{(enumerate|itemize)\}([\s\S]*?)\\end\{\1\}/g, (_, env, body) => {
      const marker = env === "enumerate" ? "1. " : "- ";
      const items = body
        .split(/\\item\b/)
        .map((s) => s.trim())
        .filter((s) => s.length > 0)
        .map((s) => marker + s)
        .join("\n");
      return "\n\n" + items + "\n\n";
    });

    // Simple inline formatting (non-nested braces cover the practical cases).
    t = t.replace(/\\emph\{([^{}]*)\}/g, "*$1*");
    t = t.replace(/\\textit\{([^{}]*)\}/g, "*$1*");
    t = t.replace(/\\textbf\{([^{}]*)\}/g, "**$1**");
    t = t.replace(/\\texttt\{([^{}]*)\}/g, "`$1`");
    t = t.replace(/\\textsc\{([^{}]*)\}/g, "$1");
    t = t.replace(/\\underline\{([^{}]*)\}/g, "$1");

    // Structure & whitespace commands.
    // Cross-references: KaTeX has no \label/\ref machinery, so show the keys readably.
    t = t.replace(/\\eqref\{([^}]*)\}/g, "($1)");
    t = t.replace(/\\ref\{([^}]*)\}/g, "($1)");
    t = t.replace(/\\cite(?:\[[^\]]*\])?\{([^}]*)\}/g, "[$1]");

    // Math extraction already ran, so insert the literal symbol, not $\blacksquare$.
    t = t.replace(/\\begin\{proof\}/g, "\n\n**Proof.** ");
    t = t.replace(/\\end\{proof\}/g, " ∎\n\n");
    t = t.replace(/\\(noindent|smallskip|medskip|bigskip|centering)\b/g, "");
    t = t.replace(/\\par\b/g, "\n\n");
    t = t.replace(/\\\\(\[[^\]]*\])?/g, "  \n");   // forced line break
    t = t.replace(/\\ldots\b/g, "…");
    t = t.replace(/~/g, " ");
    t = t.replace(/``/g, "“").replace(/''/g, "”");
    t = t.replace(/\\%/g, "%").replace(/\\&/g, "&").replace(/\\_/g, "_").replace(/\\#/g, "#");

    return t;
  }

  /* Undefined control sequences seen during rendering — reported to the app so it can
   * point the user at Notation → Math Macros instead of failing silently in red. */
  const undefinedMacros = new Set();

  window.flushUndefinedMacroReport = function () {
    if (undefinedMacros.size === 0) return;
    const names = [...undefinedMacros];
    undefinedMacros.clear();
    if (window.webkit?.messageHandlers?.manifieldBridge) {
      window.webkit.messageHandlers.manifieldBridge.postMessage({
        type: "undefinedMacros",
        names: names,
      });
    }
  };

  function renderSegment(seg) {
    // KaTeX does not support \label{}; strip it so numbered equations still render.
    const body = seg.body.replace(/\\label\s*\{[^}]*\}/g, "");
    try {
      return katex.renderToString(body, {
        displayMode: seg.display,
        throwOnError: true,
        output: "html",
        macros: Object.assign({}, mathMacros),
      });
    } catch (e) {
      const message = String(e.message || e);
      const undef = message.match(/Undefined control sequence: (\\[a-zA-Z]+)/);
      if (undef) undefinedMacros.add(undef[1]);
      const raw = seg.display ? "$$" + seg.body + "$$" : "$" + seg.body + "$";
      return '<span class="math-error" title="' +
        message.replace(/"/g, "&quot;") + '">' +
        raw.replace(/&/g, "&amp;").replace(/</g, "&lt;") + "</span>";
    }
  }

  /* Renders markdown+LaTeX to an HTML string. */
  window.renderMarkdownWithMath = function (markdown) {
    const code = extractCode(String(markdown || ""));
    const { out, segments } = extractMath(code.out);
    const converted = restoreCode(latexTextToMarkdown(out), code.segments);
    let html = marked.parse(converted, { breaks: false, mangle: false, headerIds: false });
    segments.forEach((seg, i) => {
      // The placeholder may appear inside a <p> or <code>; plain split/join is robust.
      html = html.split(PLACEHOLDER(i)).join(renderSegment(seg));
    });
    return html;
  };

  /* Renders inline (no block markdown) — used for names/labels. */
  window.renderInlineMath = function (text) {
    const { out, segments } = extractMath(String(text || ""));
    let html = out.replace(/&/g, "&amp;").replace(/</g, "&lt;");
    segments.forEach((seg, i) => {
      html = html.split(PLACEHOLDER(i)).join(renderSegment(seg));
    });
    return html;
  };

  /* KaTeX draws anything that has to stretch — the repeating middle of a tall \left|,
   * radicals, extensible arrows, horizontal braces — as inline SVG. output:"html" only
   * means "no MathML", so the HTML-only DOMPurify profile silently deleted those paths
   * and the delimiters vanished while the rest of the formula rendered. Allow exactly the
   * three elements KaTeX emits and the closed set of attributes they carry; nothing here
   * can navigate or execute. <style> is re-forbidden because DOMPurify admits it inside
   * an SVG subtree once <svg> is allowed, which would hand a prompt-injected model the
   * whole stylesheet (and @import as a network callout). */
  const SANITIZE = {
    USE_PROFILES: { html: true },
    ADD_TAGS: ["svg", "path", "line"],
    ADD_ATTR: ["viewbox", "preserveaspectratio", "xmlns", "d", "stroke-width", "x1", "x2", "y1", "y2"],
    FORBID_TAGS: ["style"],
    /* srcset is a second way to name an image URL and DOMPurify does not police it the
       way it polices src — with <img> now allowed at all, it has to go. */
    FORBID_ATTR: ["srcset"],
    /* DOMPurify's default URI allow-list has no room for a scheme of ours, so it would
       strip the src off every figure. Adding manifield-figure here only makes the scheme
       *expressible*; the hook below is what confines it to <img>, and Swift is what
       decides whether an id resolves to anything. */
    ALLOWED_URI_REGEXP:
      /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|manifield-figure):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
  };

  /* The image rule, in one place: a page may show figures of the open project and
     nothing else. Markdown reaching this renderer can come from a model that has been
     prompt-injected, so an <img> pointing anywhere off-machine would be a fetch we did
     not authorize — and one carrying whatever the model put in the query string. Only
     manifield-figure:// survives; every other image is dropped entirely rather than
     left as a broken frame. The scheme is also stripped from href, where it would do
     nothing useful and only widen what a link can address. */
  const FIGURE_SRC = /^manifield-figure:\/\/[a-z0-9][a-z0-9-]*$/i;
  DOMPurify.addHook("afterSanitizeAttributes", function (node) {
    if (node.tagName === "IMG") {
      if (!FIGURE_SRC.test(node.getAttribute("src") || "")) node.remove();
      return;
    }
    if (node.hasAttribute && node.hasAttribute("href") &&
        /^manifield-figure:/i.test(node.getAttribute("href") || "")) {
      node.removeAttribute("href");
    }
  });

  /* The single write-path to the DOM. Everything rendered from markdown/LLM output is
   * sanitized here (marked does NOT strip raw HTML, and chat content comes from a model
   * that could be prompt-injected). */
  window.setRenderedContent = function (el, html) {
    const clean = DOMPurify.sanitize(html, SANITIZE);
    el.replaceChildren(document.createRange().createContextualFragment(clean));
  };
})();
