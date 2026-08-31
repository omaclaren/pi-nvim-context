import { randomBytes } from "node:crypto";
import {
	chmod,
	lstat,
	mkdir,
	readdir,
	readFile,
	rename,
	rm,
	stat,
	writeFile,
} from "node:fs/promises";
import { rmSync } from "node:fs";
import * as net from "node:net";
import { basename, dirname, join, resolve } from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

export const PROTOCOL_VERSION = 1;
export const MAX_PREFILL_BYTES = 256 * 1024;
// A JSON string can expand one UTF-8 byte to a six-byte escape (for example, "\\u0000").
const MAX_REQUEST_BYTES = MAX_PREFILL_BYTES * 6 + 16 * 1024;
const MAX_UNIX_SOCKET_PATH_BYTES = process.platform === "darwin" ? 103 : 107;
const RUNTIME_DIR_ENV = "PI_NVIM_CONTEXT_RUNTIME_DIR";

interface BridgeManifest {
	protocol: number;
	socketPath: string;
	pid: number;
	cwd: string;
	sessionId: string;
	sessionFile?: string;
	sessionName?: string;
	startedAt: string;
	updatedAt: string;
}

interface BridgeRuntime {
	active: boolean;
	ctx: ExtensionContext;
	server: net.Server;
	connections: Set<net.Socket>;
	socketPath: string;
	manifestPath: string;
	startedAt: string;
	exitHandler: () => void;
}

interface RequestMessage {
	protocol?: unknown;
	type?: unknown;
	text?: unknown;
	summary?: unknown;
}

interface ResponseMessage {
	ok: boolean;
	type?: string;
	error?: string;
	info?: BridgeManifest;
}

export function getRuntimeDirectory(): string {
	const override = process.env[RUNTIME_DIR_ENV];
	if (override) return resolve(override);

	const uid = typeof process.getuid === "function" ? process.getuid() : "user";
	return join("/tmp", `pi-nvim-context-${uid}`);
}

async function ensureRuntimeDirectory(runtimeDirectory: string): Promise<void> {
	await mkdir(runtimeDirectory, { recursive: true, mode: 0o700 });
	const metadata = await lstat(runtimeDirectory);
	if (!metadata.isDirectory() || metadata.isSymbolicLink()) {
		throw new Error(`${runtimeDirectory} is not a secure directory`);
	}
	if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) {
		throw new Error(`${runtimeDirectory} is owned by another user`);
	}
	await chmod(runtimeDirectory, 0o700);
}

function processIsAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch (error) {
		return (error as NodeJS.ErrnoException).code === "EPERM";
	}
}

async function pruneStaleFiles(runtimeDirectory: string): Promise<void> {
	let entries: string[];
	try {
		entries = await readdir(runtimeDirectory);
	} catch {
		return;
	}

	await Promise.all(
		entries
			.filter((entry) => entry.endsWith(".json"))
			.map(async (entry) => {
				const manifestPath = join(runtimeDirectory, entry);
				const derivedSocketPath = manifestPath.slice(0, -".json".length) + ".sock";
				let socketPath = derivedSocketPath;
				let pid: number | undefined;
				try {
					const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as Partial<BridgeManifest>;
					if (
						typeof manifest.socketPath !== "string" ||
						dirname(resolve(manifest.socketPath)) !== runtimeDirectory
					) {
						throw new Error("Invalid bridge manifest");
					}
					socketPath = manifest.socketPath;
					if (!Number.isSafeInteger(manifest.pid) || (manifest.pid ?? 0) <= 0) {
						throw new Error("Invalid bridge PID");
					}
					pid = manifest.pid;
				} catch {
					await Promise.all([
						rm(manifestPath, { force: true }),
						rm(derivedSocketPath, { force: true }),
					]);
					return;
				}

				let socketExists = true;
				try {
					await stat(socketPath);
				} catch {
					socketExists = false;
				}
				if (!socketExists || (pid !== undefined && !processIsAlive(pid))) {
					await Promise.all([
						rm(manifestPath, { force: true }),
						rm(socketPath, { force: true }),
					]);
				}
			}),
	);
}

function manifestFor(runtime: BridgeRuntime, pi: ExtensionAPI): BridgeManifest {
	const sessionFile = runtime.ctx.sessionManager.getSessionFile();
	return {
		protocol: PROTOCOL_VERSION,
		socketPath: runtime.socketPath,
		pid: process.pid,
		cwd: runtime.ctx.cwd,
		sessionId: runtime.ctx.sessionManager.getSessionId(),
		...(sessionFile ? { sessionFile } : {}),
		...(pi.getSessionName() ? { sessionName: pi.getSessionName() } : {}),
		startedAt: runtime.startedAt,
		updatedAt: new Date().toISOString(),
	};
}

async function writeManifest(runtime: BridgeRuntime, pi: ExtensionAPI): Promise<void> {
	if (!runtime.active) return;
	const temporaryPath = `${runtime.manifestPath}.tmp-${randomBytes(4).toString("hex")}`;
	const serialized = `${JSON.stringify(manifestFor(runtime, pi))}\n`;
	try {
		await writeFile(temporaryPath, serialized, { encoding: "utf8", mode: 0o600 });
		if (!runtime.active) return;
		await rename(temporaryPath, runtime.manifestPath);
		if (!runtime.active) {
			await rm(runtime.manifestPath, { force: true });
			return;
		}
		await chmod(runtime.manifestPath, 0o600);
	} finally {
		await rm(temporaryPath, { force: true }).catch(() => undefined);
	}
}

function response(socket: net.Socket, message: ResponseMessage): void {
	if (socket.destroyed) return;
	socket.end(`${JSON.stringify(message)}\n`);
}

function appendSeparator(currentEditorText: string): string {
	if (currentEditorText.length === 0 || currentEditorText.endsWith("\n\n")) return "";
	if (currentEditorText.endsWith("\n")) return "\n";
	return "\n\n";
}

function safeSummary(value: unknown): string {
	if (typeof value !== "string") return "editor context";
	const singleLine = value.replace(/[\r\n]+/g, " ").trim();
	return singleLine.length > 0 ? singleLine.slice(0, 120) : "editor context";
}

function handleRequest(
	runtime: BridgeRuntime,
	pi: ExtensionAPI,
	socket: net.Socket,
	message: RequestMessage,
): void {
	if (!runtime.active) {
		response(socket, { ok: false, error: "Pi session is no longer active" });
		return;
	}

	if (message.protocol !== undefined && message.protocol !== PROTOCOL_VERSION) {
		response(socket, {
			ok: false,
			error: `Unsupported protocol version: ${String(message.protocol)}`,
		});
		return;
	}

	if (message.type === "ping" || message.type === "info") {
		response(socket, {
			ok: true,
			type: message.type,
			info: manifestFor(runtime, pi),
		});
		return;
	}

	if (message.type !== "prefill") {
		response(socket, { ok: false, error: `Unknown message type: ${String(message.type)}` });
		return;
	}

	if (typeof message.text !== "string" || message.text.trim().length === 0) {
		response(socket, { ok: false, error: "Prefill text must be a non-empty string" });
		return;
	}

	if (Buffer.byteLength(message.text, "utf8") > MAX_PREFILL_BYTES) {
		response(socket, {
			ok: false,
			error: `Prefill text exceeds ${MAX_PREFILL_BYTES} bytes`,
		});
		return;
	}

	try {
		const summary = safeSummary(message.summary);
		const currentEditorText = runtime.ctx.ui.getEditorText();
		runtime.ctx.ui.pasteToEditor(appendSeparator(currentEditorText) + message.text);
		runtime.ctx.ui.notify(`Added ${summary} from Neovim`, "info");
		response(socket, { ok: true, type: "prefilled" });
	} catch (error) {
		response(socket, {
			ok: false,
			error: error instanceof Error ? error.message : String(error),
		});
	}
}

function handleConnection(runtime: BridgeRuntime, pi: ExtensionAPI, socket: net.Socket): void {
	runtime.connections.add(socket);
	socket.setEncoding("utf8");
	socket.setTimeout(5000);

	let buffer = "";
	let handled = false;

	const cleanup = () => runtime.connections.delete(socket);
	socket.on("close", cleanup);
	socket.on("error", cleanup);
	socket.on("timeout", () => socket.destroy());

	socket.on("data", (chunk: string) => {
		if (handled) return;
		buffer += chunk;
		if (Buffer.byteLength(buffer, "utf8") > MAX_REQUEST_BYTES) {
			handled = true;
			response(socket, { ok: false, error: "Request is too large" });
			return;
		}

		const newline = buffer.indexOf("\n");
		if (newline < 0) return;
		handled = true;
		const line = buffer.slice(0, newline).trim();
		if (!line) {
			response(socket, { ok: false, error: "Request is empty" });
			return;
		}

		try {
			handleRequest(runtime, pi, socket, JSON.parse(line) as RequestMessage);
		} catch (error) {
			response(socket, {
				ok: false,
				error: `Invalid JSON: ${error instanceof Error ? error.message : String(error)}`,
			});
		}
	});
}

async function closeServer(server: net.Server): Promise<void> {
	if (!server.listening) return;
	await new Promise<void>((resolveClose) => {
		server.close(() => resolveClose());
	});
}

export default function piNvimContext(pi: ExtensionAPI): void {
	let currentRuntime: BridgeRuntime | null = null;

	const stopRuntime = async (): Promise<void> => {
		const runtime = currentRuntime;
		if (!runtime) return;
		currentRuntime = null;
		runtime.active = false;
		process.off("exit", runtime.exitHandler);
		for (const connection of runtime.connections) connection.destroy();
		await closeServer(runtime.server).catch(() => undefined);
		await Promise.all([
			rm(runtime.manifestPath, { force: true }),
			rm(runtime.socketPath, { force: true }),
		]).catch(() => undefined);
	};

	const startRuntime = async (ctx: ExtensionContext): Promise<void> => {
		await stopRuntime();
		if (ctx.mode !== "tui") return;

		if (process.platform === "win32") {
			ctx.ui.notify("pi-nvim-context currently requires Unix sockets", "warning");
			return;
		}

		const runtimeDirectory = getRuntimeDirectory();
		await ensureRuntimeDirectory(runtimeDirectory);
		await pruneStaleFiles(runtimeDirectory);

		const instanceId = `${process.pid}-${randomBytes(6).toString("hex")}`;
		const socketPath = join(runtimeDirectory, `${instanceId}.sock`);
		const manifestPath = join(runtimeDirectory, `${instanceId}.json`);
		if (Buffer.byteLength(socketPath, "utf8") > MAX_UNIX_SOCKET_PATH_BYTES) {
			throw new Error(`Unix socket path is too long: ${socketPath}`);
		}
		await rm(socketPath, { force: true });

		const server = net.createServer();
		const runtime: BridgeRuntime = {
			active: true,
			ctx,
			server,
			connections: new Set(),
			socketPath,
			manifestPath,
			startedAt: new Date().toISOString(),
			exitHandler: () => {
				rmSync(manifestPath, { force: true });
				rmSync(socketPath, { force: true });
			},
		};
		currentRuntime = runtime;

		server.on("connection", (socket) => handleConnection(runtime, pi, socket));
		await new Promise<void>((resolveListen, rejectListen) => {
			const onError = (error: Error) => rejectListen(error);
			server.once("error", onError);
			server.listen(socketPath, () => {
				server.off("error", onError);
				resolveListen();
			});
		});

		if (currentRuntime !== runtime || !runtime.active) {
			await closeServer(server).catch(() => undefined);
			await Promise.all([
				rm(manifestPath, { force: true }),
				rm(socketPath, { force: true }),
			]).catch(() => undefined);
			return;
		}

		server.on("error", (error) => {
			if (runtime.active) runtime.ctx.ui.notify(`Neovim bridge error: ${error.message}`, "error");
		});
		await chmod(socketPath, 0o600);
		await writeManifest(runtime, pi);
		process.once("exit", runtime.exitHandler);
	};

	pi.on("session_start", async (_event, ctx) => {
		try {
			await startRuntime(ctx);
		} catch (error) {
			await stopRuntime();
			if (ctx.mode === "tui") {
				ctx.ui.notify(
					`Could not start Neovim context bridge: ${error instanceof Error ? error.message : String(error)}`,
					"error",
				);
			}
		}
	});

	pi.on("session_info_changed", async (_event, ctx) => {
		const runtime = currentRuntime;
		if (!runtime?.active) return;
		runtime.ctx = ctx;
		await writeManifest(runtime, pi).catch(() => undefined);
	});

	pi.on("session_shutdown", async () => {
		await stopRuntime();
	});

	pi.registerCommand("nvim-context", {
		description: "Show Neovim context bridge status",
		handler: async (_args, ctx) => {
			const runtime = currentRuntime;
			if (!runtime?.active) {
				ctx.ui.notify("Neovim context bridge is not active in this mode", "warning");
				return;
			}
			ctx.ui.notify(
				[
					"Neovim context bridge is active.",
					`Session: ${pi.getSessionName() ?? runtime.ctx.sessionManager.getSessionId()}`,
					`Directory: ${basename(dirname(runtime.socketPath))}`,
				].join("\n"),
				"info",
			);
		},
	});
}
