import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import * as net from "node:net";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { CompletionRunner } from "../completion.js";
import { PROTOCOL_VERSION, registerPiNvimContext } from "../index.js";

type Handler = (...args: unknown[]) => unknown;

function createMockPi(sessionName = "Bridge test", complete?: CompletionRunner) {
	const handlers = new Map<string, Handler[]>();
	const commands = new Map<string, unknown>();
	const pi = {
		on(event: string, handler: Handler) {
			handlers.set(event, [...(handlers.get(event) ?? []), handler]);
		},
		registerCommand(name: string, command: unknown) {
			commands.set(name, command);
		},
		getSessionName() {
			return sessionName;
		},
	};
	registerPiNvimContext(pi as unknown as ExtensionAPI, { complete });
	return { handlers, commands };
}

async function emit(
	handlers: Map<string, Handler[]>,
	event: string,
	...args: unknown[]
): Promise<void> {
	for (const handler of handlers.get(event) ?? []) {
		await handler(...args);
	}
}

function request(socketPath: string, payload: unknown): Promise<Record<string, unknown>> {
	return new Promise((resolveRequest, rejectRequest) => {
		const socket = net.createConnection(socketPath);
		let buffer = "";
		socket.setEncoding("utf8");
		socket.setTimeout(3000, () => socket.destroy(new Error("test request timed out")));
		socket.on("connect", () => socket.write(`${JSON.stringify(payload)}\n`));
		socket.on("data", (chunk: string) => {
			buffer += chunk;
			const newline = buffer.indexOf("\n");
			if (newline < 0) return;
			socket.end();
			resolveRequest(JSON.parse(buffer.slice(0, newline)) as Record<string, unknown>);
		});
		socket.on("error", rejectRequest);
	});
}

function createContext(mode: ExtensionContext["mode"] = "tui") {
	let editorText = "";
	let idle = true;
	const pastes: string[] = [];
	const notifications: Array<{ message: string; type?: string }> = [];
	const context = {
		mode,
		hasUI: mode === "tui" || mode === "rpc",
		cwd: "/tmp/pi-nvim-context-project",
		model: {
			provider: "openai-codex",
			id: "test-suggestion-model",
			name: "Test suggestion model",
			reasoning: true,
		},
		modelRegistry: {
			getApiKeyAndHeaders: async () => ({ ok: true, apiKey: "test-key" }),
		},
		isIdle: () => idle,
		ui: {
			getEditorText: () => editorText,
			pasteToEditor: (text: string) => {
				pastes.push(text);
				editorText += text;
			},
			notify: (message: string, type?: string) => notifications.push({ message, type }),
		},
		sessionManager: {
			getSessionId: () => "12345678-bridge-test",
			getSessionFile: () => "/tmp/session-bridge-test.jsonl",
		},
	};
	return {
		context: context as unknown as ExtensionContext,
		pastes,
		notifications,
		getEditorText: () => editorText,
		setIdle: (value: boolean) => {
			idle = value;
		},
	};
}

test("Pi bridge exposes a private socket and prefills without submitting", async () => {
	const testRoot = await mkdtemp(join("/tmp", "pi-nvim-context-test-"));
	const runtimeDirectory = join(testRoot, "runtime");
	const originalOverride = process.env.PI_NVIM_CONTEXT_RUNTIME_DIR;
	process.env.PI_NVIM_CONTEXT_RUNTIME_DIR = runtimeDirectory;

	try {
		const completionCalls: Array<{ prompt: string; options: Record<string, unknown> }> = [];
		let cancelledModelCall = false;
		const complete = (async (_model: unknown, modelContext: { messages?: Array<{ content?: Array<{ text?: string }> }> }, options: Record<string, unknown>) => {
			const prompt = modelContext.messages?.[0]?.content?.[0]?.text ?? "";
			completionCalls.push({ prompt, options });
			if (prompt.includes("CANCEL_ME")) {
				await new Promise<never>((_resolve, reject) => {
					const signal = options.signal as AbortSignal;
					signal.addEventListener("abort", () => {
						cancelledModelCall = true;
						reject(new Error("cancelled by test client"));
					}, { once: true });
				});
			}
			return {
				role: "assistant",
				content: [{
					type: "text",
					text: prompt.includes("<edit_instruction>")
						? "A clearer replacement."
						: prompt.includes("<insert_instruction>")
							? " A guided insertion."
							: " natural continuation",
				}],
				stopReason: "stop",
				timestamp: Date.now(),
			};
		}) as unknown as CompletionRunner;
		const { handlers, commands } = createMockPi("Bridge test", complete);
		const mock = createContext();
		assert.ok(commands.has("nvim-context"));

		await mkdir(runtimeDirectory, { mode: 0o700 });
		const staleSocket = join(runtimeDirectory, "stale.sock");
		const staleManifest = join(runtimeDirectory, "stale.json");
		await writeFile(staleSocket, "orphaned socket placeholder");
		await writeFile(staleManifest, JSON.stringify({
			protocol: PROTOCOL_VERSION,
			socketPath: staleSocket,
			pid: 2_147_483_647,
		}));

		await emit(handlers, "session_start", { reason: "startup" }, mock.context);
		const entries = await readdir(runtimeDirectory);
		assert.equal(entries.includes("stale.json"), false, "dead bridge manifests should be pruned");
		assert.equal(entries.includes("stale.sock"), false, "dead bridge sockets should be pruned");
		const manifestName = entries.find((entry) => entry.endsWith(".json"));
		assert.ok(
			manifestName,
			`manifest should be created; entries=${JSON.stringify(entries)} notifications=${JSON.stringify(mock.notifications)}`,
		);
		const manifestPath = join(runtimeDirectory, manifestName);
		const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as {
			protocol: number;
			capabilities: string[];
			socketPath: string;
			cwd: string;
			sessionName: string;
		};

		assert.equal(manifest.protocol, PROTOCOL_VERSION);
		assert.deepEqual(manifest.capabilities, ["prefill", "suggest", "guided-insertion"]);
		assert.equal(manifest.cwd, mock.context.cwd);
		assert.equal(manifest.sessionName, "Bridge test");
		assert.equal((await stat(runtimeDirectory)).mode & 0o777, 0o700);
		assert.equal((await stat(manifestPath)).mode & 0o777, 0o600);
		assert.equal((await stat(manifest.socketPath)).mode & 0o777, 0o600);

		const statusCommand = commands.get("nvim-context") as {
			handler: (args: string, ctx: ExtensionContext) => Promise<void>;
		};
		await statusCommand.handler("", mock.context);
		assert.match(mock.notifications.at(-1)?.message ?? "", /Pi working directory: \/tmp\/pi-nvim-context-project/);
		assert.match(mock.notifications.at(-1)?.message ?? "", /Use Space p p in Neovim to link this session explicitly/);

		const ping = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "ping",
		});
		assert.equal(ping.ok, true);
		assert.equal(ping.type, "ping");

		const completion = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "suggest",
			requestId: "completion-1",
			kind: "completion",
			prefix: "A sentence that needs",
			selection: "",
			suffix: ".",
			language: "markdown",
			label: "notes.md",
		});
		assert.equal(completion.ok, true);
		assert.equal(completion.type, "suggestion");
		assert.equal(completion.suggestion, " natural continuation");
		assert.equal(completion.modelLabel, "openai-codex/test-suggestion-model");
		assert.equal(completion.thinking, "off");
		assert.equal("reasoning" in completionCalls[0].options, false, "cursor completions keep thinking off");
		assert.match(completionCalls[0].prompt, /A sentence that needs⟦CURSOR⟧\./);
		assert.deepEqual(mock.pastes, [], "direct suggestions do not alter Pi's input editor");

		const insertion = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "suggest",
			requestId: "insertion-1",
			kind: "insertion",
			prefix: "This discussion needs",
			selection: "",
			suffix: " before the conclusion.",
			instruction: "Add a reference to the named book.",
			language: "markdown",
			label: "notes.md",
		});
		assert.equal(insertion.ok, true);
		assert.equal(insertion.suggestion, " A guided insertion.");
		assert.equal(insertion.thinking, "low");
		assert.equal(completionCalls[1].options.reasoning, "low");
		assert.equal(completionCalls[1].options.maxTokens, 4_000);
		assert.match(completionCalls[1].prompt, /<insert_instruction>\nAdd a reference to the named book\./);
		assert.match(completionCalls[1].prompt, /This discussion needs⟦CURSOR⟧ before the conclusion\./);
		assert.deepEqual(mock.pastes, [], "guided insertions do not alter Pi's input editor");

		const invalidInsertion = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "suggest",
			requestId: "insertion-invalid",
			kind: "insertion",
			prefix: "Before",
			selection: "",
			suffix: " after",
		});
		assert.equal(invalidInsertion.ok, false);
		assert.match(String(invalidInsertion.error), /Insertion instruction is empty/);
		assert.equal(completionCalls.length, 2, "invalid insertions do not call the model");

		const rewrite = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "suggest",
			requestId: "rewrite-1",
			kind: "rewrite",
			prefix: "Before. ",
			selection: "An awkward sentence.",
			suffix: " After.",
			instruction: "Make this clearer.",
			language: "markdown",
			label: "notes.md",
		});
		assert.equal(rewrite.ok, true);
		assert.equal(rewrite.suggestion, "A clearer replacement.");
		assert.equal(rewrite.thinking, "low");
		assert.equal(completionCalls[2].options.reasoning, "low");
		assert.match(completionCalls[2].prompt, /<edit_instruction>\nMake this clearer\./);
		assert.deepEqual(mock.pastes, [], "rewrites do not alter Pi's input editor");

		mock.setIdle(false);
		const busy = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "suggest",
			requestId: "busy-1",
			kind: "completion",
			prefix: "Busy",
			selection: "",
			suffix: "",
		});
		assert.equal(busy.ok, false);
		assert.match(String(busy.error), /Pi is busy/);
		mock.setIdle(true);

		const cancellingSocket = net.createConnection(manifest.socketPath);
		await once(cancellingSocket, "connect");
		cancellingSocket.write(`${JSON.stringify({
			protocol: PROTOCOL_VERSION,
			type: "suggest",
			requestId: "cancel-1",
			kind: "completion",
			prefix: "CANCEL_ME",
			selection: "",
			suffix: "",
		})}\n`);
		await new Promise((resolveDelay) => setTimeout(resolveDelay, 20));
		cancellingSocket.destroy();
		for (let attempt = 0; attempt < 50 && !cancelledModelCall; attempt += 1) {
			await new Promise((resolveDelay) => setTimeout(resolveDelay, 10));
		}
		assert.equal(cancelledModelCall, true, "closing the Neovim socket aborts its model call");

		const first = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "prefill",
			text: "Neovim file: `README.md`",
			summary: "current file",
		});
		assert.equal(first.ok, true);
		assert.deepEqual(mock.pastes, ["Neovim file: `README.md`"]);

		const second = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "prefill",
			text: "Neovim location: `README.md`, line 10",
			summary: "current\nlocation",
		});
		assert.equal(second.ok, true);
		assert.deepEqual(mock.pastes, [
			"Neovim file: `README.md`",
			"\n\nNeovim location: `README.md`, line 10",
		]);
		assert.equal(mock.getEditorText(), mock.pastes.join(""));
		assert.match(mock.notifications.at(-1)?.message ?? "", /Added current location from Neovim/);

		// JSON escaping can make a valid decoded payload much larger on the wire.
		const escapeHeavyText = "\\".repeat(150 * 1024);
		const escapeHeavy = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "prefill",
			text: escapeHeavyText,
			summary: "escape-heavy context",
		});
		assert.equal(escapeHeavy.ok, true);
		assert.equal(mock.pastes.at(-1), `\n\n${escapeHeavyText}`);

		const invalid = await request(manifest.socketPath, {
			protocol: 999,
			type: "prefill",
			text: "ignored",
		});
		assert.equal(invalid.ok, false);

		await emit(handlers, "session_shutdown", { reason: "quit" }, mock.context);
		assert.rejects(stat(manifestPath));
		assert.rejects(stat(manifest.socketPath));

		const printRuntime = join(testRoot, "print-runtime");
		process.env.PI_NVIM_CONTEXT_RUNTIME_DIR = printRuntime;
		const printExtension = createMockPi();
		const printContext = createContext("print");
		await emit(
			printExtension.handlers,
			"session_start",
			{ reason: "startup" },
			printContext.context,
		);
		await assert.rejects(readdir(printRuntime));
	} finally {
		if (originalOverride === undefined) {
			delete process.env.PI_NVIM_CONTEXT_RUNTIME_DIR;
		} else {
			process.env.PI_NVIM_CONTEXT_RUNTIME_DIR = originalOverride;
		}
		await rm(testRoot, { recursive: true, force: true });
	}
});
