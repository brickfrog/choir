///|
pub(all) struct KvStore {
  project_dir : String
}

///|
pub fn KvStore::new(project_dir : String) -> KvStore {
  { project_dir, }
}

///|
pub fn KvStore::get(self : KvStore, key : String) -> String? {
  let path = self.project_dir + "/.choir/kv/" + key
  let raw = @sys.read_file(path).trim().to_string()
  if raw == "" {
    None
  } else {
    Some(raw)
  }
}
