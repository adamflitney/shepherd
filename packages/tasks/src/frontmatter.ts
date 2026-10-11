// Round-tripping frontmatter. Unknown fields, comments, blank lines and body text
// are kept exactly as written; `set` rewrites only the entry it is told to change.

export type Scalar = string | number;
export type Value = Scalar | Scalar[];

interface Entry {
  key: string | null; // null for comments and blank lines
  lines: string[];
}

const KEY_LINE = /^([A-Za-z_][\w-]*):(?:\s(.*)|())$/;

export class Frontmatter {
  private entries: Entry[];
  body: string;
  hasFrontmatter: boolean;
  private eol: string;

  private constructor(entries: Entry[], body: string, hasFrontmatter: boolean, eol: string) {
    this.entries = entries;
    this.body = body;
    this.hasFrontmatter = hasFrontmatter;
    this.eol = eol;
  }

  static parse(text: string): Frontmatter {
    const eol = text.includes("\r\n") ? "\r\n" : "\n";
    if (!text.startsWith(`---${eol}`)) return new Frontmatter([], text, false, eol);
    const closeAt = text.indexOf(`${eol}---${eol}`, 3);
    const closeAtEof = text.endsWith(`${eol}---`) ? text.length - 4 - (eol.length - 1) : -1;
    let fmEnd: number;
    let bodyStart: number;
    if (closeAt !== -1) {
      fmEnd = closeAt;
      bodyStart = closeAt + eol.length + 3 + eol.length;
    } else if (closeAtEof !== -1) {
      fmEnd = closeAtEof;
      bodyStart = text.length;
    } else {
      return new Frontmatter([], text, false, eol);
    }
    const raw = text.slice(3 + eol.length, fmEnd);
    const lines = raw === "" ? [] : raw.split(eol);
    const entries: Entry[] = [];
    for (const line of lines) {
      const m = KEY_LINE.exec(line);
      if (m) entries.push({ key: m[1]!, lines: [line] });
      else if (entries.length > 0 && entries.at(-1)!.key !== null && /^(\s|- )/.test(line))
        entries.at(-1)!.lines.push(line); // continuation of a block value
      else entries.push({ key: null, lines: [line] });
    }
    return new Frontmatter(entries, text.slice(bodyStart), true, eol);
  }

  serialize(): string {
    const lines = this.entries.flatMap((e) => e.lines);
    if (!this.hasFrontmatter && lines.length === 0) return this.body;
    const head = lines.length ? lines.join(this.eol) + this.eol : "";
    return `---${this.eol}${head}---${this.eol}${this.body}`;
  }

  keys(): string[] {
    return this.entries.flatMap((e) => (e.key ? [e.key] : []));
  }

  get(key: string): Value | undefined {
    const entry = this.entries.find((e) => e.key === key);
    if (!entry) return undefined;
    const m = KEY_LINE.exec(entry.lines[0]!)!;
    if (entry.lines.length > 1) return undefined; // block values are kept, not interpreted
    return parseValue(stripComment(m[2] ?? ""));
  }

  set(key: string, value: Value | undefined): void {
    const idx = this.entries.findIndex((e) => e.key === key);
    if (value === undefined) {
      if (idx !== -1) this.entries.splice(idx, 1);
      return;
    }
    if (idx === -1) {
      this.entries.push({ key, lines: [`${key}: ${formatValue(value)}`] });
      this.hasFrontmatter = true;
      return;
    }
    const first = this.entries[idx]!.lines[0]!;
    const m = KEY_LINE.exec(first)!;
    const oldRaw = m[2] ?? "";
    const comment = oldRaw.slice(stripComment(oldRaw, false).length); // spacing + "# ..."
    this.entries[idx] = { key, lines: [`${key}: ${formatValue(value)}${comment}`] };
  }
}

/** Returns the value with any trailing ` # comment` removed. */
function stripComment(raw: string, trim = true): string {
  let quote: string | null = null;
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i]!;
    if (quote) {
      if (c === "\\" && quote === '"') i++;
      else if (c === quote) quote = null;
    } else if (c === '"' || c === "'") quote = c;
    else if (c === "#" && (i === 0 || /\s/.test(raw[i - 1]!))) {
      const out = raw.slice(0, i);
      return trim ? out.trim() : out.replace(/\s+$/, "");
    }
  }
  return trim ? raw.trim() : raw.replace(/\s+$/, "");
}

function parseValue(raw: string): Value {
  if (raw.startsWith("[") && raw.endsWith("]")) {
    const inner = raw.slice(1, -1).trim();
    return inner === "" ? [] : splitList(inner).map((s) => parseScalar(s.trim()));
  }
  return parseScalar(raw);
}

function splitList(inner: string): string[] {
  const parts: string[] = [];
  let cur = "";
  let quote: string | null = null;
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i]!;
    if (quote) {
      cur += c;
      if (c === "\\" && quote === '"') cur += inner[++i] ?? "";
      else if (c === quote) quote = null;
    } else if (c === '"' || c === "'") {
      quote = c;
      cur += c;
    } else if (c === ",") {
      parts.push(cur);
      cur = "";
    } else cur += c;
  }
  parts.push(cur);
  return parts;
}

function parseScalar(s: string): Scalar {
  if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
    try {
      return JSON.parse(s) as string;
    } catch {
      return s.slice(1, -1);
    }
  }
  if (s.startsWith("'") && s.endsWith("'") && s.length >= 2) return s.slice(1, -1).replace(/''/g, "'");
  if (/^-?\d+$/.test(s)) return Number(s);
  return s;
}

function needsQuotes(s: string): boolean {
  return (
    s === "" ||
    s !== s.trim() ||
    /^-?\d+$/.test(s) ||
    /^(true|false|null|~)$/i.test(s) ||
    /^[\[\]{}&*!|>'"%@`#,-]/.test(s) ||
    /:(\s|$)/.test(s) ||
    /\s#/.test(s) ||
    /[,\]"']/.test(s) ||
    /[\r\n]/.test(s)
  );
}

function formatScalar(v: Scalar): string {
  if (typeof v === "number") return String(v);
  return needsQuotes(v) ? JSON.stringify(v) : v;
}

function formatValue(v: Value): string {
  return Array.isArray(v) ? `[${v.map(formatScalar).join(", ")}]` : formatScalar(v);
}
