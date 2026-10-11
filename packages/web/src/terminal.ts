import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { Terminal as XTerm } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";

export type TermKind = "xterm" | "ghostty";

/** What the app needs from a terminal emulator, so xterm.js and ghostty-web are interchangeable. */
export interface TermView {
  readonly kind: TermKind;
  write(data: string): void;
  reset(): void;
  focus(): void;
  /** Fit to the container and return the new size. */
  fit(): { cols: number; rows: number };
  size(): { cols: number; rows: number };
  onData(cb: (data: string) => void): void;
  onResize(cb: (size: { cols: number; rows: number }) => void): void;
  /** Return true from the handler to swallow a key so it never reaches the terminal. */
  onKey(cb: (e: KeyboardEvent) => boolean): void;
  dispose(): void;
}

const dark = () => matchMedia("(prefers-color-scheme: dark)").matches;
const THEME_DARK = { background: "#14161a", foreground: "#d8dee9", cursor: "#d8dee9", selectionBackground: "#3b4252" };
const THEME_LIGHT = { background: "#fbfbfa", foreground: "#222831", cursor: "#222831", selectionBackground: "#cfd8e3" };
const FONT = 'ui-monospace, "SF Mono", Menlo, Consolas, monospace';

export async function createTerm(kind: TermKind, el: HTMLElement): Promise<TermView> {
  const theme = dark() ? THEME_DARK : THEME_LIGHT;
  if (kind === "ghostty") {
    const g = await import("ghostty-web");
    // Load the WASM from our own origin. init() would inline it as a data: URL, which the page's
    // Content Security Policy rightly refuses to fetch.
    const { default: wasmUrl } = await import("ghostty-web/ghostty-vt.wasm?url");
    const ghostty = await g.Ghostty.load(wasmUrl);
    const term = new g.Terminal({ fontSize: 13, fontFamily: FONT, theme, scrollback: 5000, cursorBlink: true, ghostty });
    const fit = new g.FitAddon();
    term.loadAddon(fit);
    term.open(el);
    return {
      kind,
      write: (d) => term.write(d),
      reset: () => term.reset(),
      focus: () => term.focus(),
      fit: () => {
        fit.fit();
        return { cols: term.cols, rows: term.rows };
      },
      size: () => ({ cols: term.cols, rows: term.rows }),
      onData: (cb) => void term.onData(cb),
      onResize: (cb) => void term.onResize(cb),
      // ghostty-web: returning true means "handled, skip the terminal"
      onKey: (cb) => term.attachCustomKeyEventHandler((e) => cb(e)),
      dispose: () => term.dispose(),
    };
  }
  const term = new XTerm({ fontSize: 13, fontFamily: FONT, theme, scrollback: 5000, cursorBlink: true, allowProposedApi: true, macOptionIsMeta: true });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.loadAddon(new WebLinksAddon());
  term.open(el);
  return {
    kind,
    write: (d) => term.write(d),
    reset: () => term.reset(),
    focus: () => term.focus(),
    fit: () => {
      fit.fit();
      return { cols: term.cols, rows: term.rows };
    },
    size: () => ({ cols: term.cols, rows: term.rows }),
    onData: (cb) => void term.onData(cb),
    onResize: (cb) => void term.onResize(cb),
    // xterm.js is the other way round: returning false stops the terminal handling the key
    onKey: (cb) => term.attachCustomKeyEventHandler((e) => !cb(e)),
    dispose: () => term.dispose(),
  };
}
