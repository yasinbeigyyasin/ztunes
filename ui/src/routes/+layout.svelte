<script lang="ts">
	// The app frame (docs/spotify-spec/screens/shell-layout.md): black window, 8px padding and gaps,
	// top bar 64px, three rounded #121212 panels (library | main | right panel) with resizable
	// widths, player bar 72px. The mini player window renders only <MiniPlayer/>.
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import { browser } from '$app/environment';
	import { afterNavigate, goto } from '$app/navigation';
	import { cancelRestore, restoreTo } from '$lib/scrollrestore';
	import { onMount } from 'svelte';
	import { getCurrentWindow } from '@tauri-apps/api/window';
	import { Tooltip } from 'bits-ui';
	import { appearance, initTheme } from '$lib/theme.svelte';
	import { blockForeignDrag, dragScroll } from '$lib/dnd';
	import { suppressNative } from '$lib/menu';
	import LinkDialog from '$lib/components/LinkDialog.svelte';
	import { handleImportDrop, imp, initImport } from '$lib/import.svelte';
	import VideoSurface from '$lib/components/VideoSurface.svelte';
	import AndroidShell from '$lib/shell/AndroidShell.svelte';
	import { listen as listenTauri } from '@tauri-apps/api/event';
	import { ready as androidReady } from '$lib/platform/android/host';
	import { auth, initApp, playback, ui } from '$lib/player.svelte';
	import { initWin } from '$lib/win.svelte';
	import { initDevices } from '$lib/devices.svelte';
	import { initZoom } from '$lib/zoom.svelte';
	import { initShortcuts } from '$lib/shortcuts';
	import { initErrorLog } from '$lib/errlog';
	import { initAudio } from '$lib/audio.svelte';
	import { initPodcasts } from '$lib/podcasts.svelte';
	import { reloadSavedBooks } from '$lib/audiobooks.svelte'; // stream: audiobooks
	import {
		updateState,
		availableMessage,
		installUpdate,
		openDownloadPage,
		checkForUpdatesQuiet,
		QUIET_INTERVAL_MS
	} from '$lib/updater.svelte';
	import Toaster from '$lib/kit/Toaster.svelte';
	import ConfirmHost from '$lib/kit/ConfirmDialog.svelte';
	import { MenuHost } from '$lib/kit/menus';
	import { createFolder, createPlaylist, toggleLike } from '$lib/kit/actions';
	import TopBar from '$lib/shell/TopBar.svelte';
	import PlayerBar from '$lib/shell/PlayerBar.svelte';
	import AboutRecommendations from '$lib/smart/AboutRecommendations.svelte'; // leftovers
	import RightPanel from '$lib/shell/RightPanel.svelte';
	import ResizeHandle from '$lib/shell/ResizeHandle.svelte';
	import LibrarySidebar from '$lib/shell/LibrarySidebar.svelte';
	import GlobalBanners from '$lib/settings/GlobalBanners.svelte';
	import SignInSheet from '$lib/settings/SignInSheet.svelte';
	import {
		leftPx,
		leftRail,
		nudgeLeft,
		nudgeRight,
		setLeftWidth,
		setRightWidth,
		shell,
		toggleLeft,
		toggleRight
	} from '$lib/shell/layout.svelte';
	import { libraryUi, openSearch, setFilter } from '$lib/shell/library.svelte';
	import { focusSearch } from '$lib/shell/search.svelte';
	import { openSettings } from '$lib/shell/settings';
	import { nowPlayingSong } from '$lib/shell/nowplaying';
	import { initMenubar } from '$lib/shell/menubar';
	import { requestFind } from '$lib/shell/find.svelte';
	import { installImageGuard } from '$lib/imgguard';

	// SvelteKit `snapshot` keyed to the history entry: back/forward restores the main panel's scroll.
	let scroller = $state<HTMLElement | null>(null);
	export const snapshot = {
		capture: () => (scroller ? scroller.scrollTop : null),
		restore: (y: unknown) => {
			if (!scroller || typeof y !== 'number') return;
			restoreTo(scroller, y);
		}
	};
	afterNavigate((nav) => {
		shell.libraryExpanded = false;
		// The lyrics view covers the main view only; going somewhere (a library row, search) shows
		// that page, as in Spotify.
		if (nav.type !== 'enter') shell.lyricsOpen = false;
		if (!scroller || !nav.to) return;
		if (nav.type === 'popstate') return;
		cancelRestore();
		scroller.scrollTop = 0;
	});

	let { children } = $props();

	// ── stream: perf ── Dialogs, sheets and the full-screen views are code-split: none of them is
	// on screen at launch, and together they were ~90 KB of the startup bundle. Each mounts the
	// first time it is asked for and then stays mounted (close animations, kept state); all of
	// them are fetched once the app has been idle a few seconds, so even a first open is instant.
	const lazyDialogs = {
		shortcuts: () => import('$lib/shell/ShortcutsSheet.svelte'),
		add: () => import('$lib/components/AddToPlaylist.svelte'),
		newPlaylist: () => import('$lib/components/NewPlaylistDialog.svelte'),
		share: () => import('$lib/components/ShareDialog.svelte'),
		tempo: () => import('$lib/components/TempoPitchDialog.svelte'),
		channel: () => import('$lib/components/ChannelPicker.svelte'),
		import: () => import('$lib/components/ImportDialog.svelte'),
		theater: () => import('$lib/components/TheaterMode.svelte'),
		lyrics: () => import('$lib/shell/panels/LyricsTakeover.svelte')
	};
	const mounted = $state({
		shortcuts: false,
		add: false,
		newPlaylist: false,
		share: false,
		tempo: false,
		channel: false,
		import: false
	});
	$effect(() => {
		if (ui.shortcutsOpen) mounted.shortcuts = true;
		if (ui.addSongs) mounted.add = true;
		if (ui.newPlaylist) mounted.newPlaylist = true;
		if (ui.share) mounted.share = true;
		if (ui.tempoPitchOpen) mounted.tempo = true;
		if (ui.channelPickerOpen) mounted.channel = true;
		if (imp.open) mounted.import = true;
	});
	function prefetchDialogs() {
		const t = setTimeout(() => Object.values(lazyDialogs).forEach((f) => f().catch(() => {})), 4000);
		return () => clearTimeout(t);
	}

	const isMini = browser && (() => {
		try {
			return getCurrentWindow().label === 'mini';
		} catch {
			return false;
		}
	})();
	const isAndroid = browser && (window as any).__ZTUNES_ANDROID__ === true;

	if (browser) initTheme();

	// Main panel gutter: clamp(16px, 16px + (w - 600px) / 424 * 8, 24px) — shell-layout.md.
	let mainWidth = $state(800);
	const contentSpacing = $derived(appearance.compactLayout ? 12 : Math.min(24, Math.max(16, 16 + ((mainWidth - 600) / 424) * 8)));

	// Window title: "Track • Artist" while playing.
	$effect(() => {
		const n = playback.now;
		document.title = n && !playback.paused ? `${n.title} • ${n.artists}` : 'Ztunes';
	});

	onMount(() => {
		const mountedAt = performance.now(); // stream: perf
		if (!isAndroid) initErrorLog();
		installImageGuard(); // stream: tilefix
		if (isMini) {
			const a = initApp(true);
			const k = initShortcuts(true);
			return () => {
				a();
				k();
			};
		}
		if (isAndroid) {
			let startedAndroid = false;
			let teardownApp: (() => void) | undefined;
			let teardownDevices: (() => void) | undefined;
			const stopCoreListener = listenTauri('android-core-ready', () => {
				if (startedAndroid) return;
				startedAndroid = true;
				initErrorLog();
				teardownApp = initApp();
				teardownDevices = initDevices();
				initImport();
				initAudio().catch(() => {});
				initPodcasts().catch(() => {});
				reloadSavedBooks().catch(() => {});
			});
			androidReady();
			return () => {
				stopCoreListener.then((unlisten) => unlisten());
				teardownDevices?.();
				teardownApp?.();
			};
		}
		const teardownWin = initWin();
		checkForUpdatesQuiet();
		const updateTimer = setInterval(checkForUpdatesQuiet, QUIET_INTERVAL_MS);
		const teardownApp = initApp();
		const teardownZoom = initZoom();
		const teardownShortcuts = initShortcuts(false, {
			focusSearch,
			librarySearch: openSearch,
			libraryFilter: (f) => {
				if (leftRail()) toggleLeft();
				setFilter(f);
			},
			toggleLeft,
			nudgeLeft,
			nudgeRight,
			toggleRight,
			newPlaylist: () => createPlaylist(),
			newFolder: () => createFolder(),
			like: () => {
				const s = nowPlayingSong();
				if (s) toggleLike(s);
			},
			goToContext: () => {
				const id = playback.queue.sourceId;
				if (id) goto(`/playlist/${encodeURIComponent(id)}`);
			},
			settings: openSettings,
			find: requestFind
		});
		const teardownMenubar = initMenubar();
		const stopPrefetch = prefetchDialogs();
		initImport();
		initAudio().catch(() => {});
		initPodcasts().catch?.(() => {});
		reloadSavedBooks().catch(() => {}); // stream: audiobooks
		const teardownDevices = initDevices(); // device sync: status, focus → sync_set_active
		// stream: perf — dev-only timing probe, only when launched with ENCORE_PERF (lib.rs).
		const perfMode = window.__ENCORE_PERF__;
		if (perfMode) import('$lib/perfprobe').then((m) => m.runProbe(perfMode, mountedAt));
		return () => {
			clearInterval(updateTimer);
			teardownDevices();
			teardownApp();
			teardownWin();
			teardownZoom();
			teardownShortcuts();
			teardownMenubar();
			stopPrefetch();
		};
	});

	const takeover = $derived(shell.lyricsOpen && !!playback.now); // parity3

	function observeWidth(el: HTMLElement) {
		const ro = new ResizeObserver(([e]) => (mainWidth = e.contentRect.width));
		ro.observe(el);
		return () => ro.disconnect();
	}
	void libraryUi;
</script>

<svelte:window
	bind:innerWidth={shell.windowWidth}
	onkeydown={(e) => {
		// a11y: Esc closes layers innermost-first. Menus and dialogs (bits-ui) handle it and
		// preventDefault; what's left closes the lyrics / expanded Now Playing takeover (Spotify
		// shows "Esc" on its minimise button).
		if (e.key !== 'Escape' || e.defaultPrevented || e.metaKey || e.altKey || e.ctrlKey) return;
		if (shell.lyricsOpen && playback.now) {
			const t = e.target as HTMLElement | null;
			if (t?.closest?.('input,textarea,select,[contenteditable=true]')) return;
			e.preventDefault();
			shell.lyricsOpen = false;
			// Focus goes back to the control that opens it (the takeover's content is gone).
			requestAnimationFrame(() =>
				document.querySelector<HTMLElement>('[data-player-bar] button[aria-label="Lyrics"]')?.focus()
			);
		}
	}}
	ondragover={blockForeignDrag}
	ondrop={(e) => handleImportDrop(e) || blockForeignDrag(e)}
	oncontextmenu={suppressNative}
/>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>

{#if isMini}
	{#await import('$lib/components/MiniPlayer.svelte') then m}<m.default />{/await}
{:else}
	<Tooltip.Provider delayDuration={500} skipDelayDuration={300} disableHoverableContent>
	{#if isAndroid}
		<AndroidShell>{@render children()}</AndroidShell>
	{:else}
		<div
			data-app-shell
			class="grid h-screen w-screen overflow-hidden bg-bg-app px-2 pb-2 text-white {shell.resizing
				? 'cursor-col-resize select-none'
				: ''}"
			style="grid-template-rows:auto minmax(0,1fr) 8px auto;grid-template-columns:auto auto minmax(0,1fr) auto auto"
		>
			<!-- a11y: a grid so the DOM (= Tab) order can follow Spotify's — top bar, Your Library,
			     player bar, main view, right panel — while the player bar still sits at the bottom. -->
			<!-- a11y: Spotify's one skip link ("Skip to main content" → #main-view), first in tab order,
			     shown only while focused (white pill top-left, like Spotify's). -->
			<a
				href="#main-view"
				class="skip-link"
				onclick={(e) => {
					e.preventDefault();
					document.getElementById('main-view')?.focus();
				}}>Skip to main content</a
			>
			<div class="min-w-0" style="grid-area:1/1/2/-1"><TopBar /></div>
				{#if !shell.libraryExpanded}
					<!-- parity3: hidden (not unmounted) while lyrics are open, so scroll/filters survive. -->
					<!-- a11y: the navigation landmark holds the library and its resize handle (Spotify: nav "Main"). -->
					<nav aria-label="Main" class="shrink-0 {takeover ? 'hidden' : 'contents'}">
						<div class="min-h-0" style="grid-area:2/1;width:{leftPx()}px">
							<LibrarySidebar />
						</div>
						<div class="flex min-h-0" style="grid-area:2/2">
							<ResizeHandle side="left" width={leftPx()} onresize={setLeftWidth} label="Resize Your Library" />
						</div>
					</nav>
				{/if}
				<!-- The lyrics / expanded Now Playing view takes the whole width between the top bar and
				     the player bar (Spotify desktop, measured in parity round 3): Your Library and the
				     right panel are hidden while it is open and come back as they were on close. It sits
				     over <main> instead of swapping it out, so the page underneath keeps its state and
				     scroll position for when the view closes. -->
				<div class="min-w-0" style="grid-area:4/1/5/-1"><PlayerBar /></div>
				<div class="relative min-h-0 min-w-0" style="grid-area:2/3">
					<main
						id="main-view"
						tabindex="-1"
						data-app-main
						data-main-scroll
						class="scroll-area relative h-full min-w-0 overflow-x-hidden overflow-y-auto rounded-lg bg-bg-base outline-none [container-type:inline-size]"
						style="--content-spacing:{contentSpacing}px"
						inert={shell.lyricsOpen && !!playback.now}
						bind:this={scroller}
						{@attach dragScroll}
						{@attach observeWidth}
					>
						{#if shell.libraryExpanded}
							<div class="h-full"><LibrarySidebar mode="page" /></div>
						{:else}
							{#key `${auth.epoch}:${ui.epoch}`}
								{@render children()}
							{/key}
						{/if}
					</main>
					{#if shell.lyricsOpen && playback.now}
						<!-- a11y: while it covers the (inert) main view, the takeover is the main landmark. -->
						<div class="absolute inset-0 z-10 overflow-hidden rounded-lg" role="main" aria-label="Lyrics">
							<h1 class="visually-hidden">Lyrics</h1>
							{#await lazyDialogs.lyrics() then m}<m.default />{/await}
						</div>
					{/if}
				</div>
				{#if shell.rightView}
					<aside aria-label="Now Playing view" class={takeover ? 'hidden' : 'contents'}>
					<div class="flex min-h-0" style="grid-area:2/4">
					<ResizeHandle
						side="right"
						width={shell.rightWidth}
						onresize={setRightWidth}
						label="Resize Now Playing view"
					/>
					</div>
					<div class="min-h-0" style="grid-area:2/5;width:{shell.rightWidth}px">
						<RightPanel />
					</div>
					</aside>
				{/if}
				<!-- Owns the one <video> element; renders a zero-size parking box until borrowed. -->
				<VideoSurface />
		</div>
	{/if}

		{#if ui.theaterOpen && playback.now}
			{#await lazyDialogs.theater() then m}<m.default />{/await}
		{/if}

		{#if mounted.shortcuts}{#await lazyDialogs.shortcuts() then m}<m.default />{/await}{/if}
		{#if mounted.add}{#await lazyDialogs.add() then m}<m.default />{/await}{/if}
		{#if mounted.newPlaylist}{#await lazyDialogs.newPlaylist() then m}<m.default />{/await}{/if}
		{#if mounted.share}{#await lazyDialogs.share() then m}<m.default />{/await}{/if}
		{#if mounted.tempo}
			{#await lazyDialogs.tempo() then m}<m.default bind:open={ui.tempoPitchOpen} />{/await}
		{/if}
		{#if mounted.channel}{#await lazyDialogs.channel() then m}<m.default />{/await}{/if}
		<LinkDialog />
		<SignInSheet />
		{#if mounted.import}{#await lazyDialogs.import() then m}<m.default />{/await}{/if}
		<AboutRecommendations />
		<MenuHost />
		<ConfirmHost />
		<Toaster />
		<GlobalBanners />

		{#if updateState.available}
			<div
				class="pointer-events-auto fixed bottom-[104px] left-1/2 z-[100] flex -translate-x-1/2 items-center gap-4 rounded-lg bg-bg-menu px-4 py-3 text-sm text-white shadow-menu"
			>
				<span>{availableMessage(updateState.available)}</span>
				{#if updateState.canInstall}
					<button class="btn-white sm" onclick={installUpdate} disabled={updateState.installing}>
						{updateState.installing ? 'Installing…' : 'Install'}
					</button>
				{:else}
					<button class="btn-white sm" onclick={openDownloadPage}>Download</button>
				{/if}
				{#if !updateState.installing}
					<button class="text-text-subdued hover:text-white" onclick={() => (updateState.available = null)}>Later</button>
				{/if}
			</div>
		{/if}
	</Tooltip.Provider>
{/if}
