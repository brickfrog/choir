import argv
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import shellout
import simplifile

pub type Provider {
  Claude
  Codex
}

pub type Cfg {
  Cfg(
    instruction: String,
    test_cmd: String,
    repo: String,
    n: Int,
    providers: List(Provider),
    timeout: Int,
    out: String,
  )
}

pub type Verdict {
  Pass
  Fail(Int)
  ApplyFailed
  NoPatch
}

const prefix = "nsjail -Mo -q -t {t} --disable_rlimits -R /usr -R /lib64 -R /bin -R /etc/passwd -R /etc/group -R /dev/null -R /dev/zero -R /dev/urandom -R /dev/random -R {s}/cmd:/cmd -B {s}/tmp:/tmp -D /repo -E PATH=/usr/local/bin:/usr/bin -E HOME=/tmp"

const provider_tail = " --use_pasta -R {r}/resolv.conf:/etc/resolv.conf -R /etc/hosts -R /etc/ssl -R /etc/ca-certificates -R {b}:/prov/{p} -R {r}/patches:/patches -B {s}/cred:/cred -E {e}=/cred {m} -- /usr/bin/sh -c '{c}'"

const audit_prompt = "Read the repository at /repo and the patches at /patches. Say what is wrong with each one."

pub fn main() {
  case parse(argv.load().arguments) {
    Ok(cfg) -> halt(run_choir(from_stdin(cfg)))
    Error(e) -> {
      io.println_error("choir: " <> e)
      halt(1)
    }
  }
}

/// An instruction of `-` is read from stdin instead. A paragraph does not
/// belong in a shell argument, and a heredoc is the shell's own answer to
/// that. Only `-` reads it, so `choir` with no stdin never blocks waiting.
fn from_stdin(c: Cfg) -> Cfg {
  case c.instruction {
    "-" ->
      case simplifile.read("/dev/stdin") {
        Ok(s) -> Cfg(..c, instruction: string.trim(s))
        Error(_) -> c
      }
    _ -> c
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

pub fn parse(args: List(String)) -> Result(Cfg, String) {
  parse_loop(args, Cfg("", "", ".", 2, [Claude, Codex], 1200, "./choir-out"))
}

fn parse_loop(args: List(String), c: Cfg) -> Result(Cfg, String) {
  case args {
    [] if c.instruction == "" -> Error("an instruction is required")
    [] if c.test_cmd == "" -> Error("--test is required")
    [] -> Ok(c)
    ["--test", v, ..r] -> parse_loop(r, Cfg(..c, test_cmd: v))
    ["--repo", v, ..r] -> parse_loop(r, Cfg(..c, repo: v))
    ["--out", v, ..r] -> parse_loop(r, Cfg(..c, out: v))
    ["-n", v, ..r] -> parse_int(v, r, fn(n) { Cfg(..c, n: n) })
    ["--timeout", v, ..r] -> parse_int(v, r, fn(t) { Cfg(..c, timeout: t) })
    ["--providers", v, ..r] ->
      case list.try_map(string.split(v, ","), word) {
        Ok(ps) -> parse_loop(r, Cfg(..c, providers: ps))
        Error(e) -> Error(e)
      }
    [v, ..r] if c.instruction == "" -> parse_loop(r, Cfg(..c, instruction: v))
    [v, ..] -> Error("unexpected argument: " <> v)
  }
}

fn parse_int(
  v: String,
  rest: List(String),
  set: fn(Int) -> Cfg,
) -> Result(Cfg, String) {
  case int.parse(v) {
    Ok(i) if i > 0 -> parse_loop(rest, set(i))
    _ -> Error("expected a positive integer, got: " <> v)
  }
}

fn word(w: String) -> Result(Provider, String) {
  case w {
    "claude" -> Ok(Claude)
    "codex" -> Ok(Codex)
    _ -> Error("unknown provider: " <> w)
  }
}

pub fn name(p: Provider) -> String {
  case p {
    Claude -> "claude"
    Codex -> "codex"
  }
}

pub fn assign(providers: List(Provider), index: Int) -> Provider {
  let assert Ok(p) =
    list.first(list.drop(providers, index % list.length(providers)))
  p
}

fn cred(p: Provider) -> #(String, String) {
  case p {
    Claude -> #("CLAUDE_CONFIG_DIR", ".claude/.credentials.json")
    Codex -> #("CODEX_HOME", ".codex/auth.json")
  }
}

fn command_line(p: Provider) -> String {
  case p {
    Claude -> "/prov/claude -p \"$(cat /cmd)\" --dangerously-skip-permissions"
    Codex ->
      "/prov/codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \"$(cat /cmd)\""
  }
}

@external(erlang, "erlang", "iolist_to_binary")
fn coerce(s: String) -> BitArray

pub fn text(bits: BitArray) -> String {
  result.unwrap(bit_array.to_string(bits), "")
}

fn run(cmd: String, args: List(String)) -> #(Int, BitArray) {
  case shellout.command(run: cmd, with: args, in: ".", opt: []) {
    Ok(out) -> #(0, coerce(out))
    Error(#(code, out)) -> #(code, coerce(out))
  }
}

fn line(script: String) -> String {
  let #(_, out) = run("/bin/sh", ["-c", script])
  string.trim(text(out))
}

fn fill(template: String, holes: List(#(String, String))) -> String {
  list.fold(holes, template, fn(s, h) { string.replace(s, h.0, h.1) })
}

pub fn provider_jail(
  timeout: Int,
  dir: String,
  slot: String,
  mount: String,
  bin: String,
  p: Provider,
) -> String {
  fill(prefix <> provider_tail, [
    #("{t}", int.to_string(timeout)),
    #("{s}", slot),
    #("{r}", dir),
    #("{b}", bin),
    #("{p}", name(p)),
    #("{e}", cred(p).0),
    #("{m}", mount),
    #("{c}", command_line(p)),
  ])
}

pub fn verify_jail(timeout: Int, slot: String) -> String {
  fill(prefix <> " -B {s}/repo:/repo -- /usr/bin/sh /cmd", [
    #("{t}", int.to_string(timeout)),
    #("{s}", slot),
  ])
}

pub fn wave_script(jails: List(#(String, String))) -> String {
  list.map(jails, fn(j) {
    fill("( {j} < /dev/null > {s}.log 2>&1 ; echo $? > {s}.rc ) &", [
      #("{j}", j.0),
      #("{s}", j.1),
    ])
  })
  |> list.append(["wait"])
  |> string.join("\n")
}

fn wave(jails: List(#(String, String))) -> Nil {
  let _ = run("/bin/sh", ["-c", wave_script(jails)])
  Nil
}

pub fn verdict(rc: String) -> Verdict {
  case int.parse(string.trim(rc)) {
    Ok(0) -> Pass
    Ok(c) -> Fail(c)
    Error(_) -> Fail(255)
  }
}

fn slot(dir: String, kind: String, i: Int) -> String {
  dir <> "/" <> kind <> int.to_string(i)
}

fn prep(slot: String, cmd: String, p: Provider) -> String {
  let _ = simplifile.create_directory_all(slot <> "/tmp")
  let _ = simplifile.create_directory_all(slot <> "/cred")
  let _ = simplifile.write(slot <> "/cmd", cmd)
  let _ = line("cp \"$HOME/" <> cred(p).1 <> "\" " <> slot <> "/cred/")
  line("readlink -f \"$(command -v " <> name(p) <> ")\"")
}

fn extract(dir: String, out: String, i: Int) -> Int {
  let repo = slot(dir, "w", i) <> "/repo"
  let _ = run("git", ["-C", repo, "add", "-A"])
  let #(_, patch) = run("git", ["-C", repo, "diff", "--cached", "HEAD"])
  let file = "/" <> int.to_string(i) <> ".patch"
  let _ = simplifile.write_bits(out <> file, patch)
  let _ = simplifile.write_bits(dir <> "/patches" <> file, patch)
  bit_array.byte_size(patch)
}

pub fn size_label(bytes: Int) -> String {
  case bytes < 1024 {
    True -> int.to_string(bytes) <> " B"
    False -> {
      let tenths = bytes * 10 / 1024
      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> " KB"
    }
  }
}

fn pad(s: String, w: Int) -> String {
  s <> string.repeat(" ", int.max(1, w - string.length(s)))
}

pub fn row(
  i: Int,
  p: Provider,
  bytes: Int,
  v: Verdict,
  last: String,
) -> String {
  let label = case v {
    Pass -> "PASS"
    Fail(c) -> "FAIL(" <> int.to_string(c) <> ")"
    ApplyFailed -> "APPLY FAILED"
    NoPatch -> "-"
  }
  string.trim_end(
    pad(int.to_string(i), 5)
    <> pad(name(p), 10)
    <> pad(size_label(bytes), 9)
    <> pad(label, 14)
    <> last,
  )
}

fn read(path: String) -> String {
  case simplifile.read_bits(path) {
    Ok(bits) -> text(bits)
    Error(_) -> ""
  }
}

fn last_line(path: String) -> String {
  read(path)
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(l) { l != "" })
  |> list.last
  |> result.unwrap("")
}

fn run_choir(cfg: Cfg) -> Int {
  let dir = line("mktemp -d")
  let _ = run("cp", ["-a", cfg.repo, dir <> "/repo"])
  let _ = simplifile.create_directory_all(dir <> "/patches")
  let _ = simplifile.create_directory_all(cfg.out)
  // argv, not a shell string: `--out` is user input and `line` runs /bin/sh -c.
  let #(_, abs) = run("readlink", ["-f", cfg.out])
  let out = string.trim(text(abs))
  let _ = simplifile.write(dir <> "/resolv.conf", "nameserver 10.255.255.1\n")
  // The run directory is the only way to watch a wave: every jail's log and
  // working tree is an ordinary host file under it, and a wave prints nothing
  // until it ends. v1 died of exactly this silence.
  io.println("run " <> dir)
  let plan =
    list.index_map(list.repeat(Nil, cfg.n), fn(_, i) {
      #(i, assign(cfg.providers, i))
    })
  let audit = assign(cfg.providers, cfg.n)
  io.println(
    fill("{n} work jails: {p}; audit={a}; timeout {t}s", [
      #("{n}", int.to_string(cfg.n)),
      #(
        "{p}",
        string.join(
          list.map(plan, fn(x) { int.to_string(x.0) <> "=" <> name(x.1) }),
          " ",
        ),
      ),
      #("{a}", name(audit)),
      #("{t}", int.to_string(cfg.timeout)),
    ]),
  )
  io.println("[work]   " <> int.to_string(cfg.n) <> " jails started")
  wave(
    list.map(plan, fn(x) {
      let s = slot(dir, "w", x.0)
      let bin = prep(s, cfg.instruction, x.1)
      let _ = run("cp", ["-a", dir <> "/repo", s <> "/repo"])
      let mount = "-B " <> s <> "/repo:/repo"
      #(provider_jail(cfg.timeout, dir, s, mount, bin, x.1), s)
    }),
  )
  let staged =
    list.map(plan, fn(x) {
      let s = slot(dir, "v", x.0)
      case extract(dir, out, x.0) {
        0 -> #(x.0, x.1, 0, Error(NoPatch))
        size -> {
          let _ = prep(s, cfg.test_cmd, x.1)
          let _ = run("cp", ["-a", dir <> "/repo", s <> "/repo"])
          let patch = dir <> "/patches/" <> int.to_string(x.0) <> ".patch"
          case run("git", ["-C", s <> "/repo", "apply", patch]) {
            #(0, _) -> #(x.0, x.1, size, Ok(s))
            _ -> #(x.0, x.1, size, Error(ApplyFailed))
          }
        }
      }
    })
  let jails =
    list.filter_map(staged, fn(s) {
      result.map(s.3, fn(v) { #(verify_jail(cfg.timeout, v), v) })
    })
  io.println(
    "[verify] " <> int.to_string(list.length(jails)) <> " jails started",
  )
  wave(jails)
  let rows =
    list.map(staged, fn(s) {
      case s.3 {
        Ok(v) -> #(s.0, s.1, s.2, verdict(read(v <> ".rc")))
        Error(v) -> #(s.0, s.1, s.2, v)
      }
    })
  io.println("\nJAIL PROVIDER  PATCH    TESTS         LAST LINE FROM PROVIDER")
  list.each(rows, fn(r) {
    io.println(row(r.0, r.1, r.2, r.3, last_line(slot(dir, "w", r.0) <> ".log")))
  })
  let passed = list.filter(rows, fn(r) { r.3 == Pass })
  io.println("")
  list.each(passed, fn(r) {
    io.println("  git apply " <> out <> "/" <> int.to_string(r.0) <> ".patch")
  })
  let a = dir <> "/a"
  let bin = prep(a, audit_prompt, audit)
  let mount = "-R " <> dir <> "/repo:/repo"
  wave([#(provider_jail(cfg.timeout, dir, a, mount, bin, audit), a)])
  let head =
    "audit ("
    <> name(audit)
    <> " — model commentary, unverified, no effect on the table above)"
  io.println("\n" <> head <> "\n" <> string.repeat("-", string.length(head)))
  io.println(string.trim(read(a <> ".log")))
  let _ = run("rm", ["-rf", dir])
  case passed {
    [] -> 1
    _ -> 0
  }
}
