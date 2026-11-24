/** Tauri core API shim. The Kotlin host forwards commands to the shared Rust FFI. */
import { invoke as invokeHost } from './host';

export function invoke<T>(command: string, args: Record<string, unknown> = {}): Promise<T> {
	return invokeHost<T>(command, args);
}

export function isTauri(): boolean {
	return true;
}

/** Android's private app files are not exposed as file:// URLs to the WebView. Remote and data URLs
 * are already safe to use; local paths remain non-renderable until a scoped file provider exists. */
export function convertFileSrc(path: string): string {
	if (/^(https?:|data:|blob:|content:)/i.test(path)) return path;
	return '';
}
