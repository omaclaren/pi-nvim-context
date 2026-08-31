import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import * as net from "node:net";
import { join } from "node:path";
import test from "node:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import piNvimContext, { PROTOCOL_VERSION } from "../index.js";

type Handler = (...args: unknown[]) => unknown;

function createMockPi(sessionName = "Bridge test") {
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
	piNvimContext(pi as unknown as ExtensionAPI);
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
	const pastes: string[] = [];
	const notifications: Array<{ message: string; type?: string }> = [];
	const context = {
		mode,
		hasUI: mode === "tui" || mode === "rpc",
		cwd: "/tmp/pi-nvim-context-project",
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
	};
}

test("Pi bridge exposes a private socket and prefills without submitting", async () => {
	const testRoot = await mkdtemp(join("/tmp", "pi-nvim-context-test-"));
	const runtimeDirectory = join(testRoot, "runtime");
	const originalOverride = process.env.PI_NVIM_CONTEXT_RUNTIME_DIR;
	process.env.PI_NVIM_CONTEXT_RUNTIME_DIR = runtimeDirectory;

	try {
		const { handlers, commands } = createMockPi();
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
			socketPath: string;
			cwd: string;
			sessionName: string;
		};

		assert.equal(manifest.protocol, PROTOCOL_VERSION);
		assert.equal(manifest.cwd, mock.context.cwd);
		assert.equal(manifest.sessionName, "Bridge test");
		assert.equal((await stat(runtimeDirectory)).mode & 0o777, 0o700);
		assert.equal((await stat(manifestPath)).mode & 0o777, 0o600);
		assert.equal((await stat(manifest.socketPath)).mode & 0o777, 0o600);

		const ping = await request(manifest.socketPath, {
			protocol: PROTOCOL_VERSION,
			type: "ping",
		});
		assert.equal(ping.ok, true);
		assert.equal(ping.type, "ping");

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
