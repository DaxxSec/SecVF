// daxxsec.tech — a working shell in the browser.
// Pure JS, no deps, strict CSP friendly.
(() => {
  "use strict";

  // ───────────────────────── DOM refs ──────────────────────────

  const screen   = document.getElementById("screen");
  const outputEl = document.getElementById("output");
  const echoEl   = document.getElementById("echo");
  const cursorEl = document.getElementById("cursor");
  const inputEl  = document.getElementById("input");
  const cwdEl    = document.getElementById("cwd");
  const promptEl = document.getElementById("prompt-row");

  // ───────────────────────── filesystem ─────────────────────────

  // Tiny in-memory FS. `null` value = directory; string = file content.
  const FS = {
    "/": {
      "home": {
        "guest": {
          "about.txt": [
            "DaxxSec — security tooling for macOS.",
            "",
            "Background: Digital Forensics & Incident Response.",
            "Currently building SecVF, a native macOS suite for malware analysis",
            "and network forensics.",
            "",
            "Type `secvf` to learn more.",
            "Type `contact` to get in touch.",
          ].join("\n"),
          "contact.txt": [
            "github:    https://github.com/DaxxSec",
            "email:     security@daxxsec.tech  (PGP available)",
            "linkedin:  available on request",
            "",
            "For SecVF security disclosures, see:",
            "  https://secvf.daxxsec.tech/.well-known/security.txt",
          ].join("\n"),
          "README.md": [
            "# Welcome to daxxsec.tech",
            "",
            "This is an actual working terminal. Some commands are real,",
            "some are jokes, all are documented. Type `help` for the list.",
            "",
            "## Projects",
            "  • SecVF — security virtualization framework for macOS",
            "    → https://secvf.daxxsec.tech",
            "",
            "## Conventions",
            "  • Up/Down — command history",
            "  • Tab     — autocomplete",
            "  • Ctrl+L  — clear screen",
            "  • Ctrl+C  — cancel current line",
            "",
            "Have fun.",
          ].join("\n"),
          ".secret": {
            "flag.txt": "DAXXSEC{w3lc0me_t0_the_shell}",
          },
          "projects": {
            "secvf": {
              "README":   "SecVF — full details at https://secvf.daxxsec.tech",
              "features": [
                "✔ Hardware-isolated VMs (Apple Virtualization)",
                "✔ In-process L2/L3 software switch (Swift, no kext)",
                "✔ Live tshark packet capture + Wireshark display filters",
                "✔ Ephemeral macOS sandbox for AI agents (APFS-CoW clones)",
                "✔ Kali router VM + FakeNet honeypot",
                "✔ DTrace + Endpoint Security Framework telemetry",
                "✔ MIT licensed, open source",
              ].join("\n"),
            },
          },
        },
      },
      "etc": {
        "motd": [
          "Welcome to daxxsec.tech.",
          "All your sessions are isolated and ephemeral.",
          "Be excellent to each other.",
        ].join("\n"),
        "hosts": "127.0.0.1   localhost\n10.0.100.1  router.secvf.lab",
      },
      "var": { "log": { "auth.log": "(empty — nice try)" } },
    },
  };

  // ───────────────────────── state ─────────────────────────────

  let cwdParts = ["home", "guest"];           // ~/  -> /home/guest
  let inputBuf = "";
  const history = JSON.parse(localStorage.getItem("daxxsec.history") || "[]");
  let histIdx  = history.length;
  let bootDone = false;

  // ────────────────────── pure helpers ─────────────────────────

  const join  = (a, b) => (a === "/" ? "/" + b : a + "/" + b);
  const trim  = (s) => s.replace(/^\/+|\/+$/g, "");

  function cwdString() {
    if (cwdParts.length >= 2 && cwdParts[0] === "home" && cwdParts[1] === "guest") {
      return "~" + cwdParts.slice(2).map((p) => "/" + p).join("");
    }
    return "/" + cwdParts.join("/");
  }
  function updateCwd() { cwdEl.textContent = cwdString(); }

  // Resolve a path (absolute, ~ or relative) to a normalised array of segments.
  function resolvePath(input) {
    if (!input) return cwdParts.slice();
    let parts;
    if (input === "~" || input.startsWith("~/")) {
      parts = ["home", "guest", ...trim(input.slice(1).replace(/^\//, "")).split("/").filter(Boolean)];
    } else if (input.startsWith("/")) {
      parts = trim(input).split("/").filter(Boolean);
    } else {
      parts = [...cwdParts, ...input.split("/").filter(Boolean)];
    }
    // collapse . and ..
    const out = [];
    for (const p of parts) {
      if (p === "." || p === "") continue;
      if (p === "..") { out.pop(); continue; }
      out.push(p);
    }
    return out;
  }

  // Walk FS to whatever node the segments point at; null if missing.
  function getNode(segs) {
    let node = FS["/"];
    for (const s of segs) {
      if (typeof node !== "object" || node === null) return null;
      if (!(s in node)) return null;
      node = node[s];
    }
    return node;
  }
  const isDir  = (node) => typeof node === "object" && node !== null && !Array.isArray(node) && typeof node !== "string";
  const isFile = (node) => typeof node === "string" || Array.isArray(node);
  const fileContent = (node) => Array.isArray(node) ? node.join("\n") : String(node);

  // ───────────────────────── printing ──────────────────────────

  function print(html, cls = "") {
    const div = document.createElement("div");
    div.className = "row" + (cls ? " " + cls : "");
    div.innerHTML = html;
    outputEl.appendChild(div);
    screen.scrollTop = screen.scrollHeight;
  }
  function printText(text, cls = "") {
    print(escape(text), cls);
  }
  function printAscii(text, cls = "") {
    const div = document.createElement("div");
    div.className = "row ascii" + (cls ? " " + cls : "");
    div.textContent = text;
    outputEl.appendChild(div);
    screen.scrollTop = screen.scrollHeight;
  }
  function escape(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
    }[c]));
  }

  // Mirror the command line into the rendered output area when it executes.
  function commitLine(cmd) {
    const ps1 = `<span class="ps1"><span class="user">guest</span><span class="at">@</span><span class="host">daxxsec</span><span class="colon">:</span><span class="path">${escape(cwdString())}</span><span class="dollar">$</span></span> `;
    print(ps1 + `<span class="cmd-echo">${escape(cmd)}</span>`);
  }

  // ───────────────────────── parser ────────────────────────────

  // Very small shell-like parser: supports quoted args and pipes are NOT supported.
  function parse(line) {
    const out = [];
    let cur = "", inDouble = false, inSingle = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (inDouble) {
        if (ch === '"') inDouble = false;
        else cur += ch;
      } else if (inSingle) {
        if (ch === "'") inSingle = false;
        else cur += ch;
      } else if (ch === '"') inDouble = true;
      else if (ch === "'") inSingle = true;
      else if (ch === " " || ch === "\t") { if (cur) { out.push(cur); cur = ""; } }
      else cur += ch;
    }
    if (cur) out.push(cur);
    return out;
  }

  // ───────────────────────── commands ──────────────────────────

  const COMMANDS = {
    help: {
      desc: "list available commands",
      run: () => {
        const groups = [
          ["Shell", ["help", "ls", "cd", "pwd", "cat", "clear", "echo", "date", "uname", "whoami", "history", "man"]],
          ["DaxxSec", ["about", "contact", "github", "projects", "secvf", "wiki", "social"]],
          ["Try me",  ["sudo", "vim", "emacs", "matrix", "cowsay", "coffee", "ping", "nmap", "hack", "42"]],
        ];
        for (const [title, cmds] of groups) {
          print(`<span class="dim">── ${title} ─────────────────────────────────</span>`);
          let row = `<div class="grid">`;
          for (const c of cmds) {
            const meta = COMMANDS[c];
            const desc = meta ? meta.desc : "";
            row += `<span class="accent">${escape(c)}</span><span class="dim">${escape(desc)}</span>`;
          }
          row += `</div>`;
          print(row);
        }
        print(`<span class="dim">Tab to autocomplete · ↑↓ for history · Ctrl+L to clear · Ctrl+C to cancel</span>`);
      },
    },

    ls: {
      desc: "list directory contents",
      run: (args) => {
        const target = args[0] ? resolvePath(args[0]) : cwdParts;
        const node = getNode(target);
        if (!node) return printText(`ls: ${args[0] || ""}: No such file or directory`, "err");
        if (isFile(node)) return printText(args[0] || target.join("/"));
        const entries = Object.entries(node).sort(([a], [b]) => a.localeCompare(b));
        if (!entries.length) return print(`<span class="dim">(empty)</span>`);
        let html = `<div class="grid">`;
        for (const [name, value] of entries) {
          const dirMark = isDir(value);
          const hidden = name.startsWith(".");
          const cls = dirMark ? "accent" : hidden ? "dim" : "";
          html += `<span class="${cls}">${escape(name)}${dirMark ? "/" : ""}</span><span class="dim">${dirMark ? "dir" : (isFile(value) ? fileContent(value).split("\n").length + " lines" : "")}</span>`;
        }
        html += `</div>`;
        print(html);
      },
    },

    cd: {
      desc: "change the working directory",
      run: (args) => {
        const target = args[0] || "~";
        const segs = resolvePath(target);
        const node = getNode(segs);
        if (!node) return printText(`cd: ${target}: No such file or directory`, "err");
        if (!isDir(node)) return printText(`cd: ${target}: Not a directory`, "err");
        cwdParts = segs;
        updateCwd();
      },
    },

    pwd: { desc: "print working directory", run: () => printText("/" + cwdParts.join("/")) },

    cat: {
      desc: "print the contents of a file",
      run: (args) => {
        if (!args.length) return printText("cat: missing operand", "err");
        for (const f of args) {
          const segs = resolvePath(f);
          const node = getNode(segs);
          if (!node) { printText(`cat: ${f}: No such file or directory`, "err"); continue; }
          if (isDir(node)) { printText(`cat: ${f}: Is a directory`, "err"); continue; }
          printText(fileContent(node));
        }
      },
    },

    clear: { desc: "clear the screen", run: () => { outputEl.innerHTML = ""; } },

    echo: { desc: "print arguments", run: (args) => printText(args.join(" ")) },

    date: { desc: "current date/time", run: () => printText(new Date().toString()) },

    uname: {
      desc: "system info (try `uname -a`)",
      run: (args) => {
        if (args.includes("-a")) {
          printText(`daxxsec 1.0.0 darwin 24.0 ${navigator.platform} secvf-shell/${VERSION}`);
        } else printText("daxxsec");
      },
    },

    whoami: {
      desc: "print effective user",
      run: () => {
        printText("guest");
        print(`<span class="dim">(you're in a sandboxed browser shell — no real identity)</span>`);
      },
    },

    history: {
      desc: "command history (last 50)",
      run: () => {
        if (!history.length) return print(`<span class="dim">(no history yet)</span>`);
        let h = `<div class="grid">`;
        history.slice(-50).forEach((c, i) => {
          h += `<span class="dim">${i + 1}</span><span>${escape(c)}</span>`;
        });
        h += `</div>`;
        print(h);
      },
    },

    man: {
      desc: "manual page for a command",
      run: (args) => {
        if (!args.length) return printText("man: what manual page do you want?", "err");
        const c = COMMANDS[args[0]];
        if (!c) return printText(`No manual entry for ${args[0]}`, "err");
        print(`<span class="bold">${escape(args[0].toUpperCase())}(1)</span>          DaxxSec Shell Manual          <span class="bold">${escape(args[0].toUpperCase())}(1)</span>`);
        print(`<span class="dim"></span>`);
        print(`<span class="bold">NAME</span>`);
        print(`    ${escape(args[0])} — ${escape(c.desc)}`);
        if (c.usage) { print(""); print(`<span class="bold">USAGE</span>`); print(`    ${escape(c.usage)}`); }
        if (c.note)  { print(""); print(`<span class="bold">NOTES</span>`); print(`    ${escape(c.note)}`); }
      },
    },

    // ─── DaxxSec / SecVF info ─────────────────────────────────

    about: {
      desc: "about me & this site",
      run: () => COMMANDS.cat.run(["~/about.txt"]),
    },

    contact: {
      desc: "how to reach me",
      run: () => COMMANDS.cat.run(["~/contact.txt"]),
    },

    github: {
      desc: "open the GitHub profile",
      run: () => {
        printText("Opening github.com/DaxxSec ...");
        window.open("https://github.com/DaxxSec", "_blank", "noopener,noreferrer");
      },
    },

    projects: {
      desc: "list projects",
      run: () => COMMANDS.ls.run(["~/projects"]),
    },

    secvf: {
      desc: "the SecVF security virtualization framework",
      run: () => {
        printAscii(SECVF_LOGO, "accent");
        print("");
        printText("SecVF — Security Virtualization Framework", "bold");
        printText("Native macOS suite for malware analysis & incident response.");
        print("");
        COMMANDS.cat.run(["~/projects/secvf/features"]);
        print("");
        print(`<a href="https://secvf.daxxsec.tech" target="_blank" rel="noopener noreferrer">→ secvf.daxxsec.tech</a> · <a href="https://secvf.daxxsec.tech/wiki/" target="_blank" rel="noopener noreferrer">documentation</a> · <a href="https://github.com/DaxxSec/SecVF" target="_blank" rel="noopener noreferrer">github</a>`);
      },
    },

    wiki: {
      desc: "open the SecVF documentation",
      run: () => {
        printText("Opening secvf.daxxsec.tech/wiki/ ...");
        window.open("https://secvf.daxxsec.tech/wiki/", "_blank", "noopener,noreferrer");
      },
    },

    social: {
      desc: "social links",
      run: () => {
        print(`<div class="grid">
          <span class="accent">github</span><span><a href="https://github.com/DaxxSec" target="_blank" rel="noopener noreferrer">github.com/DaxxSec</a></span>
          <span class="accent">secvf</span><span><a href="https://secvf.daxxsec.tech" target="_blank" rel="noopener noreferrer">secvf.daxxsec.tech</a></span>
          <span class="accent">email</span><span>security@daxxsec.tech</span>
        </div>`);
      },
    },

    // ─── jokes & easter eggs ──────────────────────────────────

    sudo: {
      desc: "you're not in the sudoers file",
      run: (args) => {
        if (args[0] === "make" && args[1] === "me" && args[2] === "a" && args[3] === "sandwich") {
          return printText("Okay.", "ok");
        }
        printText(`[sudo] password for guest: `, "warn");
        setTimeout(() => printText("guest is not in the sudoers file.  This incident will be reported.", "err"), 600);
      },
    },

    vim: {
      desc: "no vim. type :q to exit (the shell — kidding)",
      run: () => {
        print(`<span class="warn">vim is not available in the browser shell.</span>`);
        print(`<span class="dim">If you see this and panic about getting out: type any command. You're already free.</span>`);
      },
    },
    emacs: { desc: "you came to the wrong shell", run: () => printText("emacs: command not found. and that's a feature.", "err") },
    nano:  { desc: "no editors here", run: () => printText("nano: command not found", "err") },

    exit: {
      desc: "leave the shell",
      run: () => {
        printText("There is no exit. The shell is the destination.", "warn");
        print(`<span class="dim">(close the tab if you really want to. but consider staying for one more `cowsay`.)</span>`);
      },
    },

    matrix: {
      desc: "let it rain",
      run: () => startMatrix(),
    },

    cowsay: {
      desc: "a cow says what you tell it",
      run: (args) => {
        const msg = args.join(" ") || "moo";
        const top = "_".repeat(msg.length + 2);
        const bot = "-".repeat(msg.length + 2);
        const cow = [
          ` ${top}`,
          `< ${msg} >`,
          ` ${bot}`,
          `        \\   ^__^`,
          `         \\  (oo)\\_______`,
          `            (__)\\       )\\/\\`,
          `                ||----w |`,
          `                ||     ||`,
        ].join("\n");
        printAscii(cow, "accent");
      },
    },

    coffee: {
      desc: "make coffee",
      run: () => {
        printAscii([
          "    ( (",
          "     ) )",
          "  ........",
          "  |      |]",
          "  \\      /",
          "   `----'",
        ].join("\n"), "accent");
        printText("HTCPCP/1.0 418 I'm a teapot", "dim");
      },
    },

    "42": {
      desc: "the answer to life, the universe, and everything",
      run: () => printText("42.", "accent"),
    },

    ping: {
      desc: "fake ping",
      run: (args) => {
        const t = args[0] || "1.1.1.1";
        const lines = [
          `PING ${t} (${t}): 56 data bytes`,
          `64 bytes from ${t}: icmp_seq=0 ttl=57 time=12.3 ms`,
          `64 bytes from ${t}: icmp_seq=1 ttl=57 time=11.9 ms`,
          `64 bytes from ${t}: icmp_seq=2 ttl=57 time=13.1 ms`,
          ``,
          `--- ${t} ping statistics ---`,
          `3 packets transmitted, 3 packets received, 0.0% packet loss`,
        ];
        let i = 0;
        const tick = () => {
          if (i < lines.length) { printText(lines[i++]); setTimeout(tick, 250); }
        };
        tick();
      },
    },

    nmap: {
      desc: "fake nmap (no real scans, sorry)",
      run: (args) => {
        const t = args[args.length - 1] || "scanme.daxxsec.tech";
        printText(`Starting Nmap 7.94 ( https://nmap.org ) at ${new Date().toISOString()}`);
        printText(`Nmap scan report for ${t} (10.0.100.1)`);
        printText(`Host is up (0.012s latency).`);
        printText(`PORT     STATE  SERVICE`);
        printText(`22/tcp   open   ssh        OpenSSH 9.6`);
        printText(`80/tcp   open   http       SecVF Honeypot`);
        printText(`443/tcp  open   https      SecVF Honeypot`);
        printText(`6667/tcp open   irc        SecVF FakeNet`);
        printText(`(this is a simulated response. real scanning happens inside SecVF, not in this browser shell.)`, "dim");
      },
    },

    hack: {
      desc: "definitely-not-malicious",
      run: (args) => {
        const t = args[0] || "the.gibson";
        printText(`> connecting to ${t}…`, "warn");
        const steps = [
          "[+] bypassing firewall...",
          "[+] enumerating users...",
          "[+] enumerating ports... 22, 80, 443",
          "[+] extracting hash...",
          "[+] cracking hash... 100%",
          "[+] root access acquired.",
          "[+] just kidding. this is a static page. nobody is hacking anything.",
        ];
        let i = 0;
        const tick = () => {
          if (i < steps.length) {
            printText(steps[i], i === steps.length - 1 ? "dim" : "ok");
            i++;
            setTimeout(tick, 350);
          }
        };
        tick();
      },
    },

    "rm": {
      desc: "remove files (try -rf /)",
      run: (args) => {
        if (args.includes("-rf") && (args.includes("/") || args.includes("/*"))) {
          printText("rm: nice try.", "err");
          print(`<span class="dim">no real filesystem here. but i appreciate the spirit.</span>`);
        } else {
          printText("rm: this is a read-only filesystem.", "err");
        }
      },
    },

    ":q":  { desc: "you escaped vim", run: () => printText("Congratulations. You escaped vim.", "ok") },
    ":wq": { desc: "save and quit",   run: () => printText("Saved. (also: you escaped vim again.)", "ok") },
  };

  // ───────────────────────── ASCII art ─────────────────────────

  const SECVF_LOGO = `
       _______
      /       \\
     /  SecVF  \\
    |  /     \\  |
    | /  ✓   \\ |
    | \\  ___  / |
     \\  \\_/  /
      \\_____/
`;

  const VERSION = "1.0.0";

  // ─────────────────── command dispatch ────────────────────────

  function exec(line) {
    const argv = parse(line);
    if (!argv.length) return;
    const cmd = argv[0];
    const args = argv.slice(1);
    const meta = COMMANDS[cmd];
    if (!meta) {
      printText(`zsh: command not found: ${cmd}`, "err");
      // Suggest close matches
      const sugg = suggestion(cmd);
      if (sugg) print(`<span class="dim">did you mean: <span class="accent">${escape(sugg)}</span>?</span>`);
      return;
    }
    try { meta.run(args); }
    catch (e) { printText(`internal error: ${e.message}`, "err"); }
  }

  function suggestion(cmd) {
    let best = null, bestScore = Infinity;
    for (const k of Object.keys(COMMANDS)) {
      const d = levenshtein(cmd, k);
      if (d < bestScore && d <= 2) { bestScore = d; best = k; }
    }
    return best;
  }
  function levenshtein(a, b) {
    const m = a.length, n = b.length;
    if (!m) return n; if (!n) return m;
    const dp = Array.from({ length: m + 1 }, (_, i) => [i, ...Array(n).fill(0)]);
    for (let j = 1; j <= n; j++) dp[0][j] = j;
    for (let i = 1; i <= m; i++)
      for (let j = 1; j <= n; j++)
        dp[i][j] = a[i-1] === b[j-1] ? dp[i-1][j-1] : 1 + Math.min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1]);
    return dp[m][n];
  }

  // ─────────────────── matrix rain (CSS-based) ─────────────────

  function startMatrix() {
    const overlay = document.createElement("div");
    overlay.className = "matrix-overlay active";
    const hint = document.createElement("div");
    hint.className = "matrix-hint";
    hint.textContent = "press any key to exit the matrix";
    const cols = 60;
    const chars = "ｱｲｳｴｵｶｷｸｹｺ01010101DAXXSECVF";
    const columns = [];
    for (let i = 0; i < cols; i++) {
      const col = document.createElement("div");
      col.className = "matrix-column";
      overlay.appendChild(col);
      columns.push({ el: col, offset: Math.floor(Math.random() * 30), str: "" });
    }
    document.body.appendChild(overlay);
    document.body.appendChild(hint);
    const id = setInterval(() => {
      for (const c of columns) {
        if (c.offset > 0) { c.offset--; continue; }
        c.str += chars[Math.floor(Math.random() * chars.length)] + "\n";
        if (c.str.length > 80) c.str = c.str.slice(-80);
        c.el.textContent = c.str;
      }
    }, 90);
    const stop = () => {
      clearInterval(id);
      overlay.remove();
      hint.remove();
      window.removeEventListener("keydown", stop, true);
      window.removeEventListener("click", stop, true);
    };
    setTimeout(() => {
      window.addEventListener("keydown", stop, true);
      window.addEventListener("click", stop, true);
    }, 80);
  }

  // ─────────────────── tab completion ──────────────────────────

  function complete(buf) {
    const argv = parse(buf);
    if (!argv.length) return buf;
    // First token: complete command names
    if (argv.length === 1 && !/\s$/.test(buf)) {
      const prefix = argv[0];
      const opts = Object.keys(COMMANDS).filter((c) => c.startsWith(prefix));
      if (opts.length === 1) return opts[0] + " ";
      if (opts.length > 1) {
        printText(opts.join("  "), "dim");
        return buf;
      }
      return buf;
    }
    // Subsequent tokens: complete paths in current FS
    const last = argv[argv.length - 1] || "";
    const slash = last.lastIndexOf("/");
    const dirPart = slash >= 0 ? last.slice(0, slash + 1) : "";
    const namePart = slash >= 0 ? last.slice(slash + 1) : last;
    const dirSegs = dirPart ? resolvePath(dirPart) : cwdParts;
    const node = getNode(dirSegs);
    if (!isDir(node)) return buf;
    const opts = Object.keys(node).filter((n) => n.startsWith(namePart));
    if (opts.length === 1) {
      const completed = dirPart + opts[0] + (isDir(node[opts[0]]) ? "/" : " ");
      return buf.slice(0, buf.length - last.length) + completed;
    }
    if (opts.length > 1) printText(opts.join("  "), "dim");
    return buf;
  }

  // ───────────────────── input handlers ────────────────────────

  function setBuf(v) {
    inputBuf = v;
    echoEl.textContent = v;
  }

  function commit() {
    const line = inputBuf;
    commitLine(line);
    setBuf("");
    if (line.trim()) {
      history.push(line);
      if (history.length > 200) history.splice(0, history.length - 200);
      localStorage.setItem("daxxsec.history", JSON.stringify(history));
    }
    histIdx = history.length;
    exec(line);
    // re-anchor cursor at bottom
    setTimeout(() => screen.scrollTop = screen.scrollHeight, 0);
  }

  function onKey(e) {
    if (e.metaKey && !e.ctrlKey) return;  // let cmd-shortcuts pass
    if (e.key === "Enter") { e.preventDefault(); commit(); return; }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      if (histIdx > 0) { histIdx--; setBuf(history[histIdx] || ""); }
      return;
    }
    if (e.key === "ArrowDown") {
      e.preventDefault();
      if (histIdx < history.length) { histIdx++; setBuf(history[histIdx] || ""); }
      return;
    }
    if (e.key === "Tab") { e.preventDefault(); setBuf(complete(inputBuf)); return; }
    if (e.key === "Backspace") {
      e.preventDefault();
      if (e.altKey) {
        // delete word
        setBuf(inputBuf.replace(/\S*\s*$/, ""));
      } else setBuf(inputBuf.slice(0, -1));
      return;
    }
    if (e.ctrlKey) {
      if (e.key === "l") { e.preventDefault(); outputEl.innerHTML = ""; return; }
      if (e.key === "c") { e.preventDefault(); commitLine(inputBuf + "^C"); setBuf(""); return; }
      if (e.key === "u") { e.preventDefault(); setBuf(""); return; }
      if (e.key === "a") { /* move cursor — we don't support mid-line edit, no-op */ e.preventDefault(); return; }
      if (e.key === "e") { e.preventDefault(); return; }
      return;
    }
    if (e.key.length === 1 && !e.altKey) { e.preventDefault(); setBuf(inputBuf + e.key); }
  }

  // ───────────────────── boot sequence ─────────────────────────

  const BOOT = [
    { text: `[boot] daxxsec.tech terminal v${VERSION}`, cls: "dim", delay: 60 },
    { text: `[boot] mounting /home/guest`,              cls: "dim", delay: 40 },
    { text: `[boot] tty00: ready`,                      cls: "dim", delay: 40 },
    { text: `[boot] login: guest (auto)`,               cls: "dim", delay: 80 },
    { text: ``,                                         cls: "", delay: 30 },
  ];

  function boot() {
    let i = 0;
    const tick = () => {
      if (i < BOOT.length) {
        const line = BOOT[i++];
        if (line.text === "") print("");
        else printText(line.text, line.cls);
        setTimeout(tick, line.delay);
      } else {
        // Banner
        printAscii([
          "    ____                       _____            ",
          "   / __ \\____ __  ___  __    / ___/___  _____  ",
          "  / / / / __ `/ |/_/ |/_/    \\__ \\/ _ \\/ ___/  ",
          " / /_/ / /_/ />  < >  <     ___/ /  __/ /__    ",
          "/_____/\\__,_/_/|_/_/|_|    /____/\\___/\\___/    ",
        ].join("\n"), "accent");
        print(`<span class="dim">— a working shell. type </span><span class="accent">help</span><span class="dim"> to begin.</span>`);
        print("");
        bootDone = true;
      }
    };
    tick();
  }

  // ───────────────────── wire it up ────────────────────────────

  function focus() { /* the cursor lives via animation; this just visually emphasises */ promptEl.classList.add("focused"); }

  window.addEventListener("keydown", (e) => { if (bootDone) onKey(e); });

  // Click anywhere to focus
  document.addEventListener("click", () => screen.scrollTop = screen.scrollHeight);

  updateCwd();
  boot();
})();
