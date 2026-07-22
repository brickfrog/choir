///|
fn default_template_text(role : CommandRole) -> String {
  match role {
    ImplementationCommand =>
      "Implement the exact Part task supplied in the context. Obey the task contract, mutation boundary, and repository rules."
    PartVerificationCommand =>
      "Independently verify the exact candidate subject against the supplied Part task and declared changed paths. Report failure only for a defect attributable to this subject."
    PartAuditCommand =>
      "Independently audit the exact candidate subject against the supplied Part task and verification evidence. Findings must be attributable to this subject."
    GoalVerificationCommand =>
      "Independently verify the exact sealed Goal subject and its declared checks."
    GoalAuditCommand =>
      "Independently audit the exact sealed Goal subject and its verification evidence."
  }
}

///|
pub fn default_command_template(role : CommandRole) -> CommandTemplate {
  let content = @utf8.encode(default_template_text(role))
  { schema_version: 1, role, digest: digest_bytes(content), content }
}

///|
pub fn default_part_context_policy_digest() -> @control.Digest {
  digest_bytes(
    @utf8.encode("choir.part-context-policy.v1\u{00}instruction-only"),
  )
}

///|
pub fn provider_surface_and_profile_digest(
  surface : @control.ProviderSurfaceId,
  effective_surface_manifest_digest : @control.Digest,
  capability_profile_digest : @control.Digest,
) -> @control.Digest {
  digest_bytes(
    canonical_fields("choir.provider-surface-and-profile.v1", [
      provider_surface_tag(surface),
      effective_surface_manifest_digest.0,
      capability_profile_digest.0,
    ]),
  )
}
