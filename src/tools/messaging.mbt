///|
/// Pure plan for `notify_parent`: optional parent resolution (when the registry
/// is present) maps to delivery + success lifecycle, a resolve error, or the
/// no-registry best-effort path. The dispatcher runs `execute_delivery` and
/// `apply_dev_event` only for the planned variant.
pub(all) enum NotifyParentPlan {
  NoRegistry(dev_event~ : @phase.DevEvent, response~ : @types.Response)
  ParentResolveFailed(error_message~ : String)
  Deliver(
    delivery~ : @message.DeliveryMethod,
    dev_event_on_success~ : @phase.DevEvent,
    response_ok~ : @types.Response
  )
}

///|
pub fn notify_parent_plan(
  args : CallerMessageArgs,
  parent_resolution : Result[@types.Agent, @types.ChoirError]?,
) -> NotifyParentPlan {
  match parent_resolution {
    None => {
      let dev_event = @phase.DevEvent::NotifyParentSuccess(message=args.message)
      NoRegistry(
        dev_event~,
        response=@types.Response::ok_values({
          "status": String::to_json("notified"),
        }),
      )
    }
    Some(Err(e)) => ParentResolveFailed(error_message=e.message())
    Some(Ok(parent)) => {
      let delivery = @message.plan_delivery(
        parent,
        args.caller_id,
        args.message,
        args.status,
      )
      let dev_event_on_success = @phase.DevEvent::NotifyParentSuccess(
        message=args.message,
      )
      Deliver(
        delivery~,
        dev_event_on_success~,
        response_ok=@types.Response::ok_values({
          "status": String::to_json("notified"),
        }),
      )
    }
  }
}

///|
/// Exact `.choir/delivery.log` line for `send_message` (matches historical
/// dispatch formatting).
pub fn send_message_delivery_log_append(
  target_id : String,
  agent : @types.Agent,
  delivery : @message.DeliveryMethod,
) -> String {
  "[send_message] target=" +
  target_id +
  " terminal_target=" +
  agent.terminal_target.map(@types.LocalTarget::to_string).unwrap_or("NONE") +
  " delivery=" +
  delivery.to_display_string() +
  "\n"
}

///|
/// Pure plan for `send_message`: optional registry lookup maps to a no-registry
/// best-effort ok, target lookup error, or delivery + log line + success
/// response. The host appends `delivery_log_append` then runs `execute_delivery`.
pub(all) enum SendMessagePlan {
  NoRegistry(response~ : @types.Response)
  RegistryLookupFailed(error_message~ : String)
  Deliver(
    delivery~ : @message.DeliveryMethod,
    delivery_log_append~ : String,
    response_ok~ : @types.Response
  )
}

///|
pub fn send_message_plan(
  target_id : String,
  sender_id : String,
  message : String,
  status : @types.Status,
  registry_lookup : Result[@types.Agent, @types.ChoirError]?,
) -> SendMessagePlan {
  match registry_lookup {
    None =>
      NoRegistry(
        response=@types.Response::ok_values({
          "status": String::to_json("sent"),
        }),
      )
    Some(Err(e)) => RegistryLookupFailed(error_message=e.message())
    Some(Ok(agent)) => {
      let delivery = @message.plan_delivery(agent, sender_id, message, status)
      let delivery_log_append = send_message_delivery_log_append(
        target_id, agent, delivery,
      )
      Deliver(
        delivery~,
        delivery_log_append~,
        response_ok=@types.Response::ok_values({
          "status": String::to_json("sent"),
        }),
      )
    }
  }
}

///|
/// Effectful `send_message` adapter: delivery-log append, `execute_delivery`,
/// moontrace on failure. Preserves historical `ToolRequest::SendMessage` flow.
pub async fn interpret_send_message(
  plan : SendMessagePlan,
  project_dir : String,
  runner : async (Array[@workspace.Command]) -> Array[Int],
  sleep_fn? : async (Int) -> Unit = @async.sleep,
) -> @types.Response {
  match plan {
    SendMessagePlan::NoRegistry(response~) => response
    SendMessagePlan::RegistryLookupFailed(error_message~) =>
      @types.Response::Err(error_message)
    SendMessagePlan::Deliver(delivery~, delivery_log_append~, response_ok~) => {
      ignore(
        @sys.append_file_sync(
          project_dir + "/.choir/delivery.log",
          delivery_log_append,
        ),
      )
      match execute_delivery(delivery, runner, project_dir~, sleep_fn~) {
        Ok(_) => response_ok
        Err(e) => {
          @moontrace.error("send_message delivery failed", fields=[
            @moontrace.field("error", e.message()),
          ])
          @types.Response::Err(e.message())
        }
      }
    }
  }
}

///|
pub impl Show for NotifyParentPlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}

///|
pub impl Show for SendMessagePlan with output(self, logger) -> Unit {
  ignore(self)
  ignore(logger)
}
