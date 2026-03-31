///|
let dashboard_page : String =
  #|<!DOCTYPE html>
  #|<html lang='en'>
  #|<head>
  #|<meta charset='utf-8'>
  #|<meta name='viewport' content='width=device-width,initial-scale=1'>
  #|<title>Choir</title>
  #|<style>
  #|*{margin:0;padding:0;box-sizing:border-box}
  #|body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,monospace;background:#0d1117;color:#c9d1d9;font-size:14px}
  #|.top{display:flex;align-items:center;gap:16px;padding:12px 20px;background:#161b22;border-bottom:1px solid #30363d}
  #|.top h1{font-size:16px;font-weight:600;color:#f0f6fc}
  #|.badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:12px;font-weight:600}
  #|.b-working{background:#e5a100;color:#000}
  #|.b-review{background:#22c55e;color:#000}
  #|.b-changes{background:#a855f7;color:#fff}
  #|.b-failed{background:#ef4444;color:#fff}
  #|.b-done{background:#6b7280;color:#fff}
  #|.panels{display:flex;height:calc(100vh - 90px);overflow:hidden}
  #|.left{flex:6;overflow-y:auto;padding:16px;border-right:1px solid #30363d}
  #|.right{flex:4;overflow-y:auto;padding:16px}
  #|.agent{background:#161b22;border:1px solid #30363d;border-radius:6px;padding:10px 14px;margin-bottom:8px}
  #|.agent .id{font-weight:600;color:#f0f6fc}
  #|.agent .meta{font-size:12px;color:#8b949e;margin-top:4px}
  #|.tag{display:inline-block;padding:1px 6px;border-radius:4px;font-size:11px;font-weight:600;margin-left:6px}
  #|.t-Working{background:#e5a100;color:#000}
  #|.t-ReviewOwned,.t-ExitRequestedDeferred{background:#22c55e;color:#000}
  #|.t-ChangesRequested{background:#a855f7;color:#fff}
  #|.t-Failed{background:#ef4444;color:#fff}
  #|.t-Done,.t-Exitable{background:#6b7280;color:#fff}
  #|.t-Connected{background:#22c55e;color:#000}
  #|.t-Finalizing,.t-Finalized{background:#f59e0b;color:#000}
  #|.children{margin-left:20px;border-left:2px solid #30363d;padding-left:12px;margin-top:8px}
  #|table{width:100%;border-collapse:collapse}
  #|th{text-align:left;font-size:12px;color:#8b949e;padding:6px 8px;border-bottom:1px solid #30363d}
  #|td{padding:6px 8px;border-bottom:1px solid #21262d;font-size:13px}
  #|a{color:#58a6ff;text-decoration:none}
  #|a:hover{text-decoration:underline}
  #|.events{max-height:160px;overflow-y:auto;padding:8px 20px;border-top:1px solid #30363d;background:#0d1117;font-size:12px;font-family:monospace}
  #|.events div{padding:2px 0;color:#8b949e}
  #|.events .ts{color:#6b7280}
  #|.events .agent-id{color:#58a6ff}
  #|.events .arrow{color:#484f58}
  #|h2{font-size:13px;color:#8b949e;text-transform:uppercase;letter-spacing:1px;margin-bottom:12px}
  #|.empty{color:#484f58;font-style:italic;padding:20px}
  #|</style>
  #|</head>
  #|<body>
  #|<div class='top'>
  #|<h1>Choir</h1>
  #|<div id='badges'></div>
  #|</div>
  #|<div class='panels'>
  #|<div class='left'><h2>Agents</h2><div id='agents'><div class='empty'>No agents</div></div></div>
  #|<div class='right'><h2>Pull Requests</h2><div id='prs'><div class='empty'>No tracked PRs</div></div></div>
  #|</div>
  #|<div class='events' id='events'></div>
  #|<script>
  #|function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML}
  #|function badge(cls,n,label){return n>0?'<span class="badge '+cls+'">'+n+' '+label+'</span> ':''}
  #|function tag(cls){return '<span class="tag t-'+cls+'">'+cls+'</span>'}
  #|
  #|function renderBadges(d){
  #|  var status=d.server_alive?'':'<span class="badge b-failed">server stopped</span> ';
  #|  document.getElementById('badges').innerHTML=status+
  #|    badge('b-working',d.working,'working')+
  #|    badge('b-review',d.review,'review')+
  #|    badge('b-changes',d.changes,'fixes')+
  #|    badge('b-failed',d.failed,'failed')+
  #|    badge('b-done',d.done,'done');
  #|  if(!d.server_alive){
  #|    document.getElementById('agents').innerHTML='<div class="empty">Server stopped</div>';
  #|    document.getElementById('prs').innerHTML='<div class="empty">Server stopped</div>';
  #|  }
  #|}
  #|
  #|function agentCard(a){
  #|  var w=a.workflow||{};var ws=w.state||w;var wtag=ws.tag||'?';
  #|  var p=a.process||{};var ptag=p.tag||'?';
  #|  var role=a.role||'?';var id=a.agent_id||'?';
  #|  var pr='';if(ws.pr_number)pr=' PR #'+ws.pr_number;
  #|  var review='';if(ws.state&&ws.state.tag)review=' ('+ws.state.tag+')';
  #|  return '<div class="agent"><span class="id">'+esc(id)+'</span>'+
  #|    tag(wtag)+'<span class="tag t-'+ptag+'">'+ptag+'</span>'+
  #|    '<div class="meta">'+esc(role)+pr+review+'</div></div>';
  #|}
  #|
  #|function renderAgents(agents){
  #|  var el=document.getElementById('agents');
  #|  if(!agents.length){el.innerHTML='<div class="empty">No agents</div>';return}
  #|  var html='';
  #|  for(var i=0;i<agents.length;i++)html+=agentCard(agents[i]);
  #|  el.innerHTML=html;
  #|}
  #|
  #|function renderPRs(prs){
  #|  var el=document.getElementById('prs');
  #|  if(!prs.length){el.innerHTML='<div class="empty">No tracked PRs</div>';return}
  #|  var h='<table><tr><th>#</th><th>Branch</th><th>Agent</th><th>Review</th><th>CI</th></tr>';
  #|  for(var i=0;i<prs.length;i++){
  #|    var p=prs[i];var rs=p.last_review_state||'None';
  #|    var ci=p.last_ci_failed?'<span class="tag t-Failed">fail</span>':'ok';
  #|    h+='<tr><td><a href="'+esc(p.pr_url||'#')+'" target="_blank">#'+p.pr_number+'</a></td>';
  #|    h+='<td>'+esc(p.branch||'')+'</td><td>'+esc(p.agent_id||'')+'</td>';
  #|    h+='<td>'+tag(rs=='Approved'?'ReviewOwned':rs=='ChangesRequested'?'ChangesRequested':'Done')+'</td>';
  #|    h+='<td>'+ci+'</td></tr>';
  #|  }
  #|  el.innerHTML=h+'</table>';
  #|}
  #|
  #|function renderEvents(events){
  #|  var el=document.getElementById('events');
  #|  if(!events.length)return;
  #|  var h='';
  #|  for(var i=0;i<events.length;i++){
  #|    var e=events[i];var d=e.data||{};
  #|    var ts=new Date((e.ts||0)*1000).toLocaleTimeString();
  #|    h+='<div><span class="ts">'+ts+'</span> <span class="agent-id">'+esc(e.agent_id||'')+'</span> ';
  #|    h+='<span class="arrow">'+esc(d.from||'')+'  &#8594;  '+esc(d.to||'')+'</span></div>';
  #|  }
  #|  el.innerHTML=h;
  #|  el.scrollTop=el.scrollHeight;
  #|}
  #|
  #|function poll(url,cb){fetch(url).then(function(r){return r.json()}).then(cb).catch(function(){})}
  #|setInterval(function(){poll('/api/summary',renderBadges)},3000);
  #|setInterval(function(){
  #|  poll('/api/agents',renderAgents);
  #|  poll('/api/prs',renderPRs);
  #|  poll('/api/events',renderEvents);
  #|},5000);
  #|poll('/api/summary',renderBadges);
  #|poll('/api/agents',renderAgents);
  #|poll('/api/prs',renderPRs);
  #|poll('/api/events',renderEvents);
  #|</script>
  #|</body>
  #|</html>

///|
fn dashboard_parse_port(args : Array[String]) -> Int {
  for i = 0; i < args.length() - 1; i = i + 1 {
    if args[i] == "--port" {
      let s = args[i + 1]
      let mut n = 0
      let mut valid = true
      for c in s {
        if c >= '0' && c <= '9' {
          n = n * 10 + (c.to_int() - 48)
        } else {
          valid = false
          break
        }
      }
      if valid && n > 0 {
        return n
      }
    }
  }
  8080
}

///|
fn dashboard_list_files(
  project_dir : String,
  pattern : String,
) -> Array[String] {
  let tmp = "/tmp/choir-dash-" + @sys.get_pid().to_string() + ".tmp"
  let cmd = "ls " +
    project_dir +
    "/" +
    pattern +
    " 2>/dev/null > " +
    tmp +
    " 2>/dev/null"
  ignore(@sys.system(cmd))
  let output = @sys.read_file(tmp)
  ignore(@sys.delete_file_sync(tmp))
  let files = []
  for line in output.split("\n") {
    let trimmed = line.trim().to_string()
    if trimmed != "" {
      files.push(trimmed)
    }
  }
  files
}

///|
fn dashboard_agents_json(project_dir : String) -> String {
  let files = dashboard_list_files(project_dir, ".choir/kv/lifecycle--*")
  let child_ids = statusline_collect_child_ids(project_dir)
  let entries = []
  for path in files {
    let prefix = "/lifecycle--"
    let mut idx = -1
    for i = 0; i < path.length() - prefix.length(); i = i + 1 {
      let mut match_ = true
      for j = 0; j < prefix.length(); j = j + 1 {
        if path[i + j] != prefix[j] {
          match_ = false
          break
        }
      }
      if match_ {
        idx = i + prefix.length()
      }
    }
    if idx < 0 {
      continue
    }
    let agent_id = path[idx:].to_string()
    if child_ids.length() > 0 && !child_ids.contains(agent_id) {
      continue
    }
    let content = @sys.read_file(path)
    if content.trim().to_string() != "" {
      entries.push(content.trim().to_string())
    }
  }
  "[" + entries.join(",") + "]"
}

///|
fn dashboard_prs_json(project_dir : String) -> String {
  let content = @sys.read_file(project_dir + "/.choir/poller_state.json")
  let trimmed = content.trim().to_string()
  if trimmed == "" {
    "[]"
  } else {
    trimmed
  }
}

///|
fn dashboard_events_json(project_dir : String) -> String {
  let tmp = "/tmp/choir-dash-ev-" + @sys.get_pid().to_string() + ".tmp"
  let cmd = "tail -100 " +
    project_dir +
    "/.choir/events/*.jsonl 2>/dev/null | grep '^{' > " +
    tmp +
    " 2>/dev/null"
  ignore(@sys.system(cmd))
  let output = @sys.read_file(tmp)
  ignore(@sys.delete_file_sync(tmp))
  let entries = []
  for line in output.split("\n") {
    let trimmed = line.trim().to_string()
    if trimmed != "" && trimmed[0] == '{' {
      entries.push(trimmed)
    }
  }
  "[" + entries.join(",") + "]"
}

///|
fn dashboard_summary_json(project_dir : String) -> String {
  let (working, review, changes, failed, done) = statusline_count_agents(
    project_dir,
  )
  let pid = @sys.read_file(project_dir + "/.choir/server.pid")
    .trim()
    .to_string()
  let alive = if pid != "" { "true" } else { "false" }
  "{\"working\":\{working},\"review\":\{review},\"changes\":\{changes},\"failed\":\{failed},\"done\":\{done},\"server_alive\":\{alive}}"
}

///|
async fn dashboard_send_json(
  conn : @http.ServerConnection,
  body : String,
) -> Unit {
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "application/json",
    "Cache-Control": "no-cache",
  })
  ..write(body)
  .end_response()
}

///|
async fn dashboard_send_html(conn : @http.ServerConnection) -> Unit {
  conn
  ..send_response(200, "OK", extra_headers={
    "Content-Type": "text/html; charset=utf-8",
  })
  ..write(dashboard_page)
  .end_response()
}

///|
async fn dashboard_send_404(conn : @http.ServerConnection) -> Unit {
  conn
  ..send_response(404, "Not Found", extra_headers={
    "Content-Type": "text/plain",
  })
  ..write("not found")
  .end_response()
}

///|
fn dashboard_run() -> Unit {
  let args = @env.args()
  let port = dashboard_parse_port(args)
  let project_dir = @env.current_dir().unwrap_or(".")
  @sys.write_stdout("Dashboard: http://127.0.0.1:\{port}\n")
  @async.run_async_main(async fn() {
    let server = @http.Server::new(
      @socket.Addr::parse("127.0.0.1:" + port.to_string()),
      reuse_addr=true,
    )
    server.run_forever((request, _body, conn) => {
      match request.path {
        "/" => dashboard_send_html(conn)
        "/api/agents" =>
          dashboard_send_json(conn, dashboard_agents_json(project_dir))
        "/api/prs" => dashboard_send_json(conn, dashboard_prs_json(project_dir))
        "/api/events" =>
          dashboard_send_json(conn, dashboard_events_json(project_dir))
        "/api/summary" =>
          dashboard_send_json(conn, dashboard_summary_json(project_dir))
        _ => dashboard_send_404(conn)
      }
    })
  })
}
