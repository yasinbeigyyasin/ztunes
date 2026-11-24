<script lang="ts">
	import { displayRuns } from '$lib/artistruns';
	/**
	 * Album page (spotify-spec/screens/album.md, ref/album-active-track.jpg). Also serves local
	 * albums/artists (`LOCALALBUM:` / `LOCALARTIST:`), which have no YouTube item behind them.
	 */
	import { untrack } from 'svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { SvelteSet } from 'svelte/reactivity';
	import * as api from '$lib/api';
	import type { AlbumPage, BrowseItem, SkipReason } from '$lib/api';
	import {
		ActionBar,
		Card,
		ErrorState,
		PageHeader,
		Shelf,
		Skeleton,
		StickyHeader,
		TrackTable,
		actions,
		openItemMenu,
		type Tint
	} from '$lib/kit';
	import { playItem } from '$lib/browse';
	import { getCached, putCached } from '$lib/pagecache';
	import { thumb } from '$lib/thumb';
	import FindInList from '$lib/collections/FindInList.svelte';
	import ViewSort from '$lib/collections/ViewSort.svelte';
	import { albumKind, matchSong, songsMeta } from '$lib/collections/format';
	import { loadView, saveView } from '$lib/collections/view';

	const id = $derived(page.params.id ?? '');
	const isLocal = $derived(api.isLocalId(id));

	let album = $state.raw<AlbumPage | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let skip = $state.raw<Record<string, SkipReason>>({});
	let more = $state.raw<BrowseItem[]>([]);
	let query = $state('');
	let compact = $state(false);
	let selected = $state(new SvelteSet<number>());
	let tint = $state<Tint>();
	let sentinel = $state<HTMLElement>();
	let pendingShuffle = $state(false);
	const scroller =
		typeof document !== 'undefined' ? document.querySelector<HTMLElement>('[data-main-scroll]') : null;

	async function load(aid: string) {
		const key = `album:${aid}`;
		const hit = getCached<AlbumPage>(key);
		album = hit ?? null;
		loading = !hit;
		error = null;
		skip = {};
		more = [];
		try {
			const fresh = await api.getAlbum(aid);
			if (aid !== id) return;
			album = fresh;
			putCached(key, fresh);
			checkSkips(aid, fresh);
			loadMoreBy(aid, fresh);
		} catch (e) {
			if (aid === id && !hit) error = String(e);
		} finally {
			if (aid === id) loading = false;
		}
	}

	async function checkSkips(aid: string, a: AlbumPage) {
		try {
			const r = await api.playbackSkipReasons(a.items);
			if (aid === id) skip = r;
		} catch {
			/* nothing greyed */
		}
	}

	// "More by <Artist>": the artist's own Albums + Singles shelves, minus this release.
	async function loadMoreBy(aid: string, a: AlbumPage) {
		if (!a.artistId || api.isLocalId(a.artistId)) return;
		try {
			const artist = await api.getArtist(a.artistId);
			if (aid !== id) return;
			const picks = artist.sections
				.filter((s) => /^(albums|singles)/i.test(s.title))
				.flatMap((s) => s.items)
				.filter((i) => i.kind === 'album' && i.id !== aid && i.title !== a.title);
			const seen = new Set<string>();
			more = picks.filter((i) => !seen.has(i.id) && seen.add(i.id));
		} catch {
			/* shelf just doesn't show */
		}
	}

	$effect(() => {
		const aid = id;
		if (!aid) return;
		untrack(() => {
			compact = loadView(aid).compact;
			query = '';
			pendingShuffle = false;
			selected.clear();
			load(aid);
		});
	});
	$effect(() => saveView(id, null, compact));
	$effect(() => {
		void query;
		untrack(() => selected.clear());
	});

	const kind = $derived(albumKind(album?.subtitle));
	const rows = $derived.by(() => {
		const items = album?.items ?? [];
		if (!Object.keys(skip).length) return items;
		return items.map((s) => (skip[s.video_id] && !s.unavailable ? { ...s, unavailable: true } : s));
	});
	const shown = $derived(query.trim() ? rows.filter((s) => matchSong(s, query)) : rows);
	const runs = $derived(displayRuns(album?.artistRuns, album?.artist, album?.artistId));
	const image = $derived(thumb(album?.thumbnail, 464));
	const isArtistPage = $derived(id.startsWith(api.LOCAL_ARTIST_PREFIX));

	const item = $derived<BrowseItem>({
		kind: isArtistPage ? 'artist' : 'album',
		id,
		title: album?.title ?? 'Album',
		subtitle: album?.artist,
		thumbnail: album?.thumbnail,
		explicit: album?.explicit
	});
	const ctx = $derived({
		id,
		title: album?.title ?? '',
		kind: item.kind,
		subtitle: album?.artist,
		thumbnail: album?.thumbnail,
		sourceId: album?.playlistId ?? id
	});

	// ── Playback ─────────────────────────────────────────────────────────────────────────────
	const isThis = $derived(
		!!album &&
			(actions.playback.queue.sourceId === id ||
				(!!album.playlistId && actions.playback.queue.sourceId === album.playlistId))
	);
	const playing = $derived(isThis && !actions.playback.paused);
	const shuffleOn = $derived(isThis ? !!actions.playback.queue.shuffle : pendingShuffle);

	function play() {
		if (isThis) return void api.togglePause();
		const playable = rows.map((s, i) => [s, i] as const).filter(([s]) => !s.unavailable);
		if (!playable.length) return;
		const start = shuffleOn ? playable[Math.floor(Math.random() * playable.length)][1] : playable[0][1];
		actions.playTracks(rows, start, ctx, shuffleOn || undefined, album?.continuation);
	}

	function toggleShuffle() {
		if (isThis) api.toggleShuffle();
		else pendingShuffle = !pendingShuffle;
	}

	const year = (b: BrowseItem) => albumKind(b.subtitle).year || b.subtitle || '';
</script>

{#snippet meta()}
	{#if album?.artistThumbnail}
		<img src={thumb(album.artistThumbnail, 48)} alt="" class="mr-1 size-6 rounded-full object-cover" />
	{/if}
	{#each runs as r, i (i)}
		{#if i > 0}<span class="font-bold text-white">{', '}</span>{/if}
		{#if r.id && !api.isLocalId(r.id)}
			<a href={actions.artistHref(r.id)} class="font-bold text-white hover:underline">{r.text}</a>
		{:else}
			<span class="font-bold text-white">{r.text}</span>
		{/if}
	{/each}
	{#if kind.year}<span class="mx-1" aria-hidden="true">•</span><span>{kind.year}</span>{/if}
	{#if rows.length}<span class="mx-1" aria-hidden="true">•</span><span>{songsMeta(rows)}</span>{/if}
{/snippet}

<svelte:head><title>{album?.title ?? 'Album'} | Ztunes</title></svelte:head>

{#if loading && !album}
	<Skeleton variant="header" />
	<div class="px-[var(--content-spacing)] pt-6">
		<div class="mb-6 flex items-center gap-6">
			<div class="size-14 rounded-full bg-bg-menu"></div>
			<Skeleton width="120px" height={24} />
		</div>
		<Skeleton variant="row" count={8} />
	</div>
{:else if error}
	<div class="grid min-h-[60vh] place-items-center px-[var(--content-spacing)]">
		<ErrorState
			title="Couldn't load this album"
			message="Check your connection and try again."
			onRetry={() => load(id)}
			offline={/network|offline|connect|dns|timed? ?out/i.test(error)}
		/>
	</div>
{:else if album}
	<StickyHeader title={album.title ?? ''} tint={tint?.color} {sentinel} {scroller} {playing} onPlay={play} />
	<PageHeader type={isArtistPage ? 'Artist' : kind.type} title={album.title ?? ''} {image} bind:tintOut={tint} {meta} />
	<ActionBar
		bind:sentinel
		tint={tint?.rgb}
		{playing}
		playLabel={playing ? `Pause ${album.title}` : `Play ${album.title}`}
		onPlay={play}
		shuffle={rows.length ? shuffleOn : undefined}
		onShuffle={toggleShuffle}
		saved={isLocal ? undefined : actions.isInLibrary(item) || album.inLibrary}
		onSave={() => actions.toggleInLibrary(item)}
		download={isLocal || isArtistPage || !rows.length
			? undefined
			: { id, kind: 'album', title: album.title ?? '', subtitle: album.artist ?? null, thumbnail: album.thumbnail ?? null }}
		onMore={(e) => openItemMenu(e, item)}
		moreLabel={`More options for ${album.title}`}
	>
		{#snippet right()}
			<div class="flex items-center gap-2">
				<FindInList bind:value={query} placeholder="Search in album" button={false} />
				<ViewSort bind:compact sortable={false} />
			</div>
		{/snippet}

		<div class="px-[var(--content-spacing)] pb-10">
			<TrackTable
				tracks={shown}
				variant="album"
				context={ctx}
				menuContext={{ albumId: id, artistId: album.artistId }}
				stickyTop={64}
				bleed="var(--content-spacing)"
				{scroller}
				{compact}
				bind:selected
			>
				{#snippet empty()}
					<div class="py-10 text-center">
						{#if query.trim()}
							<p class="text-base font-bold text-white">Couldn't find "{query.trim()}"</p>
							<p class="mt-2 text-sm text-text-subdued">Try searching again using a different spelling or keyword.</p>
						{:else}
							<p class="text-base text-text-subdued">This album has no songs available.</p>
						{/if}
					</div>
				{/snippet}
			</TrackTable>

			{#if kind.year}
				<p class="mt-4 text-sm text-text-subdued">{kind.year}</p>
			{/if}

			{#if more.length && album.artistId}
				<div class="mt-12">
					<Shelf
						title={`More by ${album.artist ?? ''}`}
						href={actions.artistHref(album.artistId)}
						showAll
						showAllLabel="See discography"
						onShowAll={() => goto(`${actions.artistHref(album!.artistId!)}/discography`)}
						items={more}
						key={(i) => i.id}
					>
						{#snippet card(i)}
							<Card
								title={i.title}
								subtitle={year(i)}
								image={i.thumbnail}
								kind="album"
								href={actions.hrefFor(i)}
								onPlay={() => playItem(i)}
								oncontextmenu={(e) => openItemMenu(e, i)}
							/>
						{/snippet}
					</Shelf>
				</div>
			{/if}

			{#each album.sections?.filter((s) => /version|edition/i.test(s.title)) ?? [] as s (s.title)}
				<div class="mt-10">
					<Shelf title={s.title} items={s.items} key={(i) => i.id}>
						{#snippet card(i)}
							<Card
								title={i.title}
								subtitle={albumKind(i.subtitle).year || i.subtitle}
								image={i.thumbnail}
								kind={i.kind}
								href={actions.hrefFor(i)}
								onPlay={() => playItem(i)}
								oncontextmenu={(e) => openItemMenu(e, i)}
							/>
						{/snippet}
					</Shelf>
				</div>
			{/each}
		</div>
	</ActionBar>
{/if}
