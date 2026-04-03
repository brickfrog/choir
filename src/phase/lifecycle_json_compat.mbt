///|
/// Persistence boundary between historical KV/JSONL shape and MoonBit `derive(ToJson)` JSON.
///
/// **Derived → legacy must be schema-aware:** a generic walk that maps every `Json::String` to
/// `{ "tag": ... }` would corrupt ordinary fields (`slug`, `branch`, `url`, `message`, …). Only
/// the typed `derived_*_to_legacy` functions here wrap enum positions; struct string fields pass
/// through unchanged. There is intentionally no `derived_enum_tree_to_legacy_tagged`.
///
/// Convert persisted `{ "tag": ... }` lifecycle JSON to MoonBit `derive(ToJson)` shape
/// (nullary variants as strings, payloads as `["Variant", { fields... }]`).
fn legacy_enum_tree_to_derived(j : Json) -> Json {
  match j {
    Object(obj) =>
      if !obj.contains("tag") {
        let out = Map::new()
        obj.each(fn(k, v) { out.set(k, legacy_enum_tree_to_derived(v)) })
        Json::object(out)
      } else {
        match obj.get("tag") {
          Some(String(tag)) => {
            let payload = Map::new()
            obj.each(fn(k, v) {
              if k != "tag" {
                payload.set(k, legacy_enum_tree_to_derived(v))
              }
            })
            if tag == "Supervising" && !payload.contains("wave") {
              payload.set("wave", (1).to_json())
            }
            if payload.is_empty() {
              Json::string(tag)
            } else {
              Json::array([Json::string(tag), Json::object(payload)])
            }
          }
          _ => j
        }
      }
    Array(arr) => Json::array(arr.map(legacy_enum_tree_to_derived))
    _ => j
  }
}

///|
fn is_wrapped_workflow(obj : Map[String, Json]) -> Bool {
  if obj.length() != 2 {
    return false
  }
  match obj.get("tag") {
    Some(String(t)) =>
      (t == "Supervisor" || t == "Dev" || t == "Worker") &&
      obj.contains("state")
    _ => false
  }
}

///|
fn legacy_workflow_json_to_derived(j : Json) -> Json {
  guard j is Object(obj) else { return legacy_enum_tree_to_derived(j) }
  if is_wrapped_workflow(obj) {
    match (obj.get("tag"), obj.get("state")) {
      (Some(String(tag)), Some(state)) =>
        Json::array([tag.to_json(), legacy_enum_tree_to_derived(state)])
      _ => legacy_enum_tree_to_derived(j)
    }
  } else {
    legacy_enum_tree_to_derived(j)
  }
}

///|
/// `derive(ToJson)` uses plain JSON strings for enum payloads (e.g. URLs). Only enum
/// positions may become `{ "tag": ... }` in persisted form — never arbitrary strings.
fn derived_finalize_reason_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    _ => j
  }
}

///|
fn derived_failure_reason_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(pk, pv) { m.set(pk, pv) })
          m.set("tag", tag.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_review_ownership_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(pk, pv) { m.set(pk, pv) })
          m.set("tag", tag.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_child_summary_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(pk, pv) {
            let v2 = match (tag, pk) {
              ("ReviewOwned" | "ExitRequestedDeferred", "state") =>
                derived_review_ownership_to_legacy(pv)
              ("Failed", "reason") => derived_failure_reason_to_legacy(pv)
              _ => pv
            }
            m.set(pk, v2)
          })
          m.set("tag", tag.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_child_lifecycle_to_legacy(j : Json) -> Json {
  guard j is Object(obj) else { return j }
  let out = Map::new()
  obj.each(fn(k, v) {
    let w = if k == "summary" { derived_child_summary_to_legacy(v) } else { v }
    out.set(k, w)
  })
  Json::object(out)
}

///|
fn derived_supervisor_lifecycle_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(pk, pv) {
            let v2 = match (tag, pk) {
              ("Supervising" | "WaveComplete", "children") =>
                match pv {
                  Array(ch) =>
                    Json::array(ch.map(derived_child_lifecycle_to_legacy))
                  _ => pv
                }
              ("Failed", "reason") => derived_failure_reason_to_legacy(pv)
              _ => pv
            }
            m.set(pk, v2)
          })
          m.set("tag", tag.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_dev_lifecycle_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(pk, pv) {
            let v2 = match (tag, pk) {
              ("ReviewOwned" | "ExitRequestedDeferred", "state") =>
                derived_review_ownership_to_legacy(pv)
              ("Done", "reason") => derived_finalize_reason_to_legacy(pv)
              ("Failed", "reason") => derived_failure_reason_to_legacy(pv)
              _ => pv
            }
            m.set(pk, v2)
          })
          m.set("tag", tag.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_worker_lifecycle_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(pk, pv) {
            let v2 = match (tag, pk) {
              ("Done", "reason") => derived_finalize_reason_to_legacy(pv)
              ("Failed", "reason") => derived_failure_reason_to_legacy(pv)
              _ => pv
            }
            m.set(pk, v2)
          })
          m.set("tag", tag.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_process_state_to_legacy(j : Json) -> Json {
  match j {
    String(tag) => { "tag": tag.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(pk, pv) {
            let v2 = match (tag, pk) {
              ("Finalizing" | "Finalized", "reason") =>
                derived_finalize_reason_to_legacy(pv)
              ("Failed", "reason") => derived_failure_reason_to_legacy(pv)
              _ => pv
            }
            m.set(pk, v2)
          })
          m.set("tag", tag.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_workflow_json_to_legacy(j : Json) -> Json {
  match j {
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(tag), inner) =>
          if tag == "Supervisor" {
            {
              "tag": tag.to_json(),
              "state": derived_supervisor_lifecycle_to_legacy(inner),
            }.to_json()
          } else if tag == "Dev" {
            {
              "tag": tag.to_json(),
              "state": derived_dev_lifecycle_to_legacy(inner),
            }.to_json()
          } else if tag == "Worker" {
            {
              "tag": tag.to_json(),
              "state": derived_worker_lifecycle_to_legacy(inner),
            }.to_json()
          } else {
            j
          }
        _ => j
      }
    _ => j
  }
}

///|
fn derived_agent_lifecycle_json_to_legacy(j : Json) -> Json {
  guard j is Object(root) else { return j }
  let out = Map::new()
  root.each(fn(k, v) {
    let w = match k {
      "workflow" => derived_workflow_json_to_legacy(v)
      "process" => derived_process_state_to_legacy(v)
      "role" | "agent_id" => v
      _ => v
    }
    out.set(k, w)
  })
  Json::object(out)
}

///|
fn legacy_agent_lifecycle_json_to_derived(j : Json) -> Json {
  guard j is Object(root) else { return j }
  let out = Map::new()
  root.each(fn(k, v) {
    let w = match k {
      "workflow" => legacy_workflow_json_to_derived(v)
      "process" => legacy_enum_tree_to_derived(v)
      "role" | "agent_id" => v
      _ => legacy_enum_tree_to_derived(v)
    }
    out.set(k, w)
  })
  Json::object(out)
}

///|
/// TL persisted JSON uses `phase` and `count` (not `number`) on `PRFiled`.
fn legacy_tl_phase_json_to_derived(j : Json) -> Json {
  guard j is Object(obj) else { return j }
  match obj.get("phase") {
    Some(String(phase)) => {
      let payload = Map::new()
      obj.each(fn(k, v) {
        if k == "phase" {
          ()
        } else if phase == "PRFiled" && k == "count" {
          payload.set("number", v)
        } else {
          payload.set(k, v)
        }
      })
      if phase == "Waiting" && !payload.contains("wave") {
        payload.set("wave", (1).to_json())
      }
      if payload.is_empty() {
        phase.to_json()
      } else {
        Json::array([phase.to_json(), Json::object(payload)])
      }
    }
    _ => j
  }
}

///|
fn derived_tl_phase_json_to_legacy(j : Json) -> Json {
  match j {
    String(phase) => { "phase": phase.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(phase), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(k, v) {
            if phase == "PRFiled" && k == "number" {
              m.set("count", v)
            } else {
              m.set(k, v)
            }
          })
          m.set("phase", phase.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}

///|
fn normalize_dev_phase_legacy_json(j : Json) -> Json {
  guard j is Object(obj) else { return j }
  let out = Map::new()
  obj.each(fn(k, v) { out.set(k, v) })
  match out.get("phase") {
    Some(String(p)) => {
      let q = match p {
        "PRFiled" => "PROpenUnreviewed"
        "UnderReview" => "PRUnderReview"
        "Approved" => "ApprovedAwaitingMerge"
        _ => p
      }
      out.set("phase", q.to_json())
    }
    _ => ()
  }
  Json::object(out)
}

///|
fn legacy_dev_phase_json_to_derived(j : Json) -> Json {
  let jn = match j {
    Object(_) => normalize_dev_phase_legacy_json(j)
    _ => j
  }
  guard jn is Object(obj) else { return jn }
  match obj.get("phase") {
    Some(String(phase)) => {
      let payload = Map::new()
      obj.each(fn(k, v) { if k != "phase" { payload.set(k, v) } })
      if payload.is_empty() {
        phase.to_json()
      } else {
        Json::array([phase.to_json(), Json::object(payload)])
      }
    }
    _ => jn
  }
}

///|
fn derived_dev_phase_json_to_legacy(j : Json) -> Json {
  match j {
    String(phase) => { "phase": phase.to_json() }.to_json()
    Array(arr) if arr.length() == 2 =>
      match (arr[0], arr[1]) {
        (String(phase), Object(payload)) => {
          let m = Map::new()
          payload.each(fn(k, v) { m.set(k, v) })
          m.set("phase", phase.to_json())
          Json::object(m)
        }
        _ => j
      }
    _ => j
  }
}
