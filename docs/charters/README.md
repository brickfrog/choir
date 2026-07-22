# Architecture Charters

These documents preserve the design contracts used to build Choir's current
workflow architecture:

- [Goal workflow](goal-workflow.md) defines the durable Goal, Part, Take,
  assurance, integration, publication, and recovery model.
- [Migration workflow](migration-workflow.md) extends that model for bounded,
  repeatable repository migrations. Its first two delivery slices are
  implemented; later slices remain staged work.

The charters explain architectural intent and acceptance boundaries. Current
source code, schemas, and passing conformance tests remain the authority for
what is implemented today.
