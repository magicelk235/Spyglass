// Spyglass web previews. WebRenderer.swift injects the payload as
// `window.spyglassPayload` before this file runs:
//
//   { mode: "code" | "markdown" | "diff" | "notebook", text, language, theme,
//     fontSize, truncated, highlightLimit, baseURL, files, preamble, notebook }
//
// Whatever must be on screen when the preview appears is rendered before the
// page's load event, because the host waits for that. Highlighting, the rest
// of a long Markdown file or notebook and diagrams follow in short slices
// afterwards.
(function () {
  'use strict';

  const payload = window.spyglassPayload || { mode: 'code', text: '' };
  const root = document.documentElement;
  root.dataset.mode = payload.mode;
  if (payload.fontSize > 0) root.style.setProperty('--code-size', payload.fontSize + 'px');

  // Grammars compiled into highlight.min.js. Auto-detection only tries these:
  // running all 190-odd grammars over a sample takes far too long.
  const coreLanguages = hljs.listLanguages().filter(name => name !== 'plaintext');
  const darkScheme = window.matchMedia('(prefers-color-scheme: dark)');

  const MARKDOWN_SCRIPTS = [
    'vendor/markdown-it/markdown-it.min.js',
    'vendor/markdown-it-footnote/markdown-it-footnote.min.js',
    'vendor/markdown-it-task-lists/markdown-it-task-lists.min.js',
    'vendor/markdown-it-github-alerts/markdown-it-github-alerts.js',
    'vendor/markdown-it-dollarmath/markdown-it-dollarmath.min.js',
    'vendor/katex/katex.min.js',
  ];

  // Code mode lays text out in blocks of this many lines. Only the first
  // few are in the page when the preview appears; the rest follow, so a
  // 50,000-line file doesn't hold the preview up while it's laid out.
  const CODE_ROW_LINES = 400;
  const CODE_INITIAL_ROWS = 5;
  // Highlighting works on pieces of at most this many characters, so one
  // giant minified line is still coloured a bit at a time.
  const CODE_PIECE_CHARS = 32 * 1024;
  // A piece that ends inside a multi-line comment or string is highlighted
  // again together with the following pieces, up to this many characters.
  const CODE_MERGE_LIMIT = 256 * 1024;
  // Markdown tokens per rendering slice, and diff rows per slice.
  const MARKDOWN_SLICE_TOKENS = 2000;
  const DIFF_SLICE_ROWS = 1500;
  // The outline lists at most this many headings.
  const TOC_LIMIT = 400;
  // Code blocks in Markdown longer than this stay plain.
  const BLOCK_HIGHLIGHT_LIMIT = 512 * 1024;
  // Notebook cells rendered before the preview appears, then per slice.
  const NOTEBOOK_FIRST_CELLS = 24;
  const NOTEBOOK_SLICE_CELLS = 32;
  // Text outputs longer than this many lines start collapsed to their first
  // OUTPUT_COLLAPSED_LINES lines.
  const OUTPUT_COLLAPSE_LINES = 400;
  const OUTPUT_COLLAPSED_LINES = 200;
  // Output images past this many load only once scrolled near.
  const EAGER_IMAGES = 8;

  // MARK: - Plumbing

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' };
  function escapeHTML(text) {
    return String(text).replace(/[&<>"]/g, c => HTML_ESCAPES[c]);
  }

  function normalizeNewlines(text) {
    return text.indexOf('\r') === -1 ? text : text.replace(/\r\n?/g, '\n');
  }

  // Yields to the browser between slices of work. A message port, unlike a
  // timer, is never throttled while the page isn't visible yet.
  const channel = new MessageChannel();
  const waiting = [];
  channel.port1.onmessage = () => waiting.shift()();
  function nextTask() {
    return new Promise(resolve => {
      waiting.push(resolve);
      channel.port2.postMessage(0);
    });
  }

  const domReady = new Promise(resolve => {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => resolve(), { once: true });
    else resolve();
  });

  // Optional work waits for this so it never holds up the load event the
  // host is waiting on.
  const pageLoaded = new Promise(resolve => {
    if (document.readyState === 'complete') resolve();
    else window.addEventListener('load', () => resolve(), { once: true });
  }).then(nextTask);

  const scripts = new Map();
  function loadScript(src) {
    if (!scripts.has(src)) {
      scripts.set(src, new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = src;
        script.async = false;
        script.onload = () => resolve();
        script.onerror = () => reject(new Error('Could not load ' + src));
        document.head.appendChild(script);
      }));
    }
    return scripts.get(src);
  }

  function loadStyle(href) {
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = href;
    document.head.appendChild(link);
  }

  // Grammars outside the core build live in one large file that loads, after
  // the page, only when a preview needs one of them.
  let extraLanguages = null;
  function loadExtraLanguages() {
    if (!extraLanguages) {
      extraLanguages = pageLoaded
        .then(() => loadScript('vendor/highlight/languages.min.js'))
        .catch(error => console.error(error));
    }
    return extraLanguages;
  }

  function ensureLanguage(name) {
    if (!name) return Promise.resolve(false);
    if (hljs.getLanguage(name)) return Promise.resolve(true);
    return loadExtraLanguages().then(() => Boolean(hljs.getLanguage(name)));
  }

  function highlight(text, language) {
    try {
      return hljs.highlight(text, { language, ignoreIllegals: true });
    } catch (error) {
      console.error(error);
      return null;
    }
  }

  function detectLanguage(sample) {
    try {
      const result = hljs.highlightAuto(sample, coreLanguages);
      return result.relevance >= 5 ? result.language : null;
    } catch (error) {
      return null;
    }
  }

  // Links never navigate the preview. In-page anchors (table of contents,
  // footnotes) scroll; everything else does nothing.
  function handleLinkClick(event) {
    const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
    if (!link) return;
    event.preventDefault();
    const href = link.getAttribute('href') || '';
    if (event.type === 'click' && href.startsWith('#') && href.length > 1) {
      let id = href.slice(1);
      try { id = decodeURIComponent(id); } catch (error) { /* keep it as written */ }
      const target = document.getElementById(id) || document.getElementsByName(id)[0];
      if (target) target.scrollIntoView({ block: 'start' });
    }
  }
  document.addEventListener('click', handleLinkClick);
  document.addEventListener('auxclick', handleLinkClick);

  function showPlain(text, error) {
    if (error) console.error(error);
    document.body.textContent = '';
    if (!text) {
      document.body.append(element('div', 'empty', 'Nothing to show'));
      return;
    }
    const view = element('div', 'code-view');
    view.append(element('pre', 'source', normalizeNewlines(text)));
    document.body.append(view);
  }

  // MARK: - Code

  function renderCode(p) {
    const text = normalizeNewlines(p.text || '');
    if (!text) {
      document.body.append(element('div', 'empty', 'Empty file'));
      return;
    }
    const blocks = splitRows(text, CODE_ROW_LINES);
    const last = blocks[blocks.length - 1];
    const view = element('div', 'code-view');
    view.style.setProperty('--digits', String(String(last.firstLine + last.lines - 1).length));

    const rows = [];
    const pieces = [];
    for (const block of blocks) {
      const numbers = new Array(block.lines);
      for (let i = 0; i < block.lines; i++) numbers[i] = block.firstLine + i;
      const gutter = element('pre', 'gutter', numbers.join('\n'));
      gutter.setAttribute('aria-hidden', 'true');
      const code = element('code');
      // Plain text first; each piece is replaced once it's highlighted.
      for (const piece of splitPieces(block.text, CODE_PIECE_CHARS)) {
        pieces.push({ node: code.appendChild(element('span', null, piece)), text: piece });
      }
      const source = element('pre', 'source');
      source.append(code);
      const row = element('div', 'code-row');
      row.append(gutter, source);
      rows.push(row);
    }
    // Keeps the gutter running to the bottom of the window.
    const filler = element('div', 'code-row filler');
    filler.append(element('pre', 'gutter'));

    view.append(...rows.slice(0, CODE_INITIAL_ROWS), filler);
    document.body.append(view);
    if (rows.length > CODE_INITIAL_ROWS) {
      (async () => {
        await pageLoaded;
        for (let i = CODE_INITIAL_ROWS; i < rows.length; i += CODE_INITIAL_ROWS) {
          filler.before(...rows.slice(i, i + CODE_INITIAL_ROWS));
          await nextTask();
        }
      })().catch(error => console.error(error));
    }
    highlightCode(pieces, p.language, p.highlightLimit);
  }

  // Splits text into blocks of `size` lines: { text, firstLine, lines }.
  function splitRows(text, size) {
    const rows = [];
    let start = 0;
    let firstLine = 1;
    let lines = 0;
    let index = text.indexOf('\n');
    while (index !== -1) {
      lines += 1;
      if (lines === size) {
        rows.push({ text: text.slice(start, index + 1), firstLine, lines });
        start = index + 1;
        firstLine += lines;
        lines = 0;
      }
      index = text.indexOf('\n', index + 1);
    }
    if (start < text.length) {
      // A last line without a newline still counts.
      rows.push({ text: text.slice(start), firstLine, lines: lines + (text.endsWith('\n') ? 0 : 1) });
    }
    return rows;
  }

  // Cuts text into pieces of at most `max` characters: at line ends where
  // possible, otherwise after a space or punctuation.
  function splitPieces(text, max) {
    if (text.length <= max) return [text];
    const pieces = [];
    let start = 0;
    while (text.length - start > max) {
      let end = text.lastIndexOf('\n', start + max - 1) + 1;
      if (end <= start) end = breakPoint(text, start, start + max);
      pieces.push(text.slice(start, end));
      start = end;
    }
    pieces.push(text.slice(start));
    return pieces;
  }

  function breakPoint(text, start, limit) {
    for (let i = limit; i > limit - 2048 && i > start + 1; i--) {
      if (' \t;,})>'.includes(text[i - 1])) return i;
    }
    // Never between the two halves of a surrogate pair.
    const code = text.charCodeAt(limit - 1);
    return code >= 0xD800 && code <= 0xDBFF ? limit - 1 : limit;
  }

  function highlightCode(pieces, language, limit) {
    if (language === 'plaintext' || !pieces.length) return;
    const job = { pieces, next: 0, budget: limit > 0 ? limit : Infinity, name: null, top: null };
    const start = name => {
      job.name = name;
      job.top = hljs.getLanguage(name);
    };
    // The first piece is highlighted before the preview appears, so short
    // files never show up uncoloured.
    if (language && hljs.getLanguage(language)) {
      start(language);
      highlightSlice(job);
    }
    (async () => {
      await pageLoaded;
      if (!job.name) {
        const name = language || detectLanguage(sampleOf(pieces, 16 * 1024));
        if (!name || !(await ensureLanguage(name))) return;
        start(name);
      }
      while (highlightSlice(job)) await nextTask();
    })().catch(error => console.error(error));
  }

  function sampleOf(pieces, size) {
    let sample = '';
    for (const piece of pieces) {
      if (sample.length >= size) break;
      sample += piece.text;
    }
    return sample.slice(0, size);
  }

  // Highlights the next piece; false once there's nothing more to do or the
  // character budget is spent.
  function highlightSlice(job) {
    const pieces = job.pieces;
    if (job.next >= pieces.length || pieces[job.next].text.length > job.budget) return false;
    const first = job.next;
    let last = first;
    let text = pieces[first].text;
    let result = highlight(text, job.name);
    // Each call starts at the top level of the grammar. A piece that ended
    // inside a block comment or multi-line string is redone together with
    // the next pieces (twice as many each round) until it ends cleanly.
    // `_top` is the grammar mode highlight.js stopped in.
    let step = 1;
    while (result && result._top && result._top !== job.top && last + 1 < pieces.length && text.length < CODE_MERGE_LIMIT) {
      for (let i = 0; i < step && last + 1 < pieces.length; i++) {
        last += 1;
        text += pieces[last].text;
      }
      step *= 2;
      result = highlight(text, job.name);
    }
    if (!result) return false;
    if (first === last) pieces[first].node.innerHTML = result.value;
    else distribute(result.value, pieces.slice(first, last + 1));
    job.next = last + 1;
    job.budget -= text.length;
    return job.next < pieces.length;
  }

  // Splits the highlighted HTML of several consecutive pieces back into
  // them. Range.extractContents closes and reopens styled spans at each cut.
  function distribute(html, targets) {
    const holder = document.createElement('div');
    holder.innerHTML = html;
    for (let i = 0; i < targets.length - 1; i++) {
      const range = document.createRange();
      range.setStart(holder, 0);
      endRangeAfter(range, holder, targets[i].text.length);
      targets[i].node.replaceChildren(range.extractContents());
    }
    targets[targets.length - 1].node.replaceChildren(...holder.childNodes);
  }

  function endRangeAfter(range, root, length) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let remaining = length;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (node.length >= remaining) {
        range.setEnd(node, remaining);
        return;
      }
      remaining -= node.length;
    }
    range.setEnd(root, root.childNodes.length);
  }

  // MARK: - Markdown

  function renderMarkdown(p) {
    const source = normalizeNewlines(p.text || '');
    const layout = element('div', 'md-layout');
    const article = element('article', 'markdown-body');
    layout.append(article);
    document.body.append(layout);
    if (!source.trim()) {
      article.append(element('div', 'empty', 'Empty document'));
      return;
    }

    const md = createMarkdown();
    const { frontMatter, body } = splitFrontMatter(source);
    const env = {};
    const tokens = md.parse(body, env);
    // Code blocks waiting for syntax colors.
    let pending = [];

    if (frontMatter) {
      const pre = element('pre', 'front-matter');
      const code = element('code', null, frontMatter);
      code.dataset.lang = 'yaml';
      pre.append(code);
      article.append(pre);
      pending.push(code);
    }

    const toc = buildTOC(env.headings || []);
    if (toc) layout.append(toc);

    const slices = sliceTokens(tokens, MARKDOWN_SLICE_TOKENS);
    pending = pending.concat(appendMarkdown(article, md, slices[0] || [], env, p.baseURL));
    pending = highlightReadyBlocks(pending, 30);

    (async () => {
      await pageLoaded;
      for (let i = 1; i < slices.length; i++) {
        pending = pending.concat(appendMarkdown(article, md, slices[i], env, p.baseURL));
        pending = highlightReadyBlocks(pending, 8);
        await nextTask();
      }
      await highlightBlocks(pending);
    })().catch(error => console.error(error));
  }

  // `jupyter`: Markdown cells in a notebook, which follow Jupyter's math rules.
  function createMarkdown(options) {
    const jupyter = Boolean(options && options.jupyter);
    const md = window.markdownit({ html: true, linkify: true });
    md.use(window.markdownitFootnote)
      .use(window.markdownitTaskLists)
      .use(window.markdownitGitHubAlerts)
      .use(window.markdownitDollarmath.dollarmathPlugin, {
        // As on GitHub and in pandoc, "$5 and $10" is not math. Jupyter
        // also takes "$ x $", with spaces inside the dollars, as math.
        allow_space: jupyter,
        allow_digits: false,
        renderer: (tex, options) => renderMath(tex, options.displayMode),
      });

    md.renderer.rules.fence = (tokens, index) => {
      const token = tokens[index];
      const info = token.info ? md.utils.unescapeAll(token.info).trim() : '';
      const language = info.split(/\s+/)[0].toLowerCase();
      const content = token.content;
      if (language === 'mermaid') {
        // Shown as source until the diagram renders, and if it can't.
        return '<div class="mermaid-block"><pre><code>' + escapeHTML(content) + '</code></pre></div>\n';
      }
      if (language === 'math') {
        return '<div class="math block">' + renderMath(content, true) + '</div>\n';
      }
      const attribute = language ? ' data-lang="' + escapeHTML(language) + '"' : '';
      return '<pre><code' + attribute + '>' + escapeHTML(content) + '</code></pre>\n';
    };

    md.core.ruler.push('heading_ids', state => {
      const used = new Map();
      const headings = [];
      const tokens = state.tokens;
      for (let i = 0; i < tokens.length; i++) {
        const token = tokens[i];
        if (token.type !== 'heading_open') continue;
        const text = inlineText(tokens[i + 1]);
        const base = slugify(text) || 'section';
        const count = used.get(base) || 0;
        used.set(base, count + 1);
        const id = count ? base + '-' + count : base;
        token.attrSet('id', id);
        headings.push({ level: Number(token.tag.slice(1)), text, id });
      }
      state.env.headings = headings;
    });
    return md;
  }

  function renderMath(tex, displayMode) {
    try {
      return katex.renderToString(tex, { displayMode, throwOnError: false, strict: 'ignore' });
    } catch (error) {
      return '<code>' + escapeHTML(tex) + '</code>';
    }
  }

  function inlineText(token) {
    if (!token || !token.children) return '';
    let text = '';
    for (const child of token.children) {
      if (child.type === 'text' || child.type === 'code_inline') text += child.content;
    }
    return text.trim();
  }

  // GitHub's anchor rules: lowercase, punctuation dropped, spaces to dashes.
  function slugify(text) {
    return text.toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc}\- ]/gu, '').replace(/ /g, '-');
  }

  // YAML front matter (Jekyll, Hugo, MDX) shows as a code block rather than
  // as a rule followed by a paragraph of keys.
  function splitFrontMatter(text) {
    if (!/^---[ \t]*\n[\w.-]+[ \t]*:/.test(text)) return { frontMatter: null, body: text };
    const close = /\n(?:---|\.\.\.)[ \t]*(?:\n|$)/g;
    close.lastIndex = 3;
    const match = close.exec(text);
    if (!match || match.index > 64 * 1024) return { frontMatter: null, body: text };
    return {
      frontMatter: text.slice(text.indexOf('\n') + 1, match.index + 1),
      body: text.slice(match.index + match[0].length),
    };
  }

  // Splits the token stream between top-level blocks.
  function sliceTokens(tokens, size) {
    const slices = [];
    let start = 0;
    for (let i = 0; i < tokens.length; i++) {
      const token = tokens[i];
      if (token.level === 0 && token.nesting <= 0 && i + 1 - start >= size) {
        slices.push(tokens.slice(start, i + 1));
        start = i + 1;
      }
    }
    if (start < tokens.length) slices.push(tokens.slice(start));
    return slices;
  }

  // Renders one slice into the article and returns its code blocks for
  // highlighting. Diagrams are queued for drawing straight away.
  // `attachments` maps a notebook cell's attachment names to data URLs.
  function appendMarkdown(article, md, tokens, env, baseURL, attachments) {
    const template = document.createElement('template');
    template.innerHTML = md.renderer.render(tokens, md.options, env);
    const fragment = template.content;
    if (containsHTML(tokens)) sanitize(fragment);
    resolveImages(fragment, baseURL, attachments);
    const code = Array.from(fragment.querySelectorAll('pre > code[data-lang]'));
    const diagrams = Array.from(fragment.querySelectorAll('.mermaid-block'));
    article.append(fragment);
    queueDiagrams(diagrams);
    return code;
  }

  function containsHTML(tokens) {
    return tokens.some(token => token.type === 'html_block'
      || (token.type === 'inline' && token.children && token.children.some(child => child.type === 'html_inline')));
  }

  // Raw HTML in Markdown is kept, as on GitHub, minus anything that could run
  // code, restyle the page or load something. The page's CSP already blocks
  // scripts and network loads; this keeps the preview looking like a README.
  const UNSAFE_ELEMENTS = 'script, style, link, meta, base, title, iframe, frame, frameset, object, embed, applet, '
    + 'form, button, textarea, select, noscript, template, audio, video, portal, dialog, slot';
  const URL_ATTRIBUTES = new Set(['href', 'src', 'xlink:href', 'action', 'formaction', 'background', 'poster', 'cite', 'data']);

  function sanitize(fragment) {
    fragment.querySelectorAll(UNSAFE_ELEMENTS).forEach(node => node.remove());
    fragment.querySelectorAll('input:not([type="checkbox"])').forEach(node => node.remove());
    for (const node of fragment.querySelectorAll('*')) {
      for (const attribute of Array.from(node.attributes)) {
        const name = attribute.name.toLowerCase();
        const value = attribute.value;
        if (name.startsWith('on') || name === 'srcset' || name === 'ping') {
          node.removeAttribute(attribute.name);
        } else if (URL_ATTRIBUTES.has(name) && /^\s*(?:javascript|vbscript|data):/i.test(value)
                   && !(name === 'src' && node.tagName === 'IMG' && /^\s*data:image\//i.test(value))) {
          node.removeAttribute(attribute.name);
        }
      }
    }
  }

  // Local images load through the host's spyglass-local: handler, which
  // serves only image files the extension can read. Remote images and any
  // that fail are removed, so there are never broken-image icons.
  function resolveImages(fragment, baseURL, attachments) {
    fragment.querySelectorAll('picture > source, svg image').forEach(node => node.remove());
    for (const image of Array.from(fragment.querySelectorAll('img'))) {
      const url = localImageURL(image.getAttribute('src'), baseURL, attachments);
      if (!url) {
        removeImage(image);
        continue;
      }
      image.setAttribute('src', url);
      image.addEventListener('error', () => removeImage(image), { once: true });
    }
  }

  function localImageURL(src, baseURL, attachments) {
    const value = (src || '').trim();
    if (!value) return null;
    if (/^data:image\//i.test(value)) return value;
    if (/^attachment:/i.test(value)) return attachments ? attachmentURL(attachments, value.slice(11)) : null;
    if (!baseURL) return null;
    let url;
    try {
      url = new URL(value, baseURL);
    } catch (error) {
      return null;
    }
    if (url.protocol !== 'file:' || url.host) return null;
    return 'spyglass-local://' + url.pathname;
  }

  function attachmentURL(attachments, name) {
    if (attachments.has(name)) return attachments.get(name);
    try {
      return attachments.get(decodeURIComponent(name)) || null;
    } catch (error) {
      return null;
    }
  }

  function removeImage(image) {
    let parent = image.parentNode;
    image.remove();
    // Drop wrappers the image leaves empty, such as badge links and
    // centred paragraphs, so they don't leave gaps.
    while (parent && parent.nodeType === Node.ELEMENT_NODE
           && /^(?:A|P|PICTURE|FIGURE|CENTER)$/.test(parent.tagName)
           && parent.textContent.trim() === ''
           && !parent.querySelector('img, svg, math, input')) {
      const next = parent.parentNode;
      parent.remove();
      parent = next;
    }
  }

  function highlightBlock(code) {
    const text = code.textContent;
    if (text.length > BLOCK_HIGHLIGHT_LIMIT) return;
    const result = highlight(text, code.dataset.lang);
    if (result) code.innerHTML = result.value;
  }

  const PLAIN_FENCES = new Set(['text', 'txt', 'plain', 'plaintext', 'output', 'log', 'none', 'nohighlight']);

  // Highlights queued blocks whose grammar is loaded, for up to `budget` ms,
  // and returns the blocks still waiting.
  function highlightReadyBlocks(queue, budget) {
    const started = performance.now();
    const waiting = [];
    for (const code of queue) {
      const name = code.dataset.lang;
      if (PLAIN_FENCES.has(name)) continue;
      if (!hljs.getLanguage(name)) {
        loadExtraLanguages();
        waiting.push(code);
      } else if (performance.now() - started < budget) {
        highlightBlock(code);
      } else {
        waiting.push(code);
      }
    }
    return waiting;
  }

  async function highlightBlocks(queue) {
    for (const code of queue) {
      if (await ensureLanguage(code.dataset.lang)) highlightBlock(code);
      await nextTask();
    }
  }

  // Mermaid is large, so it loads after the page, and only for documents
  // with a diagram. Diagrams draw one at a time, in document order.
  const diagrams = [];
  let diagramQueue = pageLoaded;
  let mermaidLoaded = null;
  let diagramCount = 0;

  function queueDiagrams(blocks) {
    if (!blocks.length) return;
    const added = blocks.map(block => ({ block, source: block.textContent }));
    diagrams.push(...added);
    diagramQueue = diagramQueue.then(() => drawDiagrams(added)).catch(error => console.error(error));
  }

  async function drawDiagrams(list) {
    if (!(await loadMermaid())) {
      list.forEach(diagram => showDiagramError(diagram, 'Diagram support failed to load.'));
      return;
    }
    for (const diagram of list) {
      await drawDiagram(diagram);
      await nextTask();
    }
  }

  function loadMermaid() {
    if (!mermaidLoaded) {
      mermaidLoaded = loadScript('vendor/mermaid/mermaid.min.js').then(() => {
        configureMermaid();
        // Diagram colours are baked into the SVG, so redraw when the theme flips.
        darkScheme.addEventListener('change', () => {
          configureMermaid();
          const all = diagrams.slice();
          diagramQueue = diagramQueue.then(() => drawDiagrams(all)).catch(error => console.error(error));
        });
        return true;
      }, error => {
        console.error(error);
        return false;
      });
    }
    return mermaidLoaded;
  }

  function configureMermaid() {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: 'strict',
      theme: darkScheme.matches ? 'dark' : 'default',
      fontFamily: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif',
    });
  }

  async function drawDiagram(diagram) {
    const id = 'diagram-' + (++diagramCount);
    try {
      const { svg } = await mermaid.render(id, diagram.source);
      diagram.block.innerHTML = svg;
    } catch (error) {
      // A failed render can leave its scratch element behind.
      const scratch = document.getElementById('d' + id);
      if (scratch) scratch.remove();
      showDiagramError(diagram, 'Diagram error: ' + ((error && error.message) || error));
    }
  }

  function showDiagramError(diagram, message) {
    const block = diagram.block;
    block.textContent = '';
    const pre = element('pre');
    pre.append(element('code', null, diagram.source));
    block.append(pre, element('pre', 'render-error', message.slice(0, 600)));
  }

  // Outline beside the text, with the section in view highlighted. Hidden
  // by CSS when the window is narrow.
  function buildTOC(headings) {
    if (headings.length < 3) return null;
    const top = headings.reduce((lowest, heading) => Math.min(lowest, heading.level), 6);
    const entries = headings.filter(heading => heading.level <= top + 2).slice(0, TOC_LIMIT);
    const nav = element('nav', 'toc');
    nav.append(element('p', 'toc-title', 'Contents'));
    const list = element('ol');
    const links = new Map();
    for (const heading of entries) {
      const item = element('li');
      const link = element('a', 'depth-' + (heading.level - top + 1), heading.text || 'Untitled');
      link.setAttribute('href', '#' + encodeURIComponent(heading.id));
      link.title = heading.text;
      item.append(link);
      list.append(item);
      links.set(heading.id, link);
    }
    nav.append(list);
    trackScroll(nav, entries, links);
    return nav;
  }

  function trackScroll(nav, entries, links) {
    let active = null;
    let scheduled = false;
    const update = () => {
      scheduled = false;
      let current = entries[0].id;
      // Once scrolled to the very end, the last heading counts as current
      // even if it never reaches the top of the window.
      const scroller = document.documentElement;
      const atBottom = window.scrollY > 0 && window.innerHeight + window.scrollY >= scroller.scrollHeight - 2;
      for (const heading of entries) {
        const target = document.getElementById(heading.id);
        if (!target) break;
        if (!atBottom && target.getBoundingClientRect().top > 80) break;
        current = heading.id;
      }
      if (current === active) return;
      if (active) links.get(active).classList.remove('active');
      active = current;
      const link = links.get(active);
      link.classList.add('active');
      if (link.offsetTop < nav.scrollTop || link.offsetTop + link.offsetHeight > nav.scrollTop + nav.clientHeight) {
        nav.scrollTop = link.offsetTop - nav.clientHeight / 2;
      }
    };
    const schedule = () => {
      if (scheduled) return;
      scheduled = true;
      setTimeout(update, 50);
    };
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    pageLoaded.then(update);
  }

  // MARK: - Diff

  function renderDiff(p) {
    const files = p.files || [];
    const view = element('div', 'diff-view');
    document.body.append(view);
    const preamble = p.preamble && p.preamble.trim() ? element('pre', 'diff-preamble', p.preamble) : null;
    if (preamble) view.append(preamble);
    if (!files.length) {
      view.append(element('div', 'empty', 'No changes'));
      return;
    }

    const panel = element('div', 'diff-panel');
    const bar = element('div', 'diff-tabs');
    const sections = new Map();
    let tabs = [];
    let current = -1;
    const show = index => {
      if (index === current) return;
      if (current >= 0) {
        sections.get(current).hidden = true;
        tabs[current].classList.remove('active');
        // Start the newly picked file at its top. The tabs stick to the top
        // of the window once the preamble has scrolled away.
        const tabsTop = preamble ? preamble.offsetHeight : 0;
        window.scrollTo(window.scrollX, Math.min(window.scrollY, tabsTop));
      }
      current = index;
      let section = sections.get(index);
      if (!section) {
        section = renderDiffFile(files[index]);
        sections.set(index, section);
        panel.append(section);
      }
      section.hidden = false;
      if (tabs[index]) tabs[index].classList.add('active');
    };

    if (files.length > 1) {
      bar.setAttribute('role', 'tablist');
      tabs = files.map((file, index) => {
        const tab = element('button', 'diff-tab');
        tab.type = 'button';
        tab.setAttribute('role', 'tab');
        tab.title = displayPath(file);
        tab.append(element('span', 'name', baseName(file)), diffStat(file));
        tab.addEventListener('click', () => show(index));
        bar.append(tab);
        return tab;
      });
      view.append(bar);
    }
    view.append(panel);
    show(0);
  }

  function filePath(file) {
    return file.newPath || file.oldPath || 'unknown';
  }

  function displayPath(file) {
    if ((file.status === 'renamed' || file.status === 'copied') && file.oldPath && file.newPath) {
      return file.oldPath + ' → ' + file.newPath;
    }
    return filePath(file);
  }

  function baseName(file) {
    const path = filePath(file);
    return path.slice(path.lastIndexOf('/') + 1) || path;
  }

  function diffStat(file) {
    const stat = element('span', 'diff-stat');
    if (file.additions) stat.append(element('span', 'plus', '+' + file.additions));
    if (file.additions && file.deletions) stat.append(' ');
    if (file.deletions) stat.append(element('span', 'minus', '−' + file.deletions));
    return stat;
  }

  function badge(kind, text) {
    return element('span', 'badge ' + kind, text);
  }

  function renderDiffFile(file) {
    const section = element('section', 'diff-file');
    const header = element('div', 'diff-file-header');
    switch (file.status) {
      case 'added': header.append(badge('added', 'New file')); break;
      case 'deleted': header.append(badge('deleted', 'Deleted')); break;
      case 'renamed':
        header.append(badge('renamed', file.similarity != null && file.similarity < 100 ? 'Renamed ' + file.similarity + '%' : 'Renamed'));
        break;
      case 'copied': header.append(badge('copied', 'Copied')); break;
    }
    if (file.oldMode && file.newMode && file.oldMode !== file.newMode) {
      header.append(badge('mode', file.oldMode + ' → ' + file.newMode));
    }
    if (file.isBinary) header.append(badge('binary', 'Binary'));
    if ((file.status === 'renamed' || file.status === 'copied') && file.oldPath && file.newPath) {
      header.append(element('span', 'path', file.oldPath), element('span', 'arrow', '→'), element('span', 'path', file.newPath));
    } else {
      header.append(element('span', 'path', filePath(file)));
    }
    header.append(diffStat(file));
    section.append(header);

    if (file.isBinary) {
      section.append(element('div', 'diff-note', 'Binary file not shown.'));
      return section;
    }
    if (!file.hunks.length) {
      section.append(element('div', 'diff-note', emptyDiffNote(file)));
      return section;
    }

    const table = element('table', 'diff');
    section.append(table);
    const rows = diffRows(file);
    const appendSlice = start => {
      const body = document.createElement('tbody');
      body.innerHTML = rows.slice(start, start + DIFF_SLICE_ROWS).join('');
      table.append(body);
    };
    appendSlice(0);
    if (rows.length > DIFF_SLICE_ROWS) {
      (async () => {
        await pageLoaded;
        for (let start = DIFF_SLICE_ROWS; start < rows.length; start += DIFF_SLICE_ROWS) {
          appendSlice(start);
          await nextTask();
        }
      })().catch(error => console.error(error));
    }
    return section;
  }

  function emptyDiffNote(file) {
    if (file.oldMode && file.newMode && file.oldMode !== file.newMode) return 'File mode changed.';
    switch (file.status) {
      case 'renamed': return 'File renamed without changes.';
      case 'copied': return 'File copied without changes.';
      case 'added': return 'Empty file added.';
      case 'deleted': return 'Empty file deleted.';
      default: return 'No content changes.';
    }
  }

  function hunkRange(start, count) {
    return count === 1 ? String(start) : start + ',' + count;
  }

  function diffRows(file) {
    const rows = [];
    for (const hunk of file.hunks) {
      const header = '@@ -' + hunkRange(hunk.oldStart, hunk.oldCount) + ' +' + hunkRange(hunk.newStart, hunk.newCount) + ' @@'
        + (hunk.heading ? ' ' + hunk.heading : '');
      rows.push('<tr class="hunk"><td class="num"></td><td class="num"></td><td class="text">' + escapeHTML(header) + '</td></tr>');
      for (const line of hunk.lines) rows.push(diffRow(line));
    }
    return rows;
  }

  function diffRow(line) {
    const oldLine = line.oldLine == null ? '' : line.oldLine;
    const newLine = line.newLine == null ? '' : line.newLine;
    let kind = 'ctx';
    let marker = ' ';
    switch (line.kind) {
      case 'added': kind = 'add'; marker = '+'; break;
      case 'removed': kind = 'del'; marker = '-'; break;
      case 'noNewline':
        return '<tr class="eof"><td class="num"></td><td class="num"></td><td class="text"><span class="marker">⊘</span>'
          + escapeHTML(line.text || 'No newline at end of file') + '</td></tr>';
    }
    return '<tr class="' + kind + '"><td class="num">' + oldLine + '</td><td class="num">' + newLine
      + '</td><td class="text"><span class="marker">' + marker + '</span>' + escapeHTML(line.text) + '</td></tr>';
  }

  // MARK: - Notebook

  function renderNotebook(p) {
    const notebook = p.notebook || {};
    const cells = notebook.cells || [];
    const view = element('div', 'nb-view');
    document.body.append(view);
    if (!cells.length) {
      view.append(element('div', 'empty', 'Empty notebook'));
      return;
    }
    view.style.setProperty('--prompt-chars', String(promptWidth(cells)));
    const context = {
      md: createMarkdown({ jupyter: true }),
      baseURL: p.baseURL,
      language: notebook.language || null,
      // Code blocks waiting for syntax colors.
      pending: [],
      // Code cells rendered before their language was guessed.
      unguessed: [],
      guessed: Boolean(notebook.language),
      images: 0,
    };
    const first = Math.min(cells.length, NOTEBOOK_FIRST_CELLS);
    for (let i = 0; i < first; i++) view.append(renderCell(cells[i], context));
    context.pending = highlightReadyBlocks(context.pending, 30);

    (async () => {
      await pageLoaded;
      if (!context.guessed) {
        context.language = guessCellLanguage(cells);
        context.guessed = true;
        if (context.language) {
          context.unguessed.forEach(code => { code.dataset.lang = context.language; });
          context.pending = context.pending.concat(context.unguessed);
        }
        context.unguessed = [];
      }
      // Kernels such as Julia or Scala need the extra grammars.
      if (context.language) await ensureLanguage(context.language);
      context.pending = highlightReadyBlocks(context.pending, 16);
      for (let start = first; start < cells.length; start += NOTEBOOK_SLICE_CELLS) {
        const fragment = document.createDocumentFragment();
        const end = Math.min(cells.length, start + NOTEBOOK_SLICE_CELLS);
        for (let i = start; i < end; i++) fragment.append(renderCell(cells[i], context));
        view.append(fragment);
        context.pending = highlightReadyBlocks(context.pending, 8);
        await nextTask();
      }
      await highlightBlocks(context.pending);
    })().catch(error => console.error(error));
  }

  // Characters in the widest prompt: "In [" or "Out[", the number, "]:".
  function promptWidth(cells) {
    let largest = 0;
    for (const cell of cells) {
      if (cell.count > largest) largest = cell.count;
      for (const output of cell.outputs || []) {
        if (output.count > largest) largest = output.count;
      }
    }
    return String(largest).length + 6;
  }

  // For notebooks that don't name their kernel's language.
  function guessCellLanguage(cells) {
    let sample = '';
    for (const cell of cells) {
      if (sample.length >= 16 * 1024) break;
      if (cell.type === 'code' && cell.source) sample += cell.source + '\n';
    }
    return sample.trim() ? detectLanguage(sample.slice(0, 16 * 1024)) : null;
  }

  // One cell; a cell that fails to render shows its source as plain text.
  function renderCell(cell, context) {
    try {
      switch (cell.type) {
        case 'markdown': return renderMarkdownCell(cell, context);
        case 'code': return renderCodeCell(cell, context);
        default: return renderRawCell(cell);
      }
    } catch (error) {
      console.error(error);
      return renderRawCell(cell);
    }
  }

  function renderMarkdownCell(cell, context) {
    const row = element('div', 'nb-cell nb-markdown');
    const body = element('div', 'markdown-body');
    row.append(element('div', 'nb-prompt'), body);
    const source = normalizeNewlines(cell.source || '');
    if (!source.trim()) return row;
    const attachments = new Map((cell.attachments || []).map(attachment => [attachment.name, attachment.url]));
    const env = {};
    const tokens = context.md.parse(source, env);
    context.pending = context.pending.concat(appendMarkdown(body, context.md, tokens, env, context.baseURL, attachments));
    return row;
  }

  function renderCodeCell(cell, context) {
    const row = element('div', 'nb-cell nb-code');
    const input = element('div', 'nb-input');
    const prompt = element('div', 'nb-prompt', 'In [' + (cell.count != null ? cell.count : ' ') + ']:');
    const code = element('code', null, normalizeNewlines(cell.source || ''));
    const source = element('pre', 'nb-source');
    source.append(code);
    input.append(prompt, source);
    row.append(input);
    if (context.language) {
      code.dataset.lang = context.language;
      context.pending.push(code);
    } else if (!context.guessed) {
      context.unguessed.push(code);
    }

    const outputs = cell.outputs || [];
    if (outputs.length) {
      const area = element('div', 'nb-outputs');
      for (const output of outputs) {
        const node = renderOutput(output, context);
        if (node) area.append(node);
      }
      row.append(area);
    }
    return row;
  }

  function renderRawCell(cell) {
    const row = element('div', 'nb-cell nb-raw');
    row.append(element('div', 'nb-prompt'), element('pre', 'nb-raw-source', normalizeNewlines(cell.source || '')));
    return row;
  }

  // One output: the host has already picked the representation to show.
  function renderOutput(output, context) {
    const row = element('div', 'nb-output');
    const prompt = element('div', 'nb-prompt', output.count != null ? 'Out[' + output.count + ']:' : '');
    const body = element('div', 'nb-output-body');
    row.append(prompt, body);
    switch (output.type) {
      case 'stream':
        if (output.name === 'stderr') body.classList.add('nb-stderr');
        appendTerminalText(body, output.text);
        break;
      case 'text':
        appendTerminalText(body, output.text);
        break;
      case 'error':
        body.classList.add('nb-error');
        appendTerminalText(body, output.text);
        break;
      case 'image':
        body.append(outputImage(output, context));
        break;
      case 'omitted':
        body.append(element('div', 'nb-omitted', 'Image not shown (' + formatSize(output.size) + ')'));
        break;
      case 'html':
        appendOutputHTML(body, output.html || '', context);
        break;
      case 'markdown':
        appendOutputMarkdown(body, output.text || '', context);
        break;
      case 'latex':
        appendOutputLatex(body, output.text || '', context);
        break;
      default:
        return null;
    }
    return row;
  }

  function outputImage(output, context) {
    const image = document.createElement('img');
    image.alt = '';
    image.decoding = 'async';
    context.images += 1;
    if (context.images > EAGER_IMAGES) image.loading = 'lazy';
    if (output.width > 0) image.width = output.width;
    if (output.height > 0) image.height = output.height;
    if (output.background) image.dataset.background = output.background;
    image.addEventListener('error', () => {
      image.replaceWith(element('div', 'nb-omitted', 'Image can’t be shown'));
    }, { once: true });
    image.src = 'data:' + output.mime + ';base64,' + output.data;
    return image;
  }

  // HTML outputs get the same treatment as raw HTML in Markdown: no
  // scripts, frames, styles or event handlers, and no remote images.
  // Interactive plots and widgets are mostly script, so little may be left.
  function appendOutputHTML(body, html, context) {
    const template = document.createElement('template');
    template.innerHTML = html;
    const fragment = template.content;
    sanitize(fragment);
    resolveImages(fragment, context.baseURL);
    if (!fragment.textContent.trim() && !fragment.querySelector('img, svg, math, table, hr, input')) {
      body.append(element('div', 'nb-omitted', 'Interactive output not shown'));
      return;
    }
    body.classList.add('nb-html');
    body.append(fragment);
  }

  function appendOutputMarkdown(body, text, context) {
    body.classList.add('markdown-body');
    const env = {};
    const tokens = context.md.parse(normalizeNewlines(text), env);
    context.pending = context.pending.concat(appendMarkdown(body, context.md, tokens, env, context.baseURL));
  }

  // Jupyter hands LaTeX output to MathJax delimiters and all; KaTeX wants
  // the math alone. Text with math inside it goes through Markdown.
  function appendOutputLatex(body, text, context) {
    const source = text.trim();
    const match = /^(?:\$\$([\s\S]+)\$\$|\\\[([\s\S]+)\\\]|\$([\s\S]+)\$|\\\(([\s\S]+)\\\))$/.exec(source);
    const math = match ? match[1] || match[2] || match[3] || match[4] : source;
    if (math.includes('$')) {
      appendOutputMarkdown(body, source, context);
      return;
    }
    body.classList.add('nb-latex');
    body.innerHTML = renderMath(math, true);
  }

  // Streams, plain-text results and tracebacks, as the styled runs the host
  // made of their ANSI codes. Long text starts collapsed.
  function appendTerminalText(body, runs) {
    runs = runs || [];
    const pre = element('pre', 'nb-text');
    body.append(pre);
    const total = countLines(runs);
    if (total <= OUTPUT_COLLAPSE_LINES) {
      pre.innerHTML = runsHTML(runs, Infinity);
      return;
    }
    const toggle = element('button', 'nb-toggle');
    toggle.type = 'button';
    let expanded = false;
    const show = () => {
      pre.innerHTML = runsHTML(runs, expanded ? Infinity : OUTPUT_COLLAPSED_LINES);
      pre.classList.toggle('collapsed', !expanded);
      toggle.textContent = expanded
        ? 'Show less'
        : 'Show ' + (total - OUTPUT_COLLAPSED_LINES).toLocaleString() + ' more lines';
    };
    toggle.addEventListener('click', () => {
      expanded = !expanded;
      show();
      if (!expanded && body.getBoundingClientRect().top < 0) body.scrollIntoView({ block: 'start' });
    });
    show();
    body.append(toggle);
  }

  function countLines(runs) {
    let lines = 0;
    let last = '';
    for (const run of runs) {
      const text = run.text;
      for (let index = text.indexOf('\n'); index !== -1; index = text.indexOf('\n', index + 1)) lines += 1;
      if (text) last = text;
    }
    return last && !last.endsWith('\n') ? lines + 1 : lines;
  }

  // HTML for the runs, up to the end of line `maxLines`.
  function runsHTML(runs, maxLines) {
    const parts = [];
    let lines = 0;
    for (const run of runs) {
      let text = run.text;
      let full = false;
      if (maxLines !== Infinity) {
        for (let index = text.indexOf('\n'); index !== -1; index = text.indexOf('\n', index + 1)) {
          lines += 1;
          if (lines >= maxLines) {
            text = text.slice(0, index);
            full = true;
            break;
          }
        }
      }
      parts.push(runHTML(text, run));
      if (full) break;
    }
    return parts.join('');
  }

  // The 16 themed colors are classes. Any other color comes from the
  // 256-color palette or is a true color, picked for one kind of terminal:
  // IPython's traceback colors assume a light one. Those get a variant for
  // each theme with enough contrast to read, and backgrounds become tints
  // like the themed ones.
  function runHTML(text, run) {
    const escaped = escapeHTML(text);
    const classes = [];
    let style = '';
    if (Number.isInteger(run.fg) && run.fg >= 0 && run.fg < 16) {
      classes.push('ansi-fg-' + run.fg);
    } else if (/^#[0-9a-f]{6}$/.test(run.fg)) {
      classes.push('ansi-rgb');
      style += readableColorStyle(run.fg);
    }
    if (Number.isInteger(run.bg) && run.bg >= 0 && run.bg < 16) {
      classes.push('ansi-bg-' + run.bg);
    } else if (/^#[0-9a-f]{6}$/.test(run.bg)) {
      style += 'background-color:color-mix(in srgb,' + run.bg + ' 35%,transparent);';
    }
    if (run.bold) classes.push('ansi-bold');
    if (run.faint) classes.push('ansi-faint');
    if (run.italic) classes.push('ansi-italic');
    if (run.underline) classes.push('ansi-underline');
    if (!classes.length && !style) return escaped;
    return '<span' + (classes.length ? ' class="' + classes.join(' ') + '"' : '')
      + (style ? ' style="' + style + '"' : '') + '>' + escaped + '</span>';
  }

  // In both themes, text has the least contrast on the error tint.
  const LIGHT_TEXT_BACKGROUND = [253, 236, 236];
  const DARK_TEXT_BACKGROUND = [61, 37, 36];
  const readableColors = new Map();

  function readableColorStyle(hex) {
    let style = readableColors.get(hex);
    if (!style) {
      const rgb = [1, 3, 5].map(index => parseInt(hex.slice(index, index + 2), 16));
      style = '--rgb-light:' + hexColor(withContrast(rgb, LIGHT_TEXT_BACKGROUND, 0))
        + ';--rgb-dark:' + hexColor(withContrast(rgb, DARK_TEXT_BACKGROUND, 255)) + ';';
      readableColors.set(hex, style);
    }
    return style;
  }

  // Moves the color toward black (0) or white (255) until its contrast
  // ratio with the background reaches 4.5, the WCAG minimum for text.
  function withContrast(rgb, background, toward) {
    for (let step = 0; step < 20; step++) {
      const mixed = rgb.map(value => Math.round(value + (toward - value) * step / 20));
      if (contrastRatio(mixed, background) >= 4.5) return mixed;
    }
    return [toward, toward, toward];
  }

  function contrastRatio(a, b) {
    const first = relativeLuminance(a);
    const second = relativeLuminance(b);
    return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
  }

  function relativeLuminance(rgb) {
    const [red, green, blue] = rgb.map(value => {
      const channel = value / 255;
      return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * red + 0.7152 * green + 0.0722 * blue;
  }

  function hexColor(rgb) {
    return '#' + rgb.map(value => value.toString(16).padStart(2, '0')).join('');
  }

  function formatSize(bytes) {
    if (bytes >= 1e6) return (bytes / 1e6).toFixed(1) + ' MB';
    if (bytes >= 1e3) return Math.round(bytes / 1e3) + ' KB';
    return bytes + ' bytes';
  }

  // MARK: - Start

  const renderers = { code: renderCode, markdown: renderMarkdown, diff: renderDiff, notebook: renderNotebook };
  const render = renderers[payload.mode] || renderCode;
  const usesMarkdown = payload.mode === 'markdown' || payload.mode === 'notebook';
  const needed = usesMarkdown ? MARKDOWN_SCRIPTS : [];
  if (usesMarkdown) loadStyle('vendor/katex/katex.min.css');
  Promise.all([domReady].concat(needed.map(loadScript)))
    .then(() => render(payload))
    .catch(error => domReady.then(() => showPlain(payload.text, error)));
})();
