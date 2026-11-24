<script lang="ts">
	import { openAboutRecommendations } from '$lib/smart/AboutRecommendations.svelte'; // leftovers
	/**
	 * Playlist page — own playlists (`LOCALPLAYLIST:n`), YouTube playlists and Liked Songs (`VLLM`).
	 * Spec: spotify-spec/screens/playlist.md, liked-songs.md, overlays.md (Edit details), states.md.
	 */
	import { untrack } from 'svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { SvelteSet } from 'svelte/reactivity';
	import * as api from '$lib/api';
	import type { BrowseItem, PlaylistPage, SkipReason, SongItem } from '$lib/api';
	import {
		ActionBar,
		EmptyState,
		ErrorState,
		LIKED_TINT,
		PageHeader,
		Pill,
		Skeleton,
		StickyHeader,
		TrackTable,
		actions,
		openItemMenu,
		sortedOrder,
		toast,
		type Tint,
		type TrackColumn,
		type TrackSort
	} from '$lib/kit';
	import { lib } from '$lib/library.svelte';
	import { isTracksDrag, readTrackDrop } from '$lib/dnd'; // lane magic-d2
	import { resolveTrackDrop } from '$lib/dndTracks';
	import { toastUndo } from '$lib/kit/toast';
	import { confirmDialog } from '$lib/kit/confirm.svelte';
	import { auth } from '$lib/player.svelte';
	import { thumb } from '$lib/thumb';
	import HeartIcon from 'phosphor-svelte/lib/HeartIcon';
	import PlusIcon from 'phosphor-svelte/lib/PlusIcon';
	import PencilSimpleIcon from 'phosphor-svelte/lib/PencilSimpleIcon';
	import Mosaic from '$lib/collections/Mosaic.svelte';
	import LikedCover from '$lib/collections/LikedCover.svelte';
	import Recommended from '$lib/collections/Recommended.svelte';
	// ── stream: smart2 ── Smart Shuffle + Made for you labels.
	import SuggestionRow from '$lib/smart/SuggestionRow.svelte';
	import {
		addSuggestion,
		removeSuggestion,
		smartShuffle,
		cycleShuffle,
		nextMode,
		shuffleLabel as smartShuffleLabel,
		shuffleMode,
		smartEligible
	} from '$lib/smart/smartshuffle.svelte';
	import FindSongs from '$lib/collections/FindSongs.svelte';
	import FindInList from '$lib/collections/FindInList.svelte';
	import ViewSort from '$lib/collections/ViewSort.svelte';
	import EditDetailsModal from '$lib/collections/EditDetailsModal.svelte';
	import { matchSong, mosaicCovers, playlistAuthor, songsMeta } from '$lib/collections/format';
	import { loadView, saveView } from '$lib/collections/view';
	import { madeForName, ownerName as yourName } from '$lib/localuser.svelte'; // stream: parity3
	import Logo from '$lib/kit/Logo.svelte'; // stream: parity3
	// ── lane magic-d3 ── Liked Songs genre/mood chips (#7) and Enhance (#13).
	import { FilterChips } from '$lib/kit';
	import { filterByChip, keepChip, likedTags, loadLikedTags } from '$lib/smart/tags.svelte';
	import EnhanceButton from '$lib/smart/EnhanceButton.svelte';
	import {
		ENHANCE_EVERY,
		addEnhanced,
		enhanceEligible,
		enhanceSlots,
		enhancedRecs,
		interleave,
		loadEnhance,
		removeEnhanced
	} from '$lib/smart/enhance.svelte';

	const id = $derived(page.params.id ?? '');
	const isLiked = $derived(id === api.LIKED_ID);
	const isLocal = $derived(api.isLocalPlaylist(id));

	// `$state.raw`: Liked Songs runs to five figures; every write reassigns the object.
	let pl = $state.raw<PlaylistPage | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let loadingMore = $state(false);
	let moreError = $state(false);
	let skip = $state.raw<Record<string, SkipReason>>({});

	let query = $state('');
	let sort = $state<TrackSort>(null);
	let compact = $state(false);
	let selected = $state(new SvelteSet<number>());
	let tint = $state<Tint>();
	let sentinel = $state<HTMLElement>();
	let editOpen = $state(false);
	let findOpen = $state(false);
	let pendingShuffle = $state(false);
	/** Smart Shuffle picked before playing (smart2): applied once the queue starts. */
	let pendingSmart = $state(false);
	let recVersion = $state(0);
	const scroller =
		typeof document !== 'undefined'
			? document.querySelector<HTMLElement>('[data-main-scroll]')
			: null;

	const own = $derived(!isLiked && (isLocal || !!pl?.owned));
	const title = $derived(isLiked ? 'Liked Songs' : (pl?.title ?? ''));

	// ── Rows ─────────────────────────────────────────────────────────────────────────────────
	const rows = $derived.by(() => {
		let items = pl?.items ?? [];
		// An unlike from a row's heart drops the row at once; the refetch below catches up.
		if (isLiked && lib.ready) items = items.filter((s) => lib.liked.has(s.video_id));
		if (!Object.keys(skip).length) return items;
		return items.map((s) => (skip[s.video_id] && !s.unavailable ? { ...s, unavailable: true } : s));
	});
	// lane magic-d3: a Liked Songs chip narrows the list first (and what Play plays).
	let chipLabel = $state<string | null>(null);
	const activeChip = $derived(
		isLiked && chipLabel ? likedTags.chips.find((c) => c.label === chipLabel) : undefined
	);
	const chipRows = $derived(filterByChip(rows, activeChip));
	const shown = $derived(query.trim() ? chipRows.filter((s) => matchSong(s, query)) : chipRows);

	// ── Header ───────────────────────────────────────────────────────────────────────────────
	const covers = $derived(pl?.cover ? [] : mosaicCovers(pl?.items ?? []));
	const headerImage = $derived(
		isLiked
			? null
			: thumb(
					pl?.cover ??
						(covers.length ? covers[0] : isLocal ? pl?.items[0]?.thumbnail : (pl?.thumbnail ?? pl?.items[0]?.thumbnail)),
					464
				)
	);
	const useMosaic = $derived(!isLiked && !pl?.cover && covers.length === 4 && (isLocal || !pl?.thumbnail));
	// Spotify: "Public Playlist" / "Private Playlist". Someone else's YouTube playlist is public by
	// definition; local playlists (this Mac only) and Liked Songs stay "Playlist".
	const typeLabel = $derived(
		api.isMadeForYou(id) ? 'Public Playlist' :
		pl?.privacy === 'PUBLIC' || (!own && !isLiked && !isLocal && pl?.privacy !== 'PRIVATE')
			? 'Public Playlist'
			: pl?.privacy === 'PRIVATE' && !isLocal
				? 'Private Playlist'
				: 'Playlist'
	);
	// ── stream: parity3 ── Made for you: Spotify's full-bleed hero (the mix's artist photo for a
	// Your Mix, the playlist artwork otherwise) and "[mark] Made for <name>".
	const mfy = $derived(api.isMadeForYou(id));
	const mixArtist = $derived.by(() => {
		if (!id.startsWith('MFY_DAILY_')) return null;
		const n = new Map<string, number>();
		for (const s of pl?.items ?? []) if (s.artist_id) n.set(s.artist_id, (n.get(s.artist_id) ?? 0) + 1);
		return [...n].sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
	});
	let artistPhoto = $state<{ id: string; url: string | null } | null>(null);
	// ── stream: coverfix ── a cover that fails to load (a Made for you cover redrawn under a page
	// cached before it) never shows as a broken image: ask the backend once for the current page,
	// and meanwhile fall back to the first track's artwork, then to no image.
	let failedCovers = $state<string[]>([]);
	let reloadedFor = '';
	const headerSrc = $derived.by(() => {
		for (const src of [headerImage, thumb(pl?.items[0]?.thumbnail, 464)])
			if (src && !failedCovers.includes(src)) return src;
		return null;
	});
	function headerFailed() {
		if (!headerSrc) return;
		failedCovers = [...failedCovers, headerSrc];
		if (mfy && reloadedFor !== id) {
			reloadedFor = id;
			void load(id, true);
		}
	}
	$effect(() => {
		const aid = mixArtist;
		if (!aid || artistPhoto?.id === aid) return;
		api.getArtist(aid).then(
			(a) => {
				if (mixArtist === aid) artistPhoto = { id: aid, url: a.thumbnail ?? null };
			},
			() => {}
		);
	});
	const heroImage = $derived(
		mfy ? ((mixArtist && artistPhoto?.id === mixArtist ? artistPhoto.url : null) ?? headerSrc) : null
	);
	// ── end stream: parity3 ──
	const ownerName = $derived(
		mfy ? `Made for ${madeForName()}` :
		isLiked || own ? yourName() : (playlistAuthor(pl?.subtitle) ?? 'YouTube Music')
	);
	const remoteCount = $derived.by(() => {
		const m = /([\d,.]+)\s*(songs?|tracks?)/i.exec(pl?.subtitle ?? '');
		return m ? parseInt(m[1].replace(/[,.]/g, ''), 10) : 0;
	});
	const details = $derived(
		pl?.continuation
			? remoteCount
				? `${remoteCount.toLocaleString('en-US')} songs`
				: ''
			: songsMeta(rows, rows.length, true)
	);

	const item = $derived<BrowseItem>({
		kind: 'playlist',
		id,
		title,
		subtitle: isLiked ? `Playlist • ${rows.length} songs` : `Playlist • ${ownerName}`,
		thumbnail: headerImage ?? undefined
	});
	const ctx = $derived({
		id,
		title,
		kind: 'playlist' as const,
		subtitle: item.subtitle,
		thumbnail: item.thumbnail
	});

	// ── stream: downloads ── what the download toggle covers (Rust reads and syncs the list).
	const downloadTarget = $derived<api.DownloadCollection | undefined>(
		!id || id === api.ON_REPEAT_ID
			? undefined
			: {
					id,
					kind: isLiked ? 'liked' : 'playlist',
					title,
					subtitle: item.subtitle,
					thumbnail: isLiked ? null : (pl?.cover ?? pl?.thumbnail ?? pl?.items[0]?.thumbnail ?? null)
				}
	);

	// ── Loading ──────────────────────────────────────────────────────────────────────────────
	async function load(pid: string, silent = false) {
		if (!silent) {
			loading = true;
			error = null;
			pl = null;
			skip = {};
			moreError = false;
		}
		try {
			const fresh = await api.getPlaylist(pid);
			if (pid !== id) return;
			pl = fresh;
			error = null;
			checkSkips(pid, fresh.items);
		} catch (e) {
			if (pid !== id) return;
			if (!silent) error = String(e);
		} finally {
			if (pid === id) loading = false;
		}
	}

	async function checkSkips(pid: string, items: SongItem[]) {
		if (!items.length) return;
		try {
			const r = await api.playbackSkipReasons(items);
			if (pid === id) skip = { ...skip, ...r };
		} catch {
			/* older backend: nothing greyed */
		}
	}

	let inflight: Promise<void> | null = null;
	function loadMore(): Promise<void> {
		inflight ??= fetchPage().finally(() => (inflight = null));
		return inflight;
	}
	async function fetchPage() {
		const token = pl?.continuation;
		if (!token || !pl) return;
		const pid = id;
		loadingMore = true;
		moreError = false;
		try {
			const more = await api.getPlaylistMore(token);
			if (pid !== id || pl?.continuation !== token) return;
			pl = {
				...pl,
				items: [...pl.items, ...more.items],
				continuation: more.items.length ? more.continuation : undefined
			};
			checkSkips(pid, more.items);
		} catch {
			moreError = true;
		} finally {
			loadingMore = false;
		}
	}
	async function loadAll() {
		while (pl?.continuation && !moreError) {
			const t = pl.continuation;
			await loadMore();
			if (pl?.continuation === t) break;
		}
	}

	$effect(() => {
		const pid = id;
		if (!pid) return;
		untrack(() => {
			const v = loadView(pid, pid === api.LIKED_ID);
			sort = v.sort;
			compact = v.compact;
			query = '';
			findOpen = false;
			editOpen = false;
			pendingShuffle = false;
			pendingSmart = false;
			chipLabel = null;
			selected.clear();
			load(pid);
			if (enhanceEligible(pid)) void loadEnhance(pid);
		});
	});

	$effect(() => saveView(id, sort, compact));

	// lane magic-d3: Liked Songs' chips follow the likes (a new like gets tagged in the background).
	$effect(() => {
		if (!isLiked) return;
		void lib.likedCount;
		untrack(() => void loadLikedTags());
	});
	// Liked Songs started from anywhere else (the sidebar, a shortcut) plays all of it.
	$effect(() => {
		if (actions.playback.queue.sourceId !== api.LIKED_ID) untrack(() => (likedTags.playing = null));
	});
	$effect(() => {
		const keep = keepChip(chipLabel, likedTags.chips);
		if (likedTags.loaded && keep !== chipLabel) untrack(() => (chipLabel = keep));
	});

	// Own playlists and Liked Songs live in the local library: follow its changes (adds from a menu
	// anywhere, Undo of a removal, a rename from the sidebar) with a silent refetch.
	const libKey = $derived.by(() => {
		if (isLiked) return `liked:${lib.likedCount}`;
		if (isLocal) {
			const p = lib.playlist(id);
			return p ? `${p.updatedAt}:${p.count}:${p.name}:${p.cover ?? ''}` : 'gone';
		}
		return '';
	});
	let seenKey = '';
	$effect(() => {
		const k = libKey;
		const pid = id;
		untrack(() => {
			const prev = seenKey;
			seenKey = `${pid}|${k}`;
			if (!k || !prev.startsWith(`${pid}|`) || prev === seenKey || loading) return;
			if (k === 'gone') {
				// Deleted (from this page's menu or the sidebar): leave, like Spotify.
				if (lib.ready) goto('/');
				return;
			}
			load(pid, true);
		});
	});

	// A sort or a filter has to cover the whole list, not the pages scrolled so far.
	$effect(() => {
		if ((sort || query.trim()) && pl?.continuation && !moreError) untrack(loadAll);
	});
	// The selection holds indices into `shown`; a new filter or order makes them meaningless.
	$effect(() => {
		void query;
		void sort;
		void chipLabel;
		untrack(() => selected.clear());
	});

	// Infinite scroll for YouTube playlists.
	function moreSentinel(node: HTMLElement) {
		const io = new IntersectionObserver(([e]) => e.isIntersecting && loadMore(), {
			root: scroller,
			rootMargin: '800px 0px'
		});
		io.observe(node);
		return { destroy: () => io.disconnect() };
	}

	// `?edit=1` (actions.editPlaylistDetails, sidebar menu) opens Edit details.
	$effect(() => {
		if (page.url.searchParams.get('edit') !== '1' || !pl || !own) return;
		untrack(() => {
			editOpen = true;
			const u = new URL(page.url);
			u.searchParams.delete('edit');
			goto(u.pathname + u.search, { replaceState: true, noScroll: true, keepFocus: true });
		});
	});

	// ── Playback ─────────────────────────────────────────────────────────────────────────────
	// Liked Songs under a chip is its own thing to play: Play starts the filtered set, not pause.
	const isThis = $derived(
		!!id && actions.playback.queue.sourceId === id && (!isLiked || likedTags.playing === chipLabel)
	);
	const playing = $derived(isThis && !actions.playback.paused);
	const shuffleOn = $derived(isThis ? !!actions.playback.queue.shuffle : pendingShuffle);
	const sMode = $derived(
		isThis ? shuffleMode(shuffleOn, id) : pendingSmart ? 'smart' : pendingShuffle ? 'shuffle' : 'off'
	);

	// stream: wave2. Smart Shuffle's suggestions sit inside the track list, one after every
	// SUGGESTION_EVERY songs, the way Spotify shows them (not in a block above it). They're the
	// ones mixed into this playlist's queue; the queue panel shows them in play order.
	const SUGGESTION_EVERY = 3;
	const suggestions = $derived(
		sMode === 'smart' && isThis && !query.trim()
			? actions.playback.queue.items.filter((s) => smartShuffle.recIds.includes(s.video_id))
			: []
	);
	// lane magic-d3: Enhance's suggestions, one after every 2 songs, while no filter narrows the
	// list (Smart Shuffle's own suggestions win while it's on).
	const enhancedList = $derived(
		enhanceEligible(id) && !query.trim() && !activeChip && !suggestions.length ? enhancedRecs(id) : []
	);
	const enhanceShown = $derived(enhancedList.slice(0, enhanceSlots(shown.length, enhancedList.length)));

	function orderedRows(): SongItem[] {
		const base = chipRows;
		const order = sortedOrder(base, sort);
		const list = order.map((i) => base[i]);
		return enhancedList.length ? interleave(list, enhancedList, ENHANCE_EVERY) : list;
	}

	function play() {
		if (isThis) {
			api.togglePause();
			return;
		}
		const list = orderedRows();
		const playable = list.map((s, i) => [s, i] as const).filter(([s]) => !s.unavailable);
		if (!playable.length) return;
		const start = shuffleOn ? playable[Math.floor(Math.random() * playable.length)][1] : playable[0][1];
		if (isLiked) likedTags.playing = chipLabel;
		const more = sort || activeChip || enhancedList.length ? undefined : pl?.continuation;
		const started = actions.playTracks(list, start, ctx, shuffleOn || undefined, more);
		if (pendingSmart) void Promise.resolve(started).then(() => api.smartShuffleSet(true)).catch(() => {});
	}

	function toggleShuffle() {
		if (isThis) {
			void cycleShuffle(!!actions.playback.queue.shuffle, id);
			return;
		}
		const next = nextMode(sMode, smartEligible(id));
		pendingShuffle = next !== 'off';
		pendingSmart = next === 'smart';
	}

	// ── Edits ────────────────────────────────────────────────────────────────────────────────
	async function addSong(song: SongItem): Promise<boolean> {
		// Adding from the empty state keeps the search open, as Spotify does.
		if (!rows.length) findOpen = true;
		await actions.addToPlaylist({ kind: 'playlist', id, title }, [$state.snapshot(song) as SongItem]);
		// Local playlists follow `lib`; a YouTube playlist needs a re-read for its row ids.
		if (!isLocal) setTimeout(() => load(id, true), 800);
		return true;
	}

	function onRemoved(songs: SongItem[]) {
		if (!pl) return;
		const gone = new Set(songs.map((s) => s.set_video_id).filter(Boolean));
		pl = { ...pl, items: pl.items.filter((s) => !gone.has(s.set_video_id)) };
	}

	async function reorder(from: number[], to: number) {
		if (!pl || !own || query.trim() || sort) return;
		const prev = pl;
		const items = pl.items;
		const moving = from.map((i) => items[i]).filter(Boolean);
		const movingSet = new Set(moving);
		let before: SongItem | undefined;
		for (let i = to; i < items.length; i++)
			if (!movingSet.has(items[i])) {
				before = items[i];
				break;
			}
		const rest = items.filter((s) => !movingSet.has(s));
		const at = before ? rest.indexOf(before) : rest.length;
		rest.splice(at, 0, ...moving);
		pl = { ...pl, items: rest };
		selected.clear();
		try {
			if (isLocal) {
				await lib.moveInPlaylist(
					id,
					moving.map((s) => Number(s.set_video_id)),
					before ? Number(before.set_video_id) : undefined
				);
			} else {
				for (const s of moving)
					await api.moveInPlaylist(id, s.set_video_id!, before?.set_video_id ?? null);
			}
		} catch (e) {
			pl = prev;
			toast.error(String(e));
		}
	}

	// ── Drops from outside (lane magic-d2, gap 3) ────────────────────────────────────────────
	// Songs, a selection, or an album/playlist card dragged onto your own playlist's track list go
	// in at the accent line. Same rules as reorder: unsorted and unfiltered only.
	const canDropIn = $derived(own && !query.trim() && !sort);
	let emptyDropOver = $state(false);
	async function dropIn(e: DragEvent, to: number) {
		const d = readTrackDrop(e); // read now: the data is gone once the drop event returns
		if (!d || !pl || ('item' in d && d.item.id === id)) return;
		let songs: SongItem[];
		try {
			songs = (await resolveTrackDrop(d)).songs;
		} catch (err) {
			toast.error(String(err));
			return;
		}
		if (!songs.length) return;
		const target = { kind: 'playlist' as const, id, title };
		if (!isLocal) {
			// A YouTube playlist only appends: add, then move the new rows in front of the row the
			// line was above.
			const before = pl.items[to]?.set_video_id ?? null;
			await actions.addToPlaylist(target, songs);
			if (before) {
				try {
					const fresh = await api.getPlaylist(id);
					const want = new Set(songs.map((s) => s.video_id));
					const added = fresh.items.filter((s) => want.has(s.video_id) && s.set_video_id).slice(-songs.length);
					for (const s of added) await api.moveInPlaylist(id, s.set_video_id!, before);
				} catch {
					/* added at the end; the reload shows where */
				}
			}
			setTimeout(() => load(id, true), 300);
			return;
		}
		try {
			const r = await lib.addToPlaylist(id, songs, { position: to });
			let undo = r.undo;
			if (r.duplicates.length) {
				// Spotify's "Already added" (same words as Add to playlist ▸).
				const anyway = await confirmDialog({
					title: 'Already added',
					body:
						r.duplicates.length === 1 && songs.length === 1
							? `This is already in your ${title} playlist.`
							: `Some of these are already in your ${title} playlist.`,
					confirmLabel: 'Add anyway',
					cancelLabel: r.added.length ? 'Skip duplicates' : "Don't add"
				});
				if (anyway) {
					const dupes = songs.filter((s) => r.duplicates.includes(s.video_id));
					const r2 = await lib.addToPlaylist(id, dupes, { allowDuplicates: true, position: to + r.added.length });
					undo = async () => {
						await r2.undo();
						await r.undo();
					};
				} else if (!r.added.length) return;
			}
			toastUndo(`Added to ${title}`, undo);
		} catch (err) {
			toast.error(String(err));
		}
	}

	function applyEdit(patch: { title?: string; description?: string; privacy?: string; cover?: string | null }) {
		if (!pl) return;
		pl = {
			...pl,
			...(patch.title !== undefined && { title: patch.title }),
			...(patch.description !== undefined && { description: patch.description }),
			...(patch.privacy !== undefined && { privacy: patch.privacy }),
			...(patch.cover !== undefined && { cover: patch.cover ?? undefined })
		};
		if (!isLocal) actions.loadLibrary();
	}

	const openEdit = () => (editOpen = true);

	function openFind() {
		findOpen = true;
		requestAnimationFrame(() =>
			document.getElementById('find-songs')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
		);
	}
</script>

{#snippet cover()}
	{#if isLiked}
		<LikedCover />
	{:else if useMosaic}
		<Mosaic {covers} />
	{:else if headerSrc}
		<img src={headerSrc} alt="" class="size-full object-cover" onerror={headerFailed} />
	{/if}
{/snippet}

{#snippet emptyCover()}
	{#if useMosaic}<Mosaic {covers} />{:else if headerSrc}<img src={headerSrc} alt="" class="size-full object-cover" onerror={headerFailed} />{/if}
{/snippet}

<svelte:head><title>{title || 'Playlist'} | Ztunes</title></svelte:head>

{#if loading && !pl}
	<div class="relative">
		<Skeleton variant="header" />
		<div class="px-[var(--content-spacing)] pt-6">
			<div class="mb-6 flex items-center gap-6">
				<div class="size-14 rounded-full bg-bg-menu"></div>
				<Skeleton width="120px" height={24} />
			</div>
			<Skeleton variant="row" count={8} />
		</div>
	</div>
{:else if error}
	<div class="grid min-h-[60vh] place-items-center px-[var(--content-spacing)]">
		<ErrorState
			title={isLocal ? "Couldn't find this playlist" : "Couldn't load this playlist"}
			message={isLocal ? 'It may have been deleted.' : 'Check your connection and try again.'}
			onRetry={isLocal ? undefined : () => load(id)}
			offline={/network|offline|connect|dns|timed? ?out/i.test(error)}
		/>
	</div>
{:else if pl}
	<StickyHeader {title} tint={tint?.color} {sentinel} {scroller} {playing} onPlay={rows.length ? play : undefined} />
	{#if mfy && heroImage}
		<PageHeader
			variant="hero"
			type={typeLabel}
			{title}
			image={heroImage}
			onImageError={(src) => src === headerSrc && headerFailed()}
			heroPosition={mixArtist ? '50% 20%' : '50% 0%'}
			bind:tintOut={tint}
			description={pl.description}
		>
			{#snippet meta()}
				<Logo size={24} class="mr-1 text-white" />
				<span class="text-white">Made for <span class="font-bold">{madeForName()}</span></span>
				{#if details}<span class="mx-1" aria-hidden="true">•</span><span class="truncate">{details}</span>{/if}
			{/snippet}
			{#snippet footer()}
				<!-- leftovers: Spotify's "About recommendations" link under a Made for you hero. -->
				<button
					type="button"
					class="text-sm text-white/70 hover:text-white hover:underline"
					onclick={openAboutRecommendations}>About recommendations</button
				>
			{/snippet}
		</PageHeader>
	{:else}
		<PageHeader
			type={typeLabel}
			{title}
			image={headerImage}
			imageSnippet={isLiked || useMosaic || headerImage ? cover : undefined}
			tint={isLiked ? LIKED_TINT : undefined}
			bind:tintOut={tint}
			description={pl.description}
			owner={{
				name: ownerName,
				image: own || isLiked ? (auth.account?.thumbnail ?? undefined) : undefined,
				noAvatar: isLiked && !auth.account?.thumbnail
			}}
			{details}
			onTitleClick={own ? openEdit : undefined}
			onImageClick={own ? openEdit : undefined}
		/>
	{/if}
	<ActionBar
		bind:sentinel
		tint={tint?.rgb}
		{playing}
		playLabel={playing ? `Pause ${title}` : `Play ${title}`}
		onPlay={rows.length ? play : undefined}
		shuffle={rows.length ? shuffleOn : undefined}
		onShuffle={toggleShuffle}
		smartShuffle={sMode === 'smart'}
		shuffleLabel={smartShuffleLabel(sMode, smartEligible(id))}
		saved={!own && !isLiked ? actions.isInLibrary(item) : undefined}
		onSave={() => actions.toggleInLibrary(item)}
		download={rows.length ? downloadTarget : undefined}
		onMore={isLiked ? undefined : (e) => openItemMenu(e, item)}
		moreLabel={`More options for ${title}`}
	>
		{#snippet extra()}
			{#if enhanceEligible(id) && rows.length}<EnhanceButton playlistId={id} len={rows.length} />{/if}
		{/snippet}
		{#snippet right()}
			{#if rows.length}
				<div class="flex items-center gap-2">
					{#if !mfy && !isLiked}<FindInList bind:value={query} placeholder="Search in playlist" />{/if}
					<ViewSort bind:sort bind:compact custom={!isLiked} />
				</div>
			{/if}
		{/snippet}

		<div class="px-[var(--content-spacing)] pb-10">
			{#if own && rows.length}
				<div class="mt-[6px] mb-1.5 flex items-center gap-2">
					<Pill variant="tinted" icon={PlusIcon} onclick={openFind} class="!text-text-subdued hover:!text-white">Add</Pill>
					<Pill variant="tinted" icon={PencilSimpleIcon} onclick={openEdit} class="!text-text-subdued hover:!text-white">Name &amp; details</Pill>
				</div>
			{/if}

			{#if isLiked && likedTags.chips.length && rows.length}
				<FilterChips
					class="mt-[6px] mb-3"
					options={likedTags.chips.map((c) => ({ id: c.label, label: c.label }))}
					bind:value={chipLabel}
					clearLabel="Show all liked songs"
				/>
			{/if}

			{#if rows.length}
				{#snippet enhancedRow(k: number, layout: { columns: TrackColumn[]; template: string })}
					{#if enhanceShown[k]}
						<SuggestionRow
							song={enhanceShown[k]}
							{layout}
							onAdd={(s) => addEnhanced(id, title, s)}
							onRemove={(s) => removeEnhanced(id, s)}
						/>
					{/if}
				{/snippet}
				{#snippet suggestion(k: number, layout: { columns: TrackColumn[]; template: string })}
					{#if suggestions[k]}
						<SuggestionRow song={suggestions[k]} {layout} onAdd={addSuggestion} onRemove={removeSuggestion} />
					{/if}
				{/snippet}
				<TrackTable
					tracks={shown}
					variant="playlist"
					context={ctx}
					menuContext={{ playlistId: isLiked ? undefined : id, own, onRemove: onRemoved }}
					stickyTop={64}
					bleed="var(--content-spacing)"
					{scroller}
					{compact}
					likedOnHover={isLiked}
					bind:selected
					bind:sort
					onReorder={own && !query.trim() ? reorder : undefined}
					acceptDrop={canDropIn ? isTracksDrag : undefined}
					onDropIn={canDropIn ? dropIn : undefined}
					interleave={suggestions.length
						? { every: SUGGESTION_EVERY, count: suggestions.length, row: suggestion }
						: enhanceShown.length
							? { every: ENHANCE_EVERY, count: enhanceShown.length, row: enhancedRow }
							: undefined}
				>
					{#snippet empty()}
						<div class="py-10 text-center">
							<p class="text-base font-bold text-white">Couldn't find "{query.trim()}"</p>
							<p class="mt-2 text-sm text-text-subdued">Try searching again using a different spelling or keyword.</p>
						</div>
					{/snippet}
				</TrackTable>
				{#if pl.continuation}
					<div use:moreSentinel class="py-4">
						{#if moreError}
							<div class="flex justify-center">
								<button type="button" class="btn-outline" onclick={() => loadMore()}>Try again</button>
							</div>
						{:else if loadingMore}
							<Skeleton variant="row" count={3} />
						{/if}
					</div>
				{/if}
			{:else if isLiked}
				<EmptyState
					icon={HeartIcon}
					title="Songs you like will appear here"
					body="Save songs by tapping the heart icon."
					actionLabel="Find songs"
					onAction={() => goto('/search')}
					class="py-16"
				/>
			{:else if !own}
				<EmptyState title="This playlist is empty" body="There's nothing here yet." class="py-16" />
			{/if}

			{#if own}
				{#if !rows.length}
					<!-- lane magic-d2: an empty playlist takes a drop anywhere on its "find" area. -->
					<div
						id="find-songs"
						role="region"
						aria-label="Add songs"
						class="rounded-lg {emptyDropOver ? 'ring-2 ring-accent' : ''}"
						ondragover={(e) => {
							if (!canDropIn || !isTracksDrag(e)) return;
							e.preventDefault();
							emptyDropOver = true;
						}}
						ondragleave={() => (emptyDropOver = false)}
						ondrop={(e) => {
							if (!canDropIn || !isTracksDrag(e)) return;
							e.preventDefault();
							emptyDropOver = false;
							void dropIn(e, 0);
						}}
					><FindSongs onAdd={addSong} autofocus /></div>
					<Recommended playlistId={id} onAdd={addSong} version={recVersion} />
				{:else}
					{#if !findOpen}
						<div class="mt-6 flex justify-end">
							<button type="button" class="text-sm font-bold text-white hover:scale-[1.04]" onclick={openFind}>
								Find more
							</button>
						</div>
					{:else}
						<div id="find-songs"><FindSongs onAdd={addSong} onClose={() => (findOpen = false)} autofocus /></div>
					{/if}
					<Recommended playlistId={id} onAdd={addSong} version={recVersion} />
				{/if}
			{/if}
		</div>
	</ActionBar>

	{#if own}
		<EditDetailsModal
			bind:open={editOpen}
			{id}
			{title}
			description={pl.description ?? ''}
			privacy={isLocal ? undefined : pl.privacy}
			cover={pl.cover}
			fallback={emptyCover}
			onSaved={applyEdit}
		/>
	{/if}
{/if}
