import choir.{ApplyFailed, Claude, Codex, Fail, NoPatch, Pass}
import gleam/string
import gleeunit

pub fn main() {
  gleeunit.main()
}

pub fn parse_defaults_test() {
  let assert Ok(cfg) = choir.parse(["fix the bug", "--test", "make test"])
  assert cfg
    == choir.Cfg(
      "fix the bug",
      "make test",
      ".",
      2,
      [Claude, Codex],
      1200,
      "./choir-out",
    )
}

pub fn parse_flags_test() {
  let assert Ok(cfg) =
    choir.parse([
      "--repo", "/r", "-n", "3", "--providers", "claude", "--timeout", "60",
      "--out", "o", "do it", "--test", "t",
    ])
  assert cfg == choir.Cfg("do it", "t", "/r", 3, [Claude], 60, "o")
}

pub fn parse_errors_test() {
  let assert Error(_) = choir.parse(["x", "--test", "t", "--providers", "gpt"])
  let assert Error(_) = choir.parse(["--test", "t"])
  let assert Error(_) = choir.parse(["x"])
  let assert Error(_) = choir.parse(["x", "--test", "t", "y"])
  let assert Error(_) = choir.parse(["x", "--test", "t", "-n", "0"])
}

pub fn assign_test() {
  assert choir.assign([Claude, Codex], 0) == Claude
  assert choir.assign([Claude, Codex], 1) == Codex
  assert choir.assign([Claude, Codex], 2) == Claude
  assert choir.assign([Claude, Codex], 3) == Codex
  assert choir.assign([Codex], 5) == Codex
}

pub fn provider_jail_test() {
  let j =
    choir.provider_jail(
      9,
      "/r",
      "/r/w1",
      "-B /r/w1/repo:/repo",
      "/x/codex",
      Codex,
    )
  assert string.starts_with(
    j,
    "nsjail -Mo -q -t 9 --disable_rlimits -R /usr -R /lib64 -R /bin",
  )
  assert string.contains(
    j,
    " -R /r/w1/cmd:/cmd -B /r/w1/tmp:/tmp -D /repo -E PATH=/usr/local/bin:/usr/bin -E HOME=/tmp",
  )
  assert string.contains(
    j,
    " --use_pasta -R /r/resolv.conf:/etc/resolv.conf -R /etc/hosts -R /etc/ssl -R /etc/ca-certificates",
  )
  assert string.contains(
    j,
    " -R /x/codex:/prov/codex -R /r/patches:/patches -B /r/w1/cred:/cred -E CODEX_HOME=/cred -B /r/w1/repo:/repo ",
  )
  assert string.ends_with(
    j,
    " -- /usr/bin/sh -c '/prov/codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \"$(cat /cmd)\"'",
  )
  let c =
    choir.provider_jail(
      9,
      "/r",
      "/r/a",
      "-R /r/repo:/repo",
      "/x/claude",
      Claude,
    )
  assert string.contains(c, " -E CLAUDE_CONFIG_DIR=/cred -R /r/repo:/repo ")
  assert string.ends_with(
    c,
    " -- /usr/bin/sh -c '/prov/claude -p \"$(cat /cmd)\" --dangerously-skip-permissions'",
  )
}

pub fn verify_jail_test() {
  let j = choir.verify_jail(7, "/r/v0")
  assert !string.contains(j, "pasta")
  assert !string.contains(j, "/cred")
  assert string.ends_with(
    j,
    " -R /r/v0/cmd:/cmd -B /r/v0/tmp:/tmp -D /repo -E PATH=/usr/local/bin:/usr/bin -E HOME=/tmp -B /r/v0/repo:/repo -- /usr/bin/sh /cmd",
  )
}

pub fn wave_script_test() {
  assert choir.wave_script([#("nsjail a", "/r/w0"), #("nsjail b", "/r/w1")])
    == "( nsjail a < /dev/null > /r/w0.log 2>&1 ; echo $? > /r/w0.rc ) &\n"
    <> "( nsjail b < /dev/null > /r/w1.log 2>&1 ; echo $? > /r/w1.rc ) &\nwait"
}

pub fn table_test() {
  assert choir.size_label(0) == "0 B"
  assert choir.size_label(4198) == "4.0 KB"
  assert choir.verdict("0\n") == Pass
  assert choir.verdict("137\n") == Fail(137)
  assert choir.verdict("") == Fail(255)
  assert choir.row(0, Claude, 4198, Pass, "did it")
    == "0    claude    4.0 KB   PASS          did it"
  assert choir.row(1, Codex, 0, NoPatch, "rate limited")
    == "1    codex     0 B      -             rate limited"
  assert choir.row(2, Codex, 512, ApplyFailed, "")
    == "2    codex     512 B    APPLY FAILED"
  assert choir.row(3, Claude, 2048, Fail(1), "x")
    == "3    claude    2.0 KB   FAIL(1)       x"
}

pub fn utf8_test() {
  assert choir.text(<<104, 105>>) == "hi"
  assert choir.text(<<255, 254>>) == ""
}
