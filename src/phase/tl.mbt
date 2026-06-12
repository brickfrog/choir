///|
pub(all) enum TLEvent {
  ChildSpawned(child_id~ : String, agent_type~ : @types.AgentType)
  ChildCompleted(child_id~ : String)
  ChildFailed(child_id~ : String, reason~ : String)
  PRMerged(number~ : Int, url~ : String)
  AllChildrenDone
  OwnPRFiled(number~ : Int, url~ : String, branch~ : String)
} derive(Debug, Eq, ToJson, FromJson)

///|
pub impl Show for TLEvent with fn output(self, logger) -> Unit {
  self.to_repr().output(logger)
}
