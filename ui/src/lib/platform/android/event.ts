import { subscribe } from './host';

export type UnlistenFn = () => void;
export type Event<T> = { event: string; id: number; payload: T };

export async function listen<T>(
	event: string,
	handler: (event: Event<T>) => void,
	_options?: unknown
): Promise<UnlistenFn> {
	return subscribe(event, handler as (event: Event<unknown>) => void);
}

export async function once<T>(
	event: string,
	handler: (event: Event<T>) => void,
	_options?: unknown
): Promise<UnlistenFn> {
	let unlisten: UnlistenFn = () => {};
	unlisten = subscribe(event, (e) => {
		unlisten();
		handler(e as Event<T>);
	});
	return unlisten;
}

export async function emit<T>(event: string, payload?: T): Promise<void> {
	window.__ZTUNES_ANDROID_BRIDGE__?.dispatch(event, JSON.stringify(payload ?? null));
}
