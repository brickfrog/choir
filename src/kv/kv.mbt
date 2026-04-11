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
  ignore(self)
  ignore(key)
  None
}
