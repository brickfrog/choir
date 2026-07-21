///|
fn limits() -> @sandbox.TransferLimits {
  {
    max_entries: 4,
    max_total_bytes: 32L,
    max_file_bytes: 16L,
    max_depth: 3,
    link_policy: @sandbox.TransferLinkPolicy::TransferRejectLinks,
  }
}

///|
fn rejected(
  entries : Array[@sandbox.TransferEntry],
) -> @sandbox.TransferBlockReason {
  match @sandbox.evaluate_transfer_manifest(entries, limits()) {
    @sandbox.TransferManifestDecision::TransferManifestRejected(reason) =>
      reason
    @sandbox.TransferManifestDecision::TransferManifestAccepted(_) =>
      abort("expected transfer rejection")
  }
}

///|
test "transfer accepts bounded regular files and directories" {
  let decision = @sandbox.evaluate_transfer_manifest(
    [
      {
        path: "src",
        kind: @sandbox.TransferEntryKind::TransferDirectory,
        size_bytes: 0L,
      },
      {
        path: "src/main.mbt",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 12L,
      },
    ],
    limits(),
  )
  match decision {
    @sandbox.TransferManifestDecision::TransferManifestAccepted(manifest) => {
      assert_eq(manifest.total_bytes(), 12L)
      assert_eq(manifest.entries().length(), 2)
    }
    _ => fail("bounded manifest was rejected")
  }
}

///|
test "transfer rejects traversal absolute duplicate and backslash paths" {
  assert_eq(
    rejected([
      {
        path: "../secret",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 1L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferTraversalPath("../secret"),
  )
  assert_eq(
    rejected([
      {
        path: "/etc/passwd",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 1L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferAbsolutePath("/etc/passwd"),
  )
  assert_eq(
    rejected([
      {
        path: "src/a",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 1L,
      },
      {
        path: "src/a",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 1L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferDuplicatePath("src/a"),
  )
  assert_eq(
    rejected([
      {
        path: "src\\a",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 1L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferBackslashPath("src\\a"),
  )
}

///|
test "transfer rejects links special files and expansion bounds" {
  assert_eq(
    rejected([
      {
        path: "link",
        kind: @sandbox.TransferEntryKind::TransferSymlink,
        size_bytes: 0L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferUnsupportedEntryType(
      "link",
      @sandbox.TransferEntryKind::TransferSymlink,
    ),
  )
  assert_eq(
    rejected([
      {
        path: "dev",
        kind: @sandbox.TransferEntryKind::TransferDevice,
        size_bytes: 0L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferUnsupportedEntryType(
      "dev",
      @sandbox.TransferEntryKind::TransferDevice,
    ),
  )
  assert_eq(
    rejected([
      {
        path: "large",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 17L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferFileBytesExceeded("large", 17L, 16L),
  )
  assert_eq(
    rejected([
      {
        path: "a/b/c/d",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 1L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferDepthExceeded("a/b/c/d", 4, 3),
  )
  assert_eq(
    rejected([
      {
        path: "a",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 16L,
      },
      {
        path: "b",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 16L,
      },
      {
        path: "c",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 1L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferTotalBytesExceeded(33L, 32L),
  )
  assert_eq(
    rejected([
      {
        path: "a",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 0L,
      },
      {
        path: "b",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 0L,
      },
      {
        path: "c",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 0L,
      },
      {
        path: "d",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 0L,
      },
      {
        path: "e",
        kind: @sandbox.TransferEntryKind::TransferFile,
        size_bytes: 0L,
      },
    ]),
    @sandbox.TransferBlockReason::TransferEntryLimitExceeded(5, 4),
  )
}

///|
test "transfer rejects every link and special entry class" {
  let kinds = [
    @sandbox.TransferEntryKind::TransferSymlink,
    @sandbox.TransferEntryKind::TransferHardlink,
    @sandbox.TransferEntryKind::TransferDevice,
    @sandbox.TransferEntryKind::TransferFifo,
    @sandbox.TransferEntryKind::TransferSocket,
  ]
  for kind in kinds {
    assert_eq(
      rejected([{ path: "entry", kind, size_bytes: 0L }]),
      @sandbox.TransferBlockReason::TransferUnsupportedEntryType("entry", kind),
    )
  }
}

///|
test "transfer rejects invalid bounds and destination symlink traversal" {
  assert_eq(
    @sandbox.evaluate_transfer_manifest([], {
      max_entries: -1,
      max_total_bytes: 32L,
      max_file_bytes: 16L,
      max_depth: 3,
      link_policy: @sandbox.TransferLinkPolicy::TransferRejectLinks,
    }),
    @sandbox.TransferManifestDecision::TransferManifestRejected(
      @sandbox.TransferBlockReason::TransferInvalidLimits,
    ),
  )
  assert_true(
    @sandbox.validate_transfer_adoption_destination([
      {
        path: "artifacts",
        kind: @sandbox.TransferDestinationKind::TransferDestinationDirectory,
      },
      {
        path: "artifacts/result",
        kind: @sandbox.TransferDestinationKind::TransferDestinationSymlink,
      },
    ])
    is Err(_),
  )
  assert_true(
    @sandbox.validate_transfer_adoption_destination([
      {
        path: "artifacts",
        kind: @sandbox.TransferDestinationKind::TransferDestinationDirectory,
      },
      {
        path: "artifacts/result",
        kind: @sandbox.TransferDestinationKind::TransferDestinationMissing,
      },
    ])
    is Ok(_),
  )
  assert_true(
    @sandbox.validate_transfer_adoption_destination([
      {
        path: "artifacts",
        kind: @sandbox.TransferDestinationKind::TransferDestinationOther,
      },
    ])
    is Err(_),
  )
}

///|
test "transfer parses fixed archive listings before policy evaluation" {
  let listing =
    #|drwxr-xr-x 1000/1000         0 2026-07-20 22:51:46.1 "./"
    #|-rw-r--r-- 1000/1000        12 2026-07-20 22:51:46.1 "./src/main.mbt"
    #|lrwxrwxrwx 1000/1000         0 2026-07-20 22:51:46.1 "./AGENTS.md" -> "CLAUDE.md"
    #|drwxr-xr-x 1000/1000         0 2026-07-20 22:51:46.1 "./sub dir/"
    #|
  let entries = @sandbox.parse_transfer_archive_listing(listing).unwrap()
  assert_eq(entries, [
    {
      path: "src/main.mbt",
      kind: @sandbox.TransferEntryKind::TransferFile,
      size_bytes: 12L,
    },
    {
      path: "AGENTS.md",
      kind: @sandbox.TransferEntryKind::TransferSymlink,
      size_bytes: 0L,
    },
    {
      path: "sub dir",
      kind: @sandbox.TransferEntryKind::TransferDirectory,
      size_bytes: 0L,
    },
  ])
  assert_true(
    @sandbox.evaluate_transfer_manifest(
      entries,
      @sandbox.repository_result_transfer_limits(),
    ) is @sandbox.TransferManifestDecision::TransferManifestAccepted(_),
  )
}

///|
test "transfer listing parser rejects malformed or unknown rows" {
  assert_true(@sandbox.parse_transfer_archive_listing("not-a-row\n") is Err(_))
  assert_true(
    @sandbox.parse_transfer_archive_listing(
      "?rw-r--r-- 1000/1000 0 2026-07-20 22:51:46.1 \"./entry\"\n",
    ) is Err(_),
  )
  assert_true(
    @sandbox.parse_transfer_archive_listing(
      "-rw-r--r-- 1000/1000 0 2026-07-20 22:51:46.1 \"./bad\\nname\"\n",
    ) is Err(_),
  )
}

///|
test "repository result policy preserves symbolic links but rejects hardlinks" {
  let limits = @sandbox.repository_result_transfer_limits()
  assert_true(
    @sandbox.evaluate_transfer_manifest(
      [{
        path: "AGENTS.md",
        kind: @sandbox.TransferEntryKind::TransferSymlink,
        size_bytes: 0L,
      }],
      limits,
    ) is @sandbox.TransferManifestDecision::TransferManifestAccepted(_),
  )
  assert_true(
    @sandbox.evaluate_transfer_manifest(
      [{
        path: "alias",
        kind: @sandbox.TransferEntryKind::TransferHardlink,
        size_bytes: 0L,
      }],
      limits,
    ) is @sandbox.TransferManifestDecision::TransferManifestRejected(_),
  )
  assert_eq(
    @sandbox.evaluate_transfer_manifest(
      [{
        path: "AGENTS.md",
        kind: @sandbox.TransferEntryKind::TransferSymlink,
        size_bytes: 1L,
      }],
      limits,
    ),
    @sandbox.TransferManifestDecision::TransferManifestRejected(
      @sandbox.TransferBlockReason::TransferLinkHasContentSize("AGENTS.md"),
    ),
  )
}
