///|
fn pinned_policy() -> @sandbox.BoxLiteSandboxPolicy {
  {
    policy_digest: @control.Digest(@sandbox.boxlite_policy_digest),
    image_digest: @control.Digest(@sandbox.boxlite_probe_image_digest),
    security: @sandbox.SandboxSecurityPolicy::SandboxSecurityRequired,
    network: @sandbox.SandboxNetworkProfile::NetworkDisabled,
    cpus: 1,
    memory_mib: 256,
    disk_size_gib: 1,
  }
}

///|
test "BoxLite adapter admits only the pinned deny-network policy" {
  assert_true(@sandbox.validate_boxlite_policy(pinned_policy()) is Ok(_))
  assert_true(
    @sandbox.validate_boxlite_policy({
      ..pinned_policy(),
      network: @sandbox.SandboxNetworkProfile::NetworkAllowlisted([]),
    })
    is Err(_),
  )
  assert_true(
    @sandbox.validate_boxlite_policy({
      ..pinned_policy(),
      image_digest: @control.Digest("sha256:drift"),
    })
    is Err(_),
  )
}

///|
fn effect_capability() -> @sandbox.SandboxEffectCapability {
  {
    goal_id: @control.GoalId("goal-boxlite"),
    take_id: @control.TakeId("take-boxlite"),
    fencing_epoch: @control.FencingEpoch(1L),
  }
}

///|
test "sandbox process specs cannot name host executables or ambient env" {
  let policy_digest = @control.Digest(@sandbox.boxlite_policy_digest)
  let tool_digest = @control.Digest("toolchain-digest")
  let valid : @sandbox.SandboxProcessSpec = {
    authority: @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
      @control.TakeId("take-boxlite"),
      @control.Digest("implementation-profile"),
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      tool_digest,
    ),
    arguments: ["test", "--target", "native"],
    working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot,
    environment: [{ key: "NO_COLOR", value: "1" }],
    stdin: @sandbox.SandboxStdinPolicy::SandboxStdinClosed,
    timeout_ms: 60000L,
    resources: {
      cpu_millis: 1000L,
      memory_bytes: 268435456L,
      process_count: 64,
      file_bytes: 1073741824L,
    },
    network: {
      profile: @sandbox.SandboxNetworkProfile::NetworkDisabled,
      version: 1L,
      policy_digest,
    },
    output: {
      stdout_limit_bytes: 1048576L,
      stderr_limit_bytes: 1048576L,
      on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
    },
  }
  assert_true(
    @sandbox.validate_sandbox_process_spec(
      valid,
      effect_capability(),
      policy_digest,
      fn(_) { true },
      fn(tool, digest) {
        tool == @sandbox.SandboxRegisteredToolId("moon") &&
        digest == tool_digest
      },
    )
    is Ok(_),
  )
  assert_true(
    @sandbox.validate_sandbox_process_spec(
      {
        ..valid,
        executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
          @sandbox.SandboxRegisteredToolId("shell"),
          tool_digest,
        ),
      },
      effect_capability(),
      policy_digest,
      fn(_) { true },
      fn(tool, _) { tool == @sandbox.SandboxRegisteredToolId("moon") },
    )
    is Err(_),
  )
  assert_true(
    @sandbox.validate_sandbox_process_spec(
      {
        ..valid,
        environment: [{ key: "LD_PRELOAD", value: "/host/inject.so" }],
      },
      effect_capability(),
      policy_digest,
      fn(_) { true },
      fn(_, _) { true },
    )
    is Err(_),
  )
  assert_true(
    @sandbox.validate_sandbox_process_spec(
      { ..valid, environment: [{ key: "bad-key", value: "x" }] },
      effect_capability(),
      policy_digest,
      fn(_) { true },
      fn(_, _) { true },
    )
    is Err(_),
  )
  assert_true(
    @sandbox.validate_sandbox_process_spec(
      { ..valid, arguments: ["test\u{00}injected"] },
      effect_capability(),
      policy_digest,
      fn(_) { true },
      fn(_, _) { true },
    )
    is Err(_),
  )
  assert_true(
    @sandbox.validate_sandbox_process_spec(
      { ..valid, arguments: Array::make(97, "argument") },
      effect_capability(),
      policy_digest,
      fn(_) { true },
      fn(_, _) { true },
    )
    is Err(_),
  )
}

///|
test "invalid process specs are rejected before adapter dispatch" {
  let called = @ref.new(false)
  let adapter : @sandbox.BoxLiteSandboxAdapter = {
    prepare: fn(_) { abort("unused prepare") },
    create: fn(_) { abort("unused create") },
    clone: fn(_) { abort("unused clone") },
    execute: fn(request) {
      called.val = true
      Ok({
        execution_key: request.execution_key,
        runtime_execution_id: "runtime-execution",
        lifecycle: @sandbox.SandboxResourceLifecycle::SandboxResourceRunning,
      })
    },
    attach: fn(_) { abort("unused attach") },
    copy: fn(_) { abort("unused copy") },
    signal_or_kill: fn(_) { abort("unused process control") },
    inspect: fn(_) { abort("unused inspect") },
    destroy: fn(_) { abort("unused destroy") },
  }
  let policy_digest = @control.Digest(@sandbox.boxlite_policy_digest)
  let request : @sandbox.ExecuteSandboxRequest = {
    capability: effect_capability(),
    resource_key: @sandbox.SandboxResourceKey("resource-1"),
    execution_key: @sandbox.RuntimeExecutionKey("execution-1"),
    process: {
      authority: @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
        @control.TakeId("take-boxlite"),
        @control.Digest("implementation-profile"),
      ),
      executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
        @sandbox.SandboxRegisteredToolId("shell"),
        @control.Digest("unregistered"),
      ),
      arguments: ["-c", "host command"],
      working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceRoot,
      environment: [],
      stdin: @sandbox.SandboxStdinPolicy::SandboxStdinClosed,
      timeout_ms: 1000L,
      resources: {
        cpu_millis: 1000L,
        memory_bytes: 134217728L,
        process_count: 16,
        file_bytes: 1048576L,
      },
      network: {
        profile: @sandbox.SandboxNetworkProfile::NetworkDisabled,
        version: 1L,
        policy_digest,
      },
      output: {
        stdout_limit_bytes: 1024L,
        stderr_limit_bytes: 1024L,
        on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
      },
    },
  }
  assert_true(
    @sandbox.dispatch_boxlite_execute(
      adapter,
      request,
      policy_digest,
      fn(_) { true },
      fn(_, _) { false },
    )
    is Err(_),
  )
  assert_false(called.val)
}
