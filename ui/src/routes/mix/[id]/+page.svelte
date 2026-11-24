<script lang="ts">
	/**
	 * A Your Mix (`smart_mix`, smart.md) shown with the kit's collection layout: tinted header,
	 * action bar (play / shuffle / more), track table. Playing records a `daily_mix` context
	 * (polish.md) so it lands in Recents and Home's shortcuts.
	 * URL: /mix/<id>?title=…&subtitle=…&thumb=…
	 */
	import { untrack } from 'svelte';
	import { page } from '$app/state';
	import type { SongItem } from '$lib/api';
	import * as api from '$lib/api';
	import { parseClock } from '$lib/timecode';
	import {
		ActionBar,
		EmptyState,
		ErrorState,
		PageHeader,
		Skeleton,
		StickyHeader,
		TrackTable,
		openMenu,
		type Tint
	} from '$lib/kit';
	import { addToQueue, createPlaylist, playNext } from '$lib/kit/actions';
	import { isCurrent, isPlaying, playContext, toggle } from '$lib/discover/play.svelte';
	import { markSkips } from '$lib/discover/data';
	import { playback } from '$lib/player.svelte';
	import { getCached, putCached } from '$lib/pagecache';
	import QueueIcon from 'phosphor-svelte/lib/QueueIcon';
	import PlusIcon from 'phosphor-svelte/lib/PlusIcon';
	import ArrowClockwiseIcon from 'phosphor-svelte/lib/ArrowClockwiseIcon';

	const id = $derived(decodeURIComponent(page.params.id ?? ''));
	const title = $derived(page.url.searchParams.get('title') ?? 'Your Mix');
	const subtitle = $derived(page.url.searchParams.get('subtitle') ?? undefined);
	const image = $derived(page.url.searchParams.get('thumb') ?? undefined);

	let songs = $state<SongItem[] | null>(null);
	let error = $state(false);
	let tint = $state<Tint>();
	let sentinel = $state<HTMLElement>();
	let shuffle = $state(false);

	async function load(mixId: string, fresh = false) {
		const key = `mix:${mixId}`;
		songs = fresh ? null : getCached<SongItem[]>(key);
		error = false;
		if (songs) return;
		try {
			const s = await markSkips(await api.smartMix(mixId));
			if (mixId !== id) return;
			songs = s;
			putCached(key, s);
		} catch {
			if (mixId === id) error = true;
		}
	}
	$effect(() => {
		const mixId = id;
		if (mixId) untrack(() => load(mixId));
	});

	const ctx = $derived({ kind: 'daily_mix' as const, id, title, subtitle, thumbnail: image });
	const playing = $derived(isPlaying(id));
	function play(start: number | null = null, list = songs ?? []) {
		return playContext(id, ctx, list, { start, shuffle: start === null ? shuffle : false });
	}
	const onPlay = () => toggle(id, () => play());

	const totalSecs = $derived(
		(songs ?? []).reduce((n, s) => n + (s.duration ? (parseClock(s.duration) ?? 0) : 0), 0)
	);
	function fmtTotal(secs: number) {
		const h = Math.floor(secs / 3600);
		const m = Math.floor((secs % 3600) / 60);
		return h ? `about ${h} hr ${m} min` : `${m} min ${Math.floor(secs % 60)} sec`;
	}
	const details = $derived(
		songs ? `${songs.length} songs${totalSecs ? `, ${fmtTotal(totalSecs)}` : ''}` : undefined
	);

	function more(e: MouseEvent) {
		const list = songs ?? [];
		openMenu(e, [
			{ label: 'Add to queue', icon: QueueIcon, onSelect: () => addToQueue(list, title) },
			{ label: 'Play next', icon: QueueIcon, onSelect: () => playNext(list, title) },
			{ type: 'separator' },
			{ label: 'Save as playlist', icon: PlusIcon, onSelect: () => createPlaylist(list) },
			{ label: 'Refresh mix', icon: ArrowClockwiseIcon, onSelect: () => load(id, true) }
		]);
	}
</script>

<StickyHeader {title} tint={tint?.color} {playing} {onPlay} {sentinel} />
{#if error}
	<div class="pt-16"><ErrorState message="Try reloading the page." onRetry={() => load(id, true)} /></div>
{:else}
	<PageHeader type="Playlist" {title} {image} description={subtitle} owner={{ name: 'Ztunes' }} {details} bind:tintOut={tint} />
	<ActionBar
		{playing}
		{onPlay}
		playLabel={`Play ${title}`}
		{shuffle}
		onShuffle={() => (shuffle = !shuffle)}
		onMore={more}
		tint={tint?.rgb}
		bind:sentinel
	>
		{#if !songs}
			<Skeleton variant="row" count={10} />
		{:else if !songs.length}
			<EmptyState size="sm" title="This mix is empty right now" body="Play a few more songs and try again." />
		{:else}
			<TrackTable
				tracks={songs}
				variant="queue"
				context={{ id, title, kind: 'playlist' }}
				stickyTop={64}
				bleed="var(--content-spacing)"
				isPlaying={(s) => isCurrent(id) && playback.now?.videoId === s.video_id}
				onPlay={(list, pos) => play(pos, list)}
			/>
		{/if}
	</ActionBar>
{/if}
