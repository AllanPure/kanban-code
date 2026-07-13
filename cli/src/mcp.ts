#!/usr/bin/env node
/**
 * Kanban Code MCP server — structured board tools for the orchestrator agent.
 *
 * Speaks MCP over stdio. Every mutation goes through the same primitives as the
 * `kanban` CLI (readLinks / upsertCard), so the running app adopts the disk-owned
 * fields it already merges live (completedAt, labels, manuallyArchived, dependsOn on
 * new cards). This is why archive/label/done stick while the app is open.
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { resolve } from "node:path";
import { readLinks } from "./data.js";
import { upsertCard, isoNow, wouldCreateCycle } from "./cards.js";
import { generateKsuid } from "./ksuid.js";
import type { Link, ManualOverrides } from "./types.js";

const DEFAULT_TASK_OVERRIDES: ManualOverrides = {
  worktreePath: false,
  tmuxSession: false,
  name: true,
  column: false,
  prLink: false,
  issueLink: false,
};

const text = (s: string) => ({ content: [{ type: "text" as const, text: s }] });
const json = (o: unknown) => text(JSON.stringify(o, null, 2));

function projectName(l: Link): string {
  const p = l.projectPath ?? "";
  return p ? p.split("/").filter(Boolean).pop() ?? p : "";
}

/** Compact projection for lists (the full card is large and noisy). */
function summarize(l: Link) {
  return {
    id: l.id,
    name: l.name ?? l.promptBody?.slice(0, 60) ?? "(untitled)",
    column: l.column,
    project: projectName(l),
    archived: l.manuallyArchived,
    dependsOn: l.dependsOn,
    labels: l.labels,
    done: Boolean(l.completedAt),
    tmuxAlive: Boolean(l.tmuxLink?.sessionName),
  };
}

/** Find a card by exact id, throwing a clear error otherwise. */
function requireCard(links: Link[], id: string): Link {
  const c = links.find((l) => l.id === id);
  if (!c) throw new Error(`unknown card: ${id}`);
  return c;
}

const server = new McpServer({ name: "kanban", version: "0.1.0" });

server.registerTool(
  "list_cards",
  {
    description:
      "List board cards (compact). Filter by column and/or project (name substring or path). Archived cards are hidden unless includeArchived is true.",
    inputSchema: {
      column: z
        .enum(["backlog", "in_progress", "requires_attention", "in_review", "done", "all_sessions"])
        .optional()
        .describe("Filter by column"),
      project: z.string().optional().describe("Filter by project name substring or path"),
      includeArchived: z.boolean().optional().describe("Include archived cards (default false)"),
    },
  },
  async ({ column, project, includeArchived }) => {
    let links = readLinks();
    if (!includeArchived) links = links.filter((l) => !l.manuallyArchived);
    if (column) links = links.filter((l) => l.column === column);
    if (project) {
      const q = project.toLowerCase();
      links = links.filter(
        (l) => projectName(l).toLowerCase().includes(q) || (l.projectPath ?? "").toLowerCase().includes(q),
      );
    }
    return json({ count: links.length, cards: links.map(summarize) });
  },
);

server.registerTool(
  "show_card",
  {
    description: "Show the full detail of one card by id.",
    inputSchema: { card: z.string().describe("Card id") },
  },
  async ({ card }) => json(requireCard(readLinks(), card)),
);

server.registerTool(
  "create_task",
  {
    description:
      "Create a Backlog card. Returns the new card id. dependsOn must reference existing card ids (the card runs once they are all done).",
    inputSchema: {
      name: z.string().describe("Task title"),
      project: z.string().optional().describe("Project path the card belongs to (defaults to the server cwd)"),
      body: z.string().optional().describe("Task description; becomes the launch prompt when started"),
      dependsOn: z.array(z.string()).optional().describe("Card ids this task depends on"),
      labels: z.array(z.string()).optional().describe("Status label chips"),
    },
  },
  async ({ name, project, body, dependsOn, labels }) => {
    const links = readLinks();
    if (dependsOn?.length) {
      const known = new Set(links.map((l) => l.id));
      const missing = dependsOn.filter((id) => !known.has(id));
      if (missing.length) throw new Error(`unknown dependsOn card id(s): ${missing.join(", ")}`);
    }
    const now = isoNow();
    const card: Link = {
      id: generateKsuid("card"),
      name,
      projectPath: resolve(project ?? process.cwd()),
      column: "backlog",
      createdAt: now,
      updatedAt: now,
      lastActivity: now,
      manualOverrides: { ...DEFAULT_TASK_OVERRIDES },
      manuallyArchived: false,
      source: "manual",
      promptBody: body || undefined,
      dependsOn: dependsOn?.length ? dependsOn : undefined,
      labels: labels?.length ? labels : undefined,
      isRemote: false,
    };
    upsertCard(card);
    return json({ created: card.id, name });
  },
);

server.registerTool(
  "link_task",
  {
    description: "Add a dependency edge: <card> runs only once <dependsOn> is done. Rejects cycles.",
    inputSchema: {
      card: z.string().describe("Card that depends on another"),
      dependsOn: z.string().describe("Card that must finish first"),
    },
  },
  async ({ card, dependsOn }) => {
    const links = readLinks();
    const c = requireCard(links, card);
    requireCard(links, dependsOn);
    if (wouldCreateCycle(links, card, dependsOn)) throw new Error("that edge would create a dependency cycle");
    const deps = new Set(c.dependsOn ?? []);
    deps.add(dependsOn);
    c.dependsOn = [...deps];
    c.updatedAt = isoNow();
    upsertCard(c);
    return json({ card: c.id, dependsOn: c.dependsOn });
  },
);

server.registerTool(
  "unlink_task",
  {
    description: "Remove a dependency edge.",
    inputSchema: { card: z.string(), dependsOn: z.string() },
  },
  async ({ card, dependsOn }) => {
    const links = readLinks();
    const c = requireCard(links, card);
    const next = (c.dependsOn ?? []).filter((d) => d !== dependsOn);
    c.dependsOn = next.length ? next : undefined;
    c.updatedAt = isoNow();
    upsertCard(c);
    return json({ card: c.id, dependsOn: c.dependsOn ?? [] });
  },
);

server.registerTool(
  "label_card",
  {
    description: "Add status label chip(s) to a card (e.g. an Odoo module or a phase like 'in test').",
    inputSchema: { card: z.string(), labels: z.array(z.string()).describe("Labels to add") },
  },
  async ({ card, labels }) => {
    const links = readLinks();
    const c = requireCard(links, card);
    const set = new Set(c.labels ?? []);
    for (const l of labels) { const t = l.trim(); if (t) set.add(t); }
    c.labels = [...set];
    c.updatedAt = isoNow();
    upsertCard(c);
    return json({ card: c.id, labels: c.labels });
  },
);

server.registerTool(
  "unlabel_card",
  {
    description: "Remove status label chip(s) from a card.",
    inputSchema: { card: z.string(), labels: z.array(z.string()).describe("Labels to remove") },
  },
  async ({ card, labels }) => {
    const links = readLinks();
    const c = requireCard(links, card);
    const remove = new Set(labels.map((l) => l.trim()));
    const next = (c.labels ?? []).filter((l) => !remove.has(l));
    c.labels = next.length ? next : undefined;
    c.updatedAt = isoNow();
    upsertCard(c);
    return json({ card: c.id, labels: c.labels ?? [] });
  },
);

server.registerTool(
  "mark_done",
  {
    description:
      "Mark a task done — sets completedAt, which releases its dependents in the board's auto-scheduler. Idempotent (first signal wins).",
    inputSchema: { card: z.string() },
  },
  async ({ card }) => {
    const links = readLinks();
    const c = requireCard(links, card);
    const now = isoNow();
    c.completedAt = c.completedAt ?? now;
    c.updatedAt = now;
    upsertCard(c);
    return json({ card: c.id, completedAt: c.completedAt });
  },
);

server.registerTool(
  "archive_cards",
  {
    description:
      "Archive card(s) — hide them from the board and kill their tmux sessions. Reversible with unarchive_cards.",
    inputSchema: { cards: z.array(z.string()).describe("Card id(s) to archive") },
  },
  async ({ cards }) => {
    const links = readLinks();
    const targets = cards.map((id) => requireCard(links, id));
    const now = isoNow();
    for (const c of targets) { c.manuallyArchived = true; c.updatedAt = now; upsertCard(c); }
    return json({ archived: targets.map((c) => c.id) });
  },
);

server.registerTool(
  "unarchive_cards",
  {
    description: "Un-archive card(s) — bring them back onto the board.",
    inputSchema: { cards: z.array(z.string()).describe("Card id(s) to restore") },
  },
  async ({ cards }) => {
    const links = readLinks();
    const targets = cards.map((id) => requireCard(links, id));
    const now = isoNow();
    for (const c of targets) { c.manuallyArchived = false; c.updatedAt = now; upsertCard(c); }
    return json({ unarchived: targets.map((c) => c.id) });
  },
);

const transport = new StdioServerTransport();
await server.connect(transport);
