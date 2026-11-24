<script lang="ts">
	/**
	 * App-wide states owned by stream p-settings, mounted once by the root layout:
	 * - Offline pill in the top bar (states.md "Offline"): "No internet connection available".
	 *   Goes up on the webview's `offline` event (or a dead network at launch) and comes down when
	 *   `reconnect.ts` says YouTube Music answers again.
	 * - Playback-health banner (`playback-health` event, polish stream): "Playback isn't working
	 *   right now", with Try again (re-runs the probe) and a close X.
	 * - Settings › Display "Open Now Playing view on play": opens the right panel when a new queue
	 *   starts.
	 * - The legacy `ui.settingsOpen` flag is routed to the page.
	 * - The first-run "Bring your music from Spotify" step, then "Using Ztunes on your iPhone too?".
 * - The device-linking dialog (devices.svelte.ts opens it from anywhere).
	 */
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import * as api from '$lib/api';
	import { whenBackOnline } from '$lib/reconnect';
	import { playback, ui } from '$lib/player.svelte';
	import { shell, openRight } from '$lib/shell/layout.svelte';
	import Icon from '$lib/kit/Icon.svelte';
	import Tooltip from '$lib/kit/Tooltip.svelte';
	import WifiSlashIcon from 'phosphor-svelte/lib/WifiSlashIcon';
	import WarningCircleIcon from 'phosphor-svelte/lib/WarningCircleIcon';
	import XIcon from 'phosphor-svelte/lib/XIcon';
	import { uiPrefs } from './prefs.svelte';
	import { downloads } from '$lib/downloads.svelte'; // stream: parity3
	import { toast } from '$lib/kit/toast';
	import Welcome from './Welcome.svelte';
	import PairDialog from './devices/PairDialog.svelte';
	import LinkWelcome from './devices/LinkWelcome.svelte';

	// ── offline ──
	let offline = $state(typeof navigator !== 'undefined' && !navigator.onLine);
	let cancelWait: (() => void) | null = null;
	function goOffline() {
		offline = true;
		cancelWait?.();
		cancelWait = whenBackOnline(() => {
			offline = false;
			cancelWait = null;
		});
	}

	// ── stream: parity3 ── the network monitor (NWPathMonitor) and Settings › Offline mode also
	// raise the pill, and going offline says why rows went grey (Spotify desktop's notice).
	const netDown = $derived(offline || !downloads.network.online);
	const offlineMode = $derived(downloads.network.offlineMode);
	let wasDown = false;
	$effect(() => {
		const down = netDown;
		if (down && !wasDown)
			toast("You're offline. Downloads still play.", { duration: 5000 });
		wasDown = down;
	});

	// ── playback health ──
	let health = $state<api.PlaybackHealth | null>(null);
	let checking = $state(false);
	async function recheck() {
		checking = true;
		try {
			const h = await api.playbackHealth();
			if (h.status === 'failed') health = h;
			else health = null;
			if (h.status === 'offline') goOffline();
		} catch {
			/* keep the banner */
		} finally {
			checking = false;
		}
	}

	onMount(() => {
		if (offline) goOffline();
		const off = () => goOffline();
		window.addEventListener('offline', off);
		const unlisten = api.onPlaybackHealth((h) => {
			if (h.status === 'failed') health = h;
			else if (h.status === 'offline') goOffline();
		});
		return () => {
			window.removeEventListener('offline', off);
			cancelWait?.();
			unlisten.then((f) => f()).catch(() => {});
		};
	});

	// ── legacy "open settings" flag → the page ──
	$effect(() => {
		if (!ui.settingsOpen) return;
		ui.settingsOpen = false;
		const focus = ui.settingsFocus;
		ui.settingsFocus = null;
		goto(focus ? `/settings#${focus}` : '/settings');
	});

	// ── open Now Playing when a new queue starts ──
	let lastSource: string | null | undefined = undefined;
	$effect(() => {
		const id = playback.now?.videoId;
		const source = playback.queue.sourceId ?? null;
		const key = id ? `${source ?? ''}` : null;
		if (lastSource === undefined) {
			lastSource = key; // what was playing at launch is not "pressing play"
			return;
		}
		if (key === lastSource || !id) return;
		lastSource = key;
		if (uiPrefs.nowPlayingOnPlay && shell.rightView === null && !playback.paused) openRight('now-playing');
	});
</script>

{#if netDown || offlineMode}
	<div class="fixed top-4 right-[116px] z-[60]">
		<Tooltip
			text={netDown ? 'No internet connection available' : 'Offline mode is on. Only downloaded music plays.'}
			side="bottom"
		>
			{#snippet trigger(p)}
				<span
					{...p}
					role="status"
					class="flex h-8 items-center gap-2 rounded-full bg-bg-highlight px-3 text-sm font-bold text-white"
				>
					<Icon icon={WifiSlashIcon} size={16} />
					{netDown ? 'Offline' : 'Offline mode'}
				</span>
			{/snippet}
		</Tooltip>
	</div>
{/if}

{#if health}
	<div
		role="alert"
		class="fixed bottom-[96px] left-1/2 z-[100] flex max-w-[calc(100vw-32px)] -translate-x-1/2 items-center gap-3 rounded-lg bg-announcement py-3 pr-3 pl-4 text-sm text-white shadow-menu"
	>
		<Icon icon={WarningCircleIcon} size={24} fill />
		<span class="min-w-0">
			<span class="font-bold">Playback isn't working right now.</span>
			A Ztunes update may fix it.
		</span>
		<button
			type="button"
			class="h-8 shrink-0 rounded-full bg-white px-4 text-sm font-bold text-black transition-transform hover:scale-[1.04] disabled:opacity-50"
			disabled={checking}
			onclick={recheck}
		>
			{checking ? 'Checking…' : 'Try again'}
		</button>
		<button
			type="button"
			aria-label="Dismiss"
			class="grid size-8 shrink-0 place-items-center rounded-full text-white/80 hover:text-white"
			onclick={() => (health = null)}
		>
			<Icon icon={XIcon} size={16} />
		</button>
	</div>
{/if}

<Welcome />
<LinkWelcome />
<PairDialog />
