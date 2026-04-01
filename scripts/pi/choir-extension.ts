/**
 * Choir Pi extension prototype.
 *
 * Intended use:
 * - manual Pi + Choir experiments (M1/M2)
 * - future materialization into `.choir/pi/` for Choir-managed Pi runtimes
 *
 * This extension does not implement orchestration logic itself.
 * It shells out to `choir tool ...` and exposes a Pi-native tool surface.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";

type ChoirRole = "root" | "tl" | "dev" | "worker";
type ToolParams = Record<string, unknown>;

type ChoirToolSpec = {
	name: string;
	label: string;
	description: string;
	roles: ChoirRole[];
	parameters: unknown;
	promptSnippet?: string;
	promptGuidelines?: string[];
};

const TL_ROLES: ChoirRole[] = ["root", "tl"];
const DEV_ROLES: ChoirRole[] = ["dev"];
const WORKER_ROLES: ChoirRole[] = ["worker"];

const childRoleEnum = Type.Union([Type.Literal("dev"), Type.Literal("tl")]);
const statusEnum = Type.Union([Type.Literal("success"), Type.Literal("failure"), Type.Literal("info")]);
const allAgentTypeEnum = Type.Union([
	Type.Literal("gemini"),
	Type.Literal("claude"),
	Type.Literal("moon_pilot"),
	Type.Literal("codex"),
	Type.Literal("cursor_agent"),
	Type.Literal("pi"),
]);
const workerAgentTypeEnum = Type.Union([
	Type.Literal("gemini"),
	Type.Literal("claude"),
	Type.Literal("moon_pilot"),
	Type.Literal("pi"),
]);

const multilineKeys = new Set([
	"read_first",
	"steps",
	"verify",
	"done_criteria",
	"boundary",
	"constraints",
	"key_decisions",
	"non_goals",
]);

const toolSpecs: ChoirToolSpec[] = [
	{
		name: "fork_wave",
		label: "fork_wave",
		description: "Spawn one or more Choir child agents in worktrees.",
		roles: TL_ROLES,
		promptSnippet: "Use this to delegate implementation or sub-TL work through Choir.",
		promptGuidelines: [
			"Prefer `tasks` for distinct parallel subtasks and `task + count` for identical best-of-N work.",
			"Use `role: \"tl\"` only when you intend to spawn a sub-team-lead.",
		],
		parameters: Type.Object({
			caller_id: Type.Optional(Type.String({ description: "Caller id override. Defaults from CHOIR_AGENT_ID or Choir config when available." })),
			task: Type.Optional(Type.String({ description: "Shared task for all leaves when using `count`." })),
			tasks: Type.Optional(Type.Array(Type.String({ description: "Per-leaf task string." }), { description: "Distinct per-leaf tasks." })),
			agent_type: Type.Optional(allAgentTypeEnum),
			role: Type.Optional(childRoleEnum),
			parent_branch: Type.Optional(Type.String({ description: "Parent branch (defaults to main/default branch)." })),
			count: Type.Optional(Type.Number({ description: "Leaf count when using a shared `task`." })),
			slug_prefix: Type.Optional(Type.String({ description: "Slug prefix for generated child ids." })),
			read_first: Type.Optional(Type.Array(Type.String(), { description: "Paths children should read first." })),
			steps: Type.Optional(Type.Array(Type.String(), { description: "Implementation steps." })),
			verify: Type.Optional(Type.Array(Type.String(), { description: "Verification commands." })),
			done_criteria: Type.Optional(Type.Array(Type.String(), { description: "Acceptance criteria." })),
			boundary: Type.Optional(Type.Array(Type.String(), { description: "Things children must not do." })),
			constraints: Type.Optional(Type.Array(Type.String(), { description: "Extra constraints." })),
			context: Type.Optional(Type.String({ description: "Additional wave context." })),
			key_decisions: Type.Optional(Type.Array(Type.String(), { description: "Already-fixed decisions." })),
			non_goals: Type.Optional(Type.Array(Type.String(), { description: "Explicit non-goals." })),
		}),
	},
	{
		name: "spawn_worker",
		label: "spawn_worker",
		description: "Spawn a non-branch-owning Choir worker for research or review.",
		roles: TL_ROLES,
		promptSnippet: "Use this for research/review tasks that should not own a branch or PR.",
		parameters: Type.Object({
			caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
			task: Type.String({ description: "Primary worker task." }),
			prompt: Type.Optional(Type.String({ description: "Full prompt override." })),
			slug: Type.Optional(Type.String({ description: "Worker slug override." })),
			agent_type: Type.Optional(workerAgentTypeEnum),
			type: Type.Optional(Type.String({ description: "Worker profile, e.g. research or review." })),
			read_first: Type.Optional(Type.Array(Type.String(), { description: "Paths the worker should read first." })),
			steps: Type.Optional(Type.Array(Type.String(), { description: "Suggested steps." })),
			verify: Type.Optional(Type.Array(Type.String(), { description: "Verification commands." })),
			done_criteria: Type.Optional(Type.Array(Type.String(), { description: "Acceptance criteria." })),
			boundary: Type.Optional(Type.Array(Type.String(), { description: "Things the worker must not do." })),
			constraints: Type.Optional(Type.Array(Type.String(), { description: "Extra constraints." })),
			context: Type.Optional(Type.String({ description: "Extra context or reasoning summary." })),
			key_decisions: Type.Optional(Type.Array(Type.String(), { description: "Already-fixed decisions." })),
			non_goals: Type.Optional(Type.Array(Type.String(), { description: "Explicit non-goals." })),
		}),
	},
	{
		name: "merge_pr",
		label: "merge_pr",
		description: "Merge a tracked Choir PR after review is clean.",
		roles: TL_ROLES,
		promptSnippet: "Use this to merge a child PR through Choir's tracked merge flow.",
		parameters: Type.Object({
			pr_number: Type.Number({ description: "Pull request number to merge." }),
			parent_branch: Type.Optional(Type.String({ description: "Parent branch (defaults to main)." })),
			caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
			force: Type.Optional(Type.Boolean({ description: "Bypass ChangesRequested guard." })),
		}),
	},
	{
		name: "resolve_review_thread",
		label: "resolve_review_thread",
		description: "Resolve a GitHub pull request review thread by thread id.",
		roles: [...TL_ROLES, ...DEV_ROLES],
		parameters: Type.Object({
			thread_id: Type.String({ description: "GitHub review thread id, e.g. PRT_kwDO..." }),
			caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
		}),
	},
	{
		name: "agent_list",
		label: "agent_list",
		description: "List active agents known to the Choir registry by default.",
		roles: TL_ROLES,
		parameters: Type.Object({
			parent_id: Type.Optional(Type.String({ description: "Optional parent id filter." })),
			include_inactive: Type.Optional(Type.Boolean({ description: "Show inactive/done agents too." })),
		}),
	},
	{
		name: "cancel_wave",
		label: "cancel_wave",
		description: "Cancel active children of the current caller.",
		roles: TL_ROLES,
		parameters: Type.Object({
			force: Type.Optional(Type.Boolean({ description: "Cancel even mid-review children." })),
		}),
	},
	{
		name: "file_pr",
		label: "file_pr",
		description: "Create or update a PR for the current branch through Choir.",
		roles: DEV_ROLES,
		promptSnippet: "Use this instead of raw `gh pr create` when operating as a Choir leaf.",
		parameters: Type.Object({
			caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
			branch: Type.Optional(Type.String({ description: "Leaf branch (defaults from Choir config when available)." })),
			parent_branch: Type.Optional(Type.String({ description: "Parent branch (defaults from Choir config when available)." })),
			title: Type.Optional(Type.String({ description: "PR title override." })),
			body: Type.Optional(Type.String({ description: "PR body override." })),
		}),
	},
	{
		name: "notify_parent",
		label: "notify_parent",
		description: "Send a status message to the current parent agent.",
		roles: [...DEV_ROLES, ...WORKER_ROLES],
		promptSnippet: "Use this to report blockers, findings, PR readiness, or completion back to the parent.",
		parameters: Type.Object({
			caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
			message: Type.String({ description: "Message to send to the parent." }),
			status: Type.Optional(statusEnum),
		}),
	},
	{
		name: "shutdown",
		label: "shutdown",
		description: "Tell Choir this agent is done and request pane shutdown.",
		roles: [...DEV_ROLES, ...WORKER_ROLES],
		parameters: Type.Object({
			caller_id: Type.Optional(Type.String({ description: "Caller id override." })),
		}),
	},
	{
		name: "task_list",
		label: "task_list",
		description: "List Choir tasks.",
		roles: [...DEV_ROLES, ...WORKER_ROLES],
		parameters: Type.Object({}),
	},
	{
		name: "task_get",
		label: "task_get",
		description: "Get a Choir task by id.",
		roles: [...DEV_ROLES, ...WORKER_ROLES],
		parameters: Type.Object({
			id: Type.String({ description: "Task id." }),
		}),
	},
	{
		name: "task_update",
		label: "task_update",
		description: "Update Choir task state/notes.",
		roles: DEV_ROLES,
		parameters: Type.Object({
			id: Type.String({ description: "Task id." }),
			status: Type.Optional(Type.String({ description: "New task status." })),
			assignee: Type.Optional(Type.String({ description: "Assignee." })),
			notes: Type.Optional(Type.String({ description: "Notes." })),
		}),
	},
];

function normalizeRole(value: string | undefined): ChoirRole {
	if (value === "root" || value === "tl" || value === "dev" || value === "worker") {
		return value;
	}
	return "tl";
}

function currentRole(): ChoirRole {
	return normalizeRole(process.env.CHOIR_ROLE);
}

function currentAgentId(): string | undefined {
	const value = process.env.CHOIR_AGENT_ID?.trim();
	return value ? value : undefined;
}

function normalizeParams(toolName: string, params: ToolParams): ToolParams {
	const normalized: ToolParams = { ...params };

	for (const key of multilineKeys) {
		const value = normalized[key];
		if (Array.isArray(value)) {
			normalized[key] = value.join("\n");
		}
	}

	if ((toolName === "fork_wave" || toolName === "spawn_worker" || toolName === "merge_pr" || toolName === "file_pr" || toolName === "notify_parent" || toolName === "shutdown") && !normalized.caller_id) {
		const agentId = currentAgentId();
		if (agentId) normalized.caller_id = agentId;
	}

	return normalized;
}

function renderResultText(result: unknown): string {
	if (result === undefined) return "{}";
	return JSON.stringify(result, null, 2);
}

async function runChoirTool(pi: ExtensionAPI, toolName: string, callerRole: ChoirRole, params: ToolParams, signal: AbortSignal) {
	const normalized = normalizeParams(toolName, params);
	const execResult = await pi.exec(
		"choir",
		["tool", toolName, "--caller-role", callerRole, "--json", JSON.stringify(normalized)],
		{ signal, timeout: 10 * 60 * 1000 },
	);

	const stdout = execResult.stdout.trim();
	const stderr = execResult.stderr.trim();

	if (stdout) {
		let parsed: any;
		try {
			parsed = JSON.parse(stdout);
		} catch {
			const extra = stderr ? ` stderr: ${stderr}` : "";
			throw new Error(`invalid JSON from choir tool ${toolName}: ${stdout}${extra}`);
		}
		if (parsed && typeof parsed === "object" && typeof parsed.ok === "boolean") {
			if (parsed.ok) {
				return parsed.result ?? {};
			}
			throw new Error(parsed.error || `choir tool ${toolName} failed`);
		}
	}

	const pieces = [stderr, stdout].filter(Boolean);
	const suffix = pieces.length > 0 ? `: ${pieces.join(" | ")}` : "";
	throw new Error(`choir tool ${toolName} failed${suffix}`);
}

function builtinToolsForRole(role: ChoirRole): string[] {
	if (role === "root" || role === "tl") {
		return ["read", "bash", "grep", "find", "ls"];
	}
	if (role === "dev") {
		return ["read", "bash", "edit", "write", "grep", "find", "ls"];
	}
	return ["read", "bash", "grep", "find", "ls"];
}

function extensionToolNamesForRole(role: ChoirRole): string[] {
	return toolSpecs.filter((spec) => spec.roles.includes(role)).map((spec) => spec.name);
}

function thinkingLevelForRole(role: ChoirRole): "high" | "medium" {
	if (role === "root" || role === "tl") return "high";
	return "medium";
}

export default function choirExtension(pi: ExtensionAPI) {
	const role = currentRole();

	for (const spec of toolSpecs) {
		if (!spec.roles.includes(role)) continue;
		pi.registerTool({
			name: spec.name,
			label: spec.label,
			description: spec.description,
			promptSnippet: spec.promptSnippet,
			promptGuidelines: spec.promptGuidelines,
			parameters: spec.parameters,
			async execute(_toolCallId, params, signal, onUpdate) {
				onUpdate?.({
					content: [{ type: "text", text: `Running choir tool ${spec.name}...` }],
				});
				const result = await runChoirTool(pi, spec.name, role, params as ToolParams, signal);
				return {
					content: [{ type: "text", text: renderResultText(result) }],
					details: result,
				};
			},
		});
	}

	pi.on("session_start", async () => {
		pi.setActiveTools([...builtinToolsForRole(role), ...extensionToolNamesForRole(role)]);
		pi.setThinkingLevel(thinkingLevelForRole(role));
	});

	pi.registerCommand("choir-role", {
		description: "Show the Choir role/config detected by the Pi extension",
		handler: async (_args, ctx) => {
			const agentId = currentAgentId() || "(none)";
			ctx.ui.notify(`Choir role: ${role}\nCHOIR_AGENT_ID: ${agentId}`, "info");
		},
	});
}
