/** Thin Tauri-compatible host bridge for Android's local WebView. The Rust core remains the single
 * source of playback, search, library, and lyrics state; this module carries invoke/event messages. */

type Pending = { resolve: (value: unknown) => void; reject: (reason: unknown) => void };
type Handler = (event: { event: string; id: number; payload: unknown }) => void;

declare global {
	interface Window {
		__ZTUNES_ANDROID__?: boolean;
		ZtunesBridge?: {
			invoke: (id: string, command: string, args: string) => void;
			postMessage: (action: string, payload: string) => void;
		};
		__ZTUNES_ANDROID_BRIDGE__?: {
			resolve: (id: string, ok: boolean, raw: string) => void;
			dispatch: (name: string, raw: string) => void;
			handleBack: () => boolean;
		};
	}
}

const pending = new Map<string, Pending>();
const handlers = new Map<string, Map<number, Handler>>();
let nextId = 1;
let nextListenerId = 1;

function parse(raw: string): unknown {
	try {
		return JSON.parse(raw);
	} catch {
		return raw;
	}
}

function resolve(id: string, ok: boolean, raw: string): void {
	const call = pending.get(id);
	if (!call) return;
	pending.delete(id);
	if (ok) call.resolve(parse(raw));
	else call.reject(new Error(raw || 'Android core request failed'));
}

function dispatch(name: string, raw: string): void {
	const payload = parse(raw);
	const event = { event: name, id: 0, payload };
	for (const handler of handlers.get(name)?.values() ?? []) {
		try {
			handler(event);
		} catch (error) {
			console.error('Ztunes event handler failed', name, error);
		}
	}
}

function handleBack(): boolean {
	// Give Bits UI, the app's sheets, and the full-screen player the usual Escape event first.
	const dialog = document.querySelector<HTMLElement>(
		'[role="dialog"], dialog[open], [data-state="open"][role="menu"]'
	);
	if (dialog) {
		const target = document.activeElement instanceof HTMLElement ? document.activeElement : dialog;
		target.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
		return true;
	}
	if (location.pathname !== '/' && history.length > 1) {
		history.back();
		return true;
	}
	return false;
}

if (typeof window !== 'undefined') {
	window.__ZTUNES_ANDROID_BRIDGE__ = { resolve, dispatch, handleBack };
}

export function invoke<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
	if (typeof window === 'undefined' || !window.ZtunesBridge) {
		return Promise.reject(new Error('Android bridge is not available'));
	}
	const id = String(nextId++);
	return new Promise<T>((resolvePromise, rejectPromise) => {
		pending.set(id, {
			resolve: (value) => resolvePromise(value as T),
			reject: rejectPromise
		});
		try {
			window.ZtunesBridge!.invoke(id, command, JSON.stringify(args ?? {}));
		} catch (error) {
			pending.delete(id);
			rejectPromise(error);
		}
	});
}

export function subscribe(name: string, handler: Handler): () => void {
	let group = handlers.get(name);
	if (!group) handlers.set(name, (group = new Map()));
	const id = nextListenerId++;
	group.set(id, handler);
	return () => {
		group?.delete(id);
		if (group?.size === 0) handlers.delete(name);
	};
}

export function ready(): void {
	window.ZtunesBridge?.postMessage('ui-ready', '{}');
}

export function isAndroidHost(): boolean {
	return typeof window !== 'undefined' && window.__ZTUNES_ANDROID__ === true;
}
