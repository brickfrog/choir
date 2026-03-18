///|
pub fn tmux_new_window(
  session : String,
  name : String,
  workdir : String,
) -> Command {
  {
    program: "tmux",
    args: ["new-window", "-t", session, "-n", name, "-c", workdir],
    workdir: None,
  }
}

///|
pub fn tmux_split_pane(target : String, workdir : String) -> Command {
  {
    program: "tmux",
    args: ["split-window", "-t", target, "-c", workdir],
    workdir: None,
  }
}

///|
pub fn tmux_send_keys(target : String, text : String) -> Command {
  {
    program: "tmux",
    args: ["send-keys", "-t", target, text, "C-m"],
    workdir: None,
  }
}

///|
pub fn tmux_kill_pane(target : String) -> Command {
  { program: "tmux", args: ["kill-pane", "-t", target], workdir: None }
}

///|
pub fn tmux_kill_window(target : String) -> Command {
  { program: "tmux", args: ["kill-window", "-t", target], workdir: None }
}
