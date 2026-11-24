<script lang="ts">
	/**
	 * Top bar (shell-layout.md): 64px on black. macOS traffic lights float over its left end
	 * (titleBarStyle Overlay), then back/forward, logo; centred: Home (48px circle) + search pill
	 * (48px, 474px wide) with Browse; right: avatar menu (Settings, YouTube account — optional).
	 * The whole bar drags the window except its controls (`isWindowDrag`).
	 */
	import { afterNavigate, goto } from '$app/navigation';
	import { creatorOf } from '$lib/discover/format';
	import { page } from '$app/state';
	import { getCurrentWindow } from '@tauri-apps/api/window';
	import * as api from '$lib/api';
	import type { BrowseItem, SearchOverview, SearchSuggestions, SongItem } from '$lib/api';
	import { auth, noteSearch } from '$lib/player.svelte';
	import { asSong, openItem } from '$lib/browse';
	// ── lane magic-d6 ── the dropdown's entity recents and inline + / Follow (MAGIC-GAPS #18).
	import { addRecent, recentSearches, removeRecent, type RecentItem } from '$lib/discover/recents.svelte';
	import { openExplore } from '$lib/discover/play.svelte';
	import { isInLibrary, isLiked, isOwned, playSingle, toggleInLibrary, toggleLike } from '$lib/kit/actions';
	import Pill from '$lib/kit/Pill.svelte';
	import PlusCircleIcon from 'phosphor-svelte/lib/PlusCircleIcon';
	import CheckCircleIcon from 'phosphor-svelte/lib/CheckCircleIcon';
	import { thumb } from '$lib/thumb';
	import { win } from '$lib/win.svelte';
	import { isWindowDrag } from '$lib/utils';
	import Icon from '$lib/kit/Icon.svelte';
	import IconButton from '$lib/kit/IconButton.svelte';
	import Tooltip from '$lib/kit/Tooltip.svelte';
	import Logo from '$lib/kit/Logo.svelte';
	import { openItemMenu, openTrackMenu } from '$lib/kit/menus';
	import Skeleton from '$lib/kit/Skeleton.svelte';
	// ── stream: search-dropdown ── the dropdown lists the results page's own search (one shared
	// `searchOverview`, ~30 mixed rows from `search::dropdown_order`); the last query wins.
	import { overview, overviewNow } from '$lib/discover/overview';
	import { lastWins } from '$lib/lastwins';
	import HouseIcon from 'phosphor-svelte/lib/HouseIcon';
	import MagnifyingGlassIcon from 'phosphor-svelte/lib/MagnifyingGlassIcon';
	import CardsIcon from 'phosphor-svelte/lib/CardsIcon';
	import XIcon from 'phosphor-svelte/lib/XIcon';
	import CaretLeftIcon from 'phosphor-svelte/lib/CaretLeftIcon';
	import CaretRightIcon from 'phosphor-svelte/lib/CaretRightIcon';
	import UserCircleIcon from 'phosphor-svelte/lib/UserCircleIcon';
	import { searchFocus } from './search.svelte';
	import { openProfileMenu } from '$lib/settings/profileMenu';
	// ── stream: smart2 ── What's New bell (shell-layout.md: 32px, #b3b3b3 → white, 8px gaps).
	import BellIcon from 'phosphor-svelte/lib/BellIcon';
	import { bell, initBell } from '$lib/smart/bell.svelte';
	initBell();

	// ── back / forward (depth tracking, like the old titlebar) ──
	let depth = $state(0);
	let deepest = $state(0);
	afterNavigate((nav) => {
		if (nav.type === 'enter') depth = deepest = 0;
		else if (nav.delta !== undefined) depth = Math.max(0, depth + nav.delta);
		else deepest = depth += 1;
	});

	const onHome = $derived(page.url.pathname === '/');
	const onSearch = $derived(page.url.pathname.startsWith('/search'));

	// ── search field ──
	let input: HTMLInputElement;
	let value = $state(page.url.pathname.startsWith('/search') ? (page.url.searchParams.get('q') ?? '') : '');
	let focused = $state(false);
	let suggestions = $state<SearchSuggestions>({ queries: [], items: [] });
	let suggestFor = $state('');
	let active = $state(-1);
	let timer: ReturnType<typeof setTimeout> | undefined;
	const suggestReq = lastWins();
	// The dropdown's results: the overview of `ovFor` (`ovFailed`: its request failed).
	let ov = $state<SearchOverview | null>(null);
	let ovFor = $state('');
	let ovFailed = $state(false);
	const ovReq = lastWins();

	$effect(() => {
		if (searchFocus.seq > 0) {
			input?.focus();
			input?.select();
		}
	});

	// Spotify searches live as you type: ~250ms after the last key the main view shows the results
	// for the field's text, wherever you were. The first step onto the results page is a history
	// entry (Back returns to where you started); every keystroke after that replaces it, so history
	// isn't one entry per letter. The filter chip (`&type=`) survives a changed query.
	let navTimer: ReturnType<typeof setTimeout> | undefined;
	/** The URL query the field last navigated to, so `afterNavigate` can tell our own steps apart. */
	let navigatedFor: string | null = null;

	function searchUrl(q: string): string {
		if (!q) return '/search';
		const p = new URLSearchParams();
		p.set('q', q);
		const type = onSearch ? page.url.searchParams.get('type') : null;
		if (type) p.set('type', type);
		return `/search?${p.toString()}`;
	}

	function navigateLive(q: string, opts: { focus?: boolean } = {}) {
		clearTimeout(navTimer);
		const current = onSearch ? (page.url.searchParams.get('q') ?? '').trim() : null;
		if (current === q) return;
		navigatedFor = q;
		goto(searchUrl(q), {
			keepFocus: opts.focus ?? true,
			replaceState: onSearch,
			noScroll: onSearch
		});
	}

	/** Typeahead completions (the query rows on top); the results come from `loadResults`. */
	async function loadSuggestions(q: string) {
		const t = suggestReq.take();
		try {
			const s = await api.searchSuggestions(q);
			if (!t.current()) return;
			suggestions = s;
			suggestFor = q;
		} catch {
			if (t.current()) suggestFor = '';
		}
	}

	/** The same search the results page runs (shared request); an older query's answer is dropped. */
	async function loadResults(q: string) {
		const t = ovReq.take();
		const hit = overviewNow(q);
		if (hit) {
			ov = hit;
			ovFor = q;
			ovFailed = false;
			return;
		}
		try {
			const o = await overview(q);
			if (!t.current()) return;
			ov = o;
			ovFailed = false;
		} catch {
			if (!t.current()) return;
			ov = null;
			ovFailed = true;
		}
		ovFor = q;
	}

	function dropRequests() {
		clearTimeout(timer);
		clearTimeout(navTimer);
		suggestReq.drop();
		ovReq.drop();
		suggestions = { queries: [], items: [] };
		suggestFor = '';
	}

	function onInput() {
		clearTimeout(timer);
		clearTimeout(navTimer);
		active = -1;
		const q = value.trim();
		if (q.length < 1) {
			dropRequests();
			// Emptied by hand (backspace / ⌘⌫): back to Browse, like Spotify.
			if (onSearch) navTimer = setTimeout(() => navigateLive(''), 250);
			return;
		}
		// A query answered before (backspacing) shows at once; anything else waits for typing to
		// settle, then the dropdown and the results page ask together.
		if (overviewNow(q)) loadResults(q);
		timer = setTimeout(() => loadSuggestions(q), 150);
		navTimer = setTimeout(() => {
			navigateLive(q);
			loadResults(q);
		}, 250);
	}

	/** The X: empty the field, keep focus, and show Browse. */
	function clearField() {
		dropRequests();
		value = '';
		active = -1;
		input.focus();
		if (onSearch) navigateLive('');
		else {
			navigatedFor = '';
			goto('/search', { keepFocus: true });
		}
	}

	function submit(q = value.trim()) {
		if (!q) return;
		clearTimeout(timer);
		clearTimeout(navTimer);
		value = q;
		noteSearch(q);
		focused = false;
		input.blur();
		navigatedFor = q;
		const current = onSearch ? (page.url.searchParams.get('q') ?? '').trim() : null;
		if (current !== q) goto(searchUrl(q), { replaceState: onSearch });
	}

	// Keep the field in step with navigation it didn't make (Back/Forward, a recent search, a
	// link): the results page's query shows in the field; leaving search empties it.
	afterNavigate(() => {
		const q = page.url.pathname.startsWith('/search') ? (page.url.searchParams.get('q') ?? '') : '';
		const ours = navigatedFor !== null && navigatedFor === q.trim();
		navigatedFor = null;
		if (ours) return;
		if (document.activeElement === input && page.url.pathname.startsWith('/search')) return;
		dropRequests();
		value = q;
	});

	/** Focus with text in the field (back on the results page): its results, cached by now. */
	function onFocus() {
		focused = true;
		const q = value.trim();
		if (q && ovFor !== q) loadResults(q);
	}

	// The focused-empty dropdown lists the things you opened from search (with their art and type),
	// never what you typed: the same recent searches as /search and the iPhone.
	const recentItems = $derived(recentSearches.items.slice(0, 8));
	const showRecent = $derived(focused && !value.trim() && recentItems.length > 0);
	// Typing: never an empty overlay. Completions on top, then skeleton rows until this query's
	// results arrive (the overview is never empty: a correction, the library or "Try these" stand
	// in); if the search itself failed, the typed text as a row that opens the results page.
	const typed = $derived(value.trim());
	const showSuggest = $derived(focused && !!typed);
	const loading = $derived(showSuggest && ovFor !== typed);
	const results = $derived(showSuggest && ovFor === typed && ov ? (ov.dropdown ?? []) : []);
	type Row =
		| { kind: 'query'; text: string }
		| { kind: 'card'; item: BrowseItem }
		| { kind: 'song'; song: SongItem }
		| { kind: 'show'; item: RecentItem }
		| { kind: 'recent'; item: RecentItem };
	const entityRows = $derived<Row[]>(
		results.map((d): Row =>
			d.type === 'song'
				? { kind: 'song', song: d.song }
				: d.type === 'show'
					? { kind: 'show', item: { kind: 'podcast', id: d.show.id, title: d.show.title, subtitle: d.show.author, thumbnail: d.show.thumbnail ?? undefined } }
					: d.item.kind === 'song'
						? { kind: 'song', song: asSong(d.item) }
						: // A show or episode as the Top result opens its own page (`openExplore`), not a playlist's.
							(d.item.kind as string) === 'podcast' || (d.item.kind as string) === 'episode'
							? { kind: 'show', item: d.item }
							: { kind: 'card', item: d.item }
		)
	);
	const queryRows = $derived.by<Row[]>(() => {
		const qs = suggestFor === typed ? suggestions.queries.slice(0, 3).map((q) => ({ kind: 'query' as const, text: q.text })) : [];
		return qs.length || loading || entityRows.length ? qs : [{ kind: 'query', text: typed }];
	});
	const rows = $derived<Row[]>(
		showRecent
			? recentItems.map((item) => ({ kind: 'recent' as const, item }))
			: showSuggest
				? [...queryRows, ...entityRows]
				: []
	);
	const open = $derived(showRecent || showSuggest);
	/** A line above the results: a corrected query, or the soft "Try these". */
	const note = $derived.by(() => {
		if (!results.length || !ov) return '';
		if (ov.tryThese) return 'Try these';
		const c = ov.correction;
		return c && c.kind !== 'library' && c.kind !== 'offline' ? `Showing results for “${c.query}”` : '';
	});
	// ↑↓ keep the highlighted row in view inside the scrolling overlay.
	$effect(() => {
		if (open && active >= 0) document.getElementById(`search-opt-${active}`)?.scrollIntoView({ block: 'nearest' });
	});

	/** What an entity row draws. */
	function look(r: Exclude<Row, { kind: 'query' }>) {
		if (r.kind === 'song') {
			const s = r.song;
			return { id: s.video_id, title: s.title, sub: ['Song', s.artists].filter(Boolean).join(' • '), thumb: s.thumbnail, round: false };
		}
		const i = r.item;
		return { id: i.id, title: i.title, sub: kindLabel(i), thumb: i.thumbnail, round: i.kind === 'artist' };
	}

	/** Right-click: the song or card menu (shows and episodes have none here). */
	function rowMenu(e: MouseEvent, r: Row) {
		if (r.kind === 'song') openTrackMenu(e, [r.song]);
		else if (r.kind === 'card' || (r.kind === 'recent' && r.item.kind !== 'podcast' && r.item.kind !== 'episode'))
			openItemMenu(e, r.item as BrowseItem);
	}

	function pick(r: Row) {
		if (r.kind === 'query') {
			submit(r.text);
			return;
		}
		focused = false;
		input.blur();
		// Opening something from search makes it a recent search (it moves to the top if it was one).
		if (r.kind === 'song') {
			const s = r.song;
			addRecent({ kind: 'song', id: s.video_id, title: s.title, subtitle: s.artists, thumbnail: s.thumbnail });
			// A song plays on its own "from search", like a pick on the results page.
			playSingle(s, { search: typed || undefined });
			return;
		}
		addRecent(r.item);
		if (r.kind === 'card') openItem(r.item);
		else openExplore(r.item);
	}

	/** The row's inline action, without picking the row or closing the dropdown (Spotify). */
	function act(e: MouseEvent, run: () => unknown) {
		e.preventDefault();
		e.stopPropagation();
		run();
	}

	function onKey(e: KeyboardEvent) {
		if (e.key === 'ArrowDown') {
			active = Math.min(rows.length - 1, active + 1);
			e.preventDefault();
		} else if (e.key === 'ArrowUp') {
			active = Math.max(-1, active - 1);
			e.preventDefault();
		} else if (e.key === 'Delete' && showRecent && active >= 0 && rows[active]) {
			const r = rows[active];
			if (r.kind === 'recent') removeRecent(r.item.id);
			active = Math.min(active, rows.length - 2);
			e.preventDefault();
		} else if (e.key === 'Enter') {
			if (active >= 0 && rows[active]) pick(rows[active]);
			else submit();
			e.preventDefault();
		} else if (isEsc(e)) {
			escDown = true;
			onEscape();
			e.preventDefault();
		}
	}

	const isEsc = (e: KeyboardEvent) => e.key === 'Escape' || e.key === 'Esc' || e.keyCode === 27;
	/** Spotify: the first Escape closes the dropdown, the next one leaves the field (text kept). */
	function onEscape() {
		active = -1;
		if (open) focused = false;
		else input.blur();
	}
	// WKWebView hands Escape to the text system first when macOS shows an inline prediction
	// (or an IME is composing), and the page gets no keydown for it. The keyup still arrives,
	// so a keyup Escape whose keydown we never saw does the same job.
	let escDown = false;
	function onKeyUp(e: KeyboardEvent) {
		if (!isEsc(e)) return;
		if (!escDown) onEscape();
		escDown = false;
	}

	/** Bold the typed prefix (search-and-browse.md typeahead). */
	function split(text: string) {
		const q = value.trim().toLowerCase();
		if (q && text.toLowerCase().startsWith(q)) return [text.slice(0, q.length), text.slice(q.length)];
		return ['', text];
	}

	const KIND: Record<string, string> = {
		song: 'Song',
		artist: 'Artist',
		album: 'Album',
		playlist: 'Playlist',
		podcast: 'Podcast',
		episode: 'Episode'
	};
	const kindLabel = (i: BrowseItem | RecentItem) =>
		[KIND[i.kind] ?? 'Playlist', i.kind === 'artist' ? '' : creatorOf(i.subtitle)].filter(Boolean).join(' • ');

	// ── avatar menu ──
	const account = $derived(auth.account);
	const initial = $derived((account?.signedIn && account.name ? account.name : 'E').slice(0, 1).toUpperCase());
	// Content owned by stream p-settings ($lib/settings/profileMenu.ts).
	const avatarMenu = (e: MouseEvent) => openProfileMenu(e);

	const w = (() => {
		try {
			return getCurrentWindow();
		} catch {
			return null;
		}
	})();
	// The empty top bar drags the window, and double-clicking it does what macOS's "Double-click a
	// window's title bar to" setting says (zoom, minimise or nothing). Handled here rather than
	// with Tauri's `data-tauri-drag-region`, which only counts presses on the element itself (not
	// its empty wrappers) and always zooms. As in Tauri's script on macOS, the second click acts on
	// mouseup, and only if the pointer didn't move (a double-click-and-drag doesn't zoom).
	let down2: [number, number] | null = null;
	function chromeDown(e: MouseEvent) {
		if (e.button !== 0 || !isWindowDrag(e.target as Element)) return;
		e.preventDefault();
		if (e.detail === 2) down2 = [e.clientX, e.clientY];
		else if (e.detail === 1) w?.startDragging().catch(() => {});
	}
	async function chromeUp(e: MouseEvent) {
		const at = down2;
		down2 = null;
		if (e.button !== 0 || e.detail !== 2 || !at || !w || !isWindowDrag(e.target as Element)) return;
		if (at[0] !== e.clientX || at[1] !== e.clientY) return;
		const action = await api.titleBarDoubleClick().catch(() => 'Maximize');
		if (action === 'Minimize') await w.minimize();
		else if (action !== 'None') await w.toggleMaximize();
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<header
	data-window-drag
	class="relative z-30 flex h-16 shrink-0 items-center justify-between px-2 select-none"
	onmousedown={chromeDown}
	onmouseup={chromeUp}
>
	<!-- Left: (traffic lights) back / forward / logo -->
	<div class="flex items-center gap-2 {win.chrome === 'overlay' ? 'pl-[80px]' : 'pl-4'}">
		<IconButton
			icon={CaretLeftIcon}
			label="Go back"
			tooltipSide="bottom"
			disabled={depth === 0}
			iconSize={16}
			class="!bg-black/0"
			onclick={() => history.back()}
		/>
		<IconButton
			icon={CaretRightIcon}
			label="Go forward"
			tooltipSide="bottom"
			disabled={depth >= deepest}
			onclick={() => history.forward()}
		/>
		<Tooltip text="Ztunes" side="bottom">
			{#snippet trigger(props)}
				<a {...props} href="/" aria-label="Ztunes home" class="ml-2 text-white">
					<Logo size={32} />
				</a>
			{/snippet}
		</Tooltip>
	</div>

	<!-- Centre: home + search (centred in the window) -->
	<div class="absolute top-1/2 left-1/2 flex -translate-x-1/2 -translate-y-1/2 items-center gap-2">
		<Tooltip text="Home" side="bottom">
			{#snippet trigger(props)}
				<a
					{...props}
					href="/"
					aria-label="Home"
					class="grid size-12 shrink-0 place-items-center rounded-full bg-bg-highlight transition-transform duration-100 hover:scale-[1.04] {onHome
						? 'text-white'
						: 'text-text-subdued hover:text-white'}"
				>
					<Icon icon={HouseIcon} size={24} fill={onHome} />
				</a>
			{/snippet}
		</Tooltip>
		<div class="relative w-[clamp(240px,34vw,474px)]">
			<form
				role="search"
				class="group/search flex h-12 items-center rounded-full bg-bg-highlight pr-3 pl-3 transition-colors hover:bg-bg-elevated-highlight hover:shadow-[inset_0_0_0_1px_#535353] focus-within:!bg-bg-elevated-highlight focus-within:!shadow-[inset_0_0_0_2px_#fff]"
				onsubmit={(e) => {
					e.preventDefault();
					submit();
				}}
			>
				<button type="submit" class="text-text-subdued group-focus-within/search:text-white" aria-label="Search" tabindex="-1">
					<Icon icon={MagnifyingGlassIcon} size={24} />
				</button>
				<input
					bind:this={input}
					bind:value
					oninput={() => {
						focused = true;
						onInput();
					}}
					onkeydown={onKey}
					onkeyup={onKeyUp}
					onclick={() => (focused = true)}
					onfocus={onFocus}
					onblur={() =>
						setTimeout(() => {
							// A click outside closes it; a refocus within the delay (⌘K) doesn't.
							if (document.activeElement !== input) focused = false;
						}, 150)}
					role="combobox"
					aria-label="Songs, artists or podcasts"
					aria-autocomplete="list"
					aria-expanded={open}
					aria-controls="search-listbox"
					aria-activedescendant={open && active >= 0 ? `search-opt-${active}` : undefined}
					placeholder="Songs, artists or podcasts"
					spellcheck="false"
					autocomplete="off"
					autocorrect="off"
					autocapitalize="off"
					writingsuggestions="false"
					class="h-full min-w-0 flex-1 bg-transparent pl-3 text-base text-white outline-none placeholder:text-text-subdued"
				/>
				{#if value}
					<button
						type="button"
						aria-label="Clear search field"
						class="mr-2 text-text-subdued hover:text-white"
						onmousedown={(e) => e.preventDefault()}
						onclick={clearField}
					>
						<Icon icon={XIcon} size={24} />
					</button>
				{:else if focused}
					<span class="mr-3 flex gap-1 text-xs text-text-subdued">
						<span class="kbd !h-5 !min-w-5 !text-xs !leading-4">⌘</span><span class="kbd !h-5 !min-w-5 !text-xs !leading-4">K</span>
					</span>
				{/if}
				<span class="h-6 w-px bg-text-subdued/60"></span>
				<Tooltip text="Browse" side="bottom">
					{#snippet trigger(props)}
						<a
							{...props}
							href="/search"
							aria-label="Browse"
							class="ml-3 transition-transform hover:scale-[1.04] {onSearch && !page.url.searchParams.get('q')
								? 'text-white'
								: 'text-text-subdued hover:text-white'}"
						>
							<Icon icon={CardsIcon} size={24} fill={onSearch && !page.url.searchParams.get('q')} />
						</a>
					{/snippet}
				</Tooltip>
			</form>

			{#if open}
				<!-- Pressing on the overlay (its scrollbar, a heading) keeps the field focused, so only a
				     click outside closes it. -->
				<div
					class="absolute top-[calc(100%+8px)] right-0 left-0 z-[1060] max-h-[min(70vh,640px)] overflow-y-auto overscroll-contain rounded-lg bg-bg-elevated-highlight p-2 shadow-menu"
					role="listbox"
					id="search-listbox"
					tabindex="-1"
					aria-label={showRecent ? 'Recent searches' : 'Suggestions'}
					aria-busy={loading}
					onmousedown={(e) => e.preventDefault()}
				>
					{#if showRecent}
						<div role="presentation" class="px-3 pt-2 pb-2 text-base font-bold text-white">Recent searches</div>
					{:else}
						<!-- Keyboard legend (search-and-browse.md §3). -->
						<div aria-hidden="true" class="flex h-6 items-center justify-between px-2 text-xs text-text-subdued">
							<span class="flex items-center gap-1"
								><span class="kbd !h-4 !min-w-4 !text-[10px] !leading-3">↑</span><span
									class="kbd !h-4 !min-w-4 !text-[10px] !leading-3">↓</span
								> Navigate</span
							>
							<span class="flex items-center gap-1"
								><span class="kbd !h-4 !min-w-4 !text-[10px] !leading-3">Enter</span> Search</span
							>
						</div>
					{/if}
					{#each rows as r, i (i)}
						{#if note && showSuggest && i === queryRows.length}
							<div role="presentation" class="px-3 pt-2 pb-1 text-sm text-text-subdued">{note}</div>
						{/if}
						{#if r.kind === 'query'}
							{@const [b, rest] = split(r.text)}
							<div
								role="option"
								id="search-opt-{i}"
								tabindex="-1"
								aria-selected={active === i}
								class="group/row flex h-12 cursor-default items-center gap-3 rounded-sm px-3 text-base {active === i
									? 'bg-white/10'
									: 'hover:bg-white/10'}"
								onmousedown={(e) => {
									e.preventDefault();
									pick(r);
								}}
							>
								<Icon icon={MagnifyingGlassIcon} size={24} class="text-text-subdued" />
								<span class="min-w-0 flex-1 truncate text-white">
									<span class="font-bold">{b}</span>{rest}
								</span>
							</div>
						{:else}
							{@const it = look(r)}
							{@const song = r.kind === 'song' ? r.song : null}
							{@const lib = r.kind === 'card' ? r.item : null}
							{@const liked = song ? isLiked(song) : false}
							{@const saved = lib ? isInLibrary(lib) : false}
							<div
								role="option"
								id="search-opt-{i}"
								tabindex="-1"
								aria-selected={active === i}
								class="group/row flex h-16 cursor-default items-center gap-3 rounded-sm px-3 {active === i
									? 'bg-white/10'
									: 'hover:bg-white/10'}"
								data-testid={r.kind === 'recent' ? 'search-recent' : 'search-suggestion'}
								onmousedown={(e) => {
									if (e.button !== 0) return;
									e.preventDefault();
									pick(r);
								}}
								oncontextmenu={(e) => rowMenu(e, r)}
							>
								<img
									src={thumb(it.thumb, 96)}
									alt=""
									class="size-12 shrink-0 bg-bg-menu object-cover {it.round ? 'rounded-full' : 'rounded-sm'}"
								/>
								<div class="min-w-0 flex-1">
									<div class="truncate text-base text-white">{it.title}</div>
									<div class="truncate text-sm text-text-subdued">{it.sub}</div>
								</div>
								{#if r.kind === 'recent'}
									<!-- a11y: pointer-only; from the keyboard, Delete removes the highlighted recent. -->
									<button
										type="button"
										aria-label="Remove"
										aria-hidden="true"
										tabindex="-1"
										class="text-text-subdued opacity-0 group-hover/row:opacity-100 hover:text-white {active === i
											? 'opacity-100'
											: ''}"
										onmousedown={(e) => act(e, () => removeRecent(it.id))}
									>
										<Icon icon={XIcon} size={16} />
									</button>
								{:else if song}
									<!-- Spotify: + on hover (or the highlighted row); a liked song keeps its accent check. -->
									<button
										type="button"
										aria-label={liked ? 'Remove from Liked Songs' : 'Add to Liked Songs'}
										tabindex="-1"
										class="grid size-8 shrink-0 place-items-center transition-transform hover:scale-[1.04] {liked
											? 'text-accent'
											: `text-text-subdued hover:text-white ${active === i ? '' : 'opacity-0 group-hover/row:opacity-100'}`}"
										onmousedown={(e) => act(e, () => toggleLike(song))}
									>
										<Icon icon={liked ? CheckCircleIcon : PlusCircleIcon} size={16} fill={liked} />
									</button>
								{:else if lib?.kind === 'artist'}
									<!-- svelte-ignore a11y_no_static_element_interactions -->
									<span
										class="shrink-0 {saved || active === i ? '' : 'opacity-0 group-hover/row:opacity-100'}"
										onmousedown={(e) => act(e, () => {})}
									>
										<Pill variant="outline" onclick={() => toggleInLibrary(lib)}>{saved ? 'Following' : 'Follow'}</Pill>
									</span>
								{:else if lib && !isOwned(lib)}
									<button
										type="button"
										aria-label={saved ? 'Remove from Your Library' : 'Save to Your Library'}
										tabindex="-1"
										class="grid size-8 shrink-0 place-items-center transition-transform hover:scale-[1.04] {saved
											? 'text-accent'
											: `text-text-subdued hover:text-white ${active === i ? '' : 'opacity-0 group-hover/row:opacity-100'}`}"
										onmousedown={(e) => act(e, () => toggleInLibrary(lib))}
									>
										<Icon icon={saved ? CheckCircleIcon : PlusCircleIcon} size={16} fill={saved} />
									</button>
								{/if}
							</div>
						{/if}
					{/each}
					{#if loading}
						<Skeleton variant="library-row" count={6} class="!px-3" />
					{/if}
				</div>
			{/if}
		</div>
	</div>

	<!-- Right: What's New bell, avatar menu -->
	<div class="flex items-center gap-2 pr-2">
		<Tooltip text="What's New" side="bottom">
			{#snippet trigger(props)}
				<button
					{...props}
					type="button"
					aria-label={bell.count ? `What's New (${bell.count} new)` : "What's New"}
					class="relative grid size-8 place-items-center rounded-full transition-transform hover:scale-[1.04] {page.url.pathname === '/content-feed'
						? 'text-white'
						: 'text-text-subdued hover:text-white'}"
					onclick={() => goto('/content-feed')}
				>
					<Icon icon={BellIcon} size={16} fill={page.url.pathname === '/content-feed'} />
					{#if bell.count && page.url.pathname !== '/content-feed'}
						<span class="absolute top-1 right-1 size-2 rounded-full bg-announcement ring-2 ring-black"></span>
					{/if}
				</button>
			{/snippet}
		</Tooltip>
		<Tooltip text={account?.signedIn ? (account.name ?? 'Account') : 'Settings and account'} side="bottom">
			{#snippet trigger(props)}
				<button
					{...props}
					type="button"
					aria-label="Account and settings"
					class="grid size-12 place-items-center rounded-full bg-bg-highlight transition-transform hover:scale-[1.04]"
					onclick={avatarMenu}
				>
					{#if account?.signedIn && account.thumbnail}
						<img src={thumb(account.thumbnail, 64)} alt="" class="size-8 rounded-full object-cover" />
					{:else if account?.signedIn}
						<span class="grid size-8 place-items-center rounded-full bg-[#f573a0] text-sm font-bold text-black">{initial}</span>
					{:else}
						<Icon icon={UserCircleIcon} size={32} class="text-text-subdued" />
					{/if}
				</button>
			{/snippet}
		</Tooltip>
	</div>
</header>
