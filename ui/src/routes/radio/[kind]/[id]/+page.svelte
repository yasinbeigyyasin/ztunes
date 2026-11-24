<script lang="ts">
	/**
	 * ── lane magic-d1 ── A radio as a playlist page (MAGIC-GAPS #1). Spotify's "Go to song radio"
	 * opens "<Song> Radio": a cover made from the seed's art, Play / Save / ···, and a track list
	 * you can browse while the current song keeps playing. Only Play (or a row) replaces the queue.
	 *
	 * URL: /radio/<song|artist|album|playlist>/<id>?name=<seed title>&thumb=<seed art>
	 * Data: `radio_tracks` (crates/core/src/radio_page.rs), the same radio `start_radio` plays.
	 */
	import { untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import type { SongItem } from '$lib/api';
	import { radioTracks, type RadioKind, type RadioPage } from '$lib/trackapi';
	import { parseClock } from '$lib/timecode';
	import { thumb } from '$lib/thumb';
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
	import { addToQueue, playNext, playlistHref, startRadio } from '$lib/kit/actions';
	import { toast, toastUndo } from '$lib/kit/toast';
	import { friendlyError } from '$lib/neterr';
	import { isCurrent, playContext, toggle } from '$lib/discover/play.svelte';
	import { lib } from '$lib/library.svelte';
	import { openPlayer, playback, radioPages } from '$lib/player.svelte';
	import { getCached, putCached } from '$lib/pagecache';
	import QueueIcon from 'phosphor-svelte/lib/QueueIcon';
	import ArrowBendDownRightIcon from 'phosphor-svelte/lib/ArrowBendDownRightIcon';
	import ArrowClockwiseIcon from 'phosphor-svelte/lib/ArrowClockwiseIcon';
	import MusicNotesPlusIcon from 'phosphor-svelte/lib/MusicNotesPlusIcon';

	const KINDS = ['song', 'artist', 'album', 'playlist'] as const;
	const kind = $derived(
		(KINDS as readonly string[]).includes(page.params.kind ?? '') ? (page.params.kind as RadioKind) : 'song'
	);
	const id = $derived(decodeURIComponent(page.params.id ?? ''));
	const nameParam = $derived(page.url.searchParams.get('name') ?? undefined);
	const thumbParam = $derived(page.url.searchParams.get('thumb') ?? undefined);

	let radio = $state<RadioPage | null>(null);
	let error = $state<string | null>(null);
	let tint = $state<Tint>();
	let sentinel = $state<HTMLElement>();
	let shuffle = $state(false);

	const cacheKey = (k: string, i: string) => `radio:${k}:${i}`;

	async function load(k: RadioKind, i: string, fresh = false) {
		radio = fresh ? null : getCached<RadioPage>(cacheKey(k, i));
		error = null;
		if (radio) return;
		try {
			const r = await radioTracks(k, i, nameParam);
			if (i !== id || k !== kind) return;
			radio = r;
			putCached(cacheKey(k, i), r);
		} catch (e) {
			if (i !== id || k !== kind) return;
			console.warn('[radio page]', e);
			error = friendlyError(e, "Couldn't load this radio");
		}
	}
	$effect(() => {
		const k = kind;
		const i = id;
		if (i) untrack(() => load(k, i));
	});

	const title = $derived(radio?.title ?? (nameParam ? `${nameParam.replace(/ Radio$/, '')} Radio` : 'Radio'));
	const art = $derived(radio?.thumbnail ?? thumbParam ?? radio?.items[0]?.thumbnail ?? undefined);
	const songs = $derived(radio?.items ?? []);
	const key = $derived(radio?.playlistId ?? `radio:${kind}:${id}`);
	const href = $derived(page.url.pathname + page.url.search);

	// The page's play state follows the queue it started (keyed on the YouTube radio id), or the
	// same radio started from a menu elsewhere (same "<seed> Radio" title).
	const current = $derived(isCurrent(key, title));
	const playing = $derived(current && !playback.paused);

	/** Play the radio from `start` (null: the top, or a shuffled opener). The current song's own
	 *  radio started from the top keeps that song playing and swaps what follows (start_radio's
	 *  splice); everything else plays exactly the list on screen. */
	async function play(start: number | null = null) {
		if (!radio || !songs.length) return;
		const seedPlaying = kind === 'song' && !!radio.seed && playback.now?.videoId === radio.seed.video_id;
		if (seedPlaying && (start === null || start === 0) && !shuffle) {
			radioPages[radio.playlistId] = { title, href };
			await startRadio('song', id, nameParam);
			return;
		}
		openPlayer();
		radioPages[radio.playlistId] = { title, href };
		try {
			await playContext(
				key,
				{
					kind: 'radio',
					id,
					title,
					subtitle: radio.description ?? undefined,
					thumbnail: art,
					params: kind === 'song' ? undefined : kind
				},
				$state.snapshot(songs) as SongItem[],
				{ start, sourceId: radio.playlistId, shuffle: start === null ? shuffle : false }
			);
		} catch (e) {
			toast.fail(e, "Couldn't start radio");
		}
	}
	const onPlay = () => toggle(key, () => play(), title);

	// ── Save: the radio as one of your playlists (Spotify's "Save to Your Library"). The playlist
	// made from this radio is remembered, so the button stays filled while it exists.
	const SAVED_KEY = 'spotless.radioSaves';
	function savedMap(): Record<string, string> {
		try {
			return JSON.parse(localStorage.getItem(SAVED_KEY) ?? '{}') ?? {};
		} catch {
			return {};
		}
	}
	function remember(radioKey: string, playlistId: string | null) {
		const m = savedMap();
		if (playlistId) m[radioKey] = playlistId;
		else delete m[radioKey];
		try {
			localStorage.setItem(SAVED_KEY, JSON.stringify(m));
		} catch {
			/* not essential */
		}
		savedTick++;
	}
	let savedTick = $state(0);
	const savedId = $derived.by(() => {
		savedTick;
		const pid = savedMap()[cacheKey(kind, id)];
		return pid && lib.playlist(pid) ? pid : null;
	});

	async function onSave() {
		const radioKey = cacheKey(kind, id);
		try {
			if (savedId) {
				const pid = savedId;
				const undo = await lib.deletePlaylist(pid);
				remember(radioKey, null);
				toastUndo('Removed from Your Library', async () => {
					await undo();
					remember(radioKey, pid);
				});
				return;
			}
			if (!songs.length) return;
			const p = await lib.createPlaylist(title, radio?.description ?? undefined);
			await lib.addToPlaylist(p.id, $state.snapshot(songs) as SongItem[], { allowDuplicates: true });
			remember(radioKey, p.id);
			toast('Added to Your Library', { action: { label: 'View', onClick: () => goto(playlistHref(p.id)) } });
		} catch (e) {
			toast.fail(e, "Couldn't save this radio");
		}
	}

	const totalSecs = $derived(songs.reduce((n, s) => n + (s.duration ? (parseClock(s.duration) ?? 0) : 0), 0));
	function fmtTotal(secs: number) {
		const h = Math.floor(secs / 3600);
		const m = Math.floor((secs % 3600) / 60);
		return h ? `about ${h} hr ${m} min` : `${m} min ${Math.floor(secs % 60)} sec`;
	}
	const details = $derived(
		radio ? `${songs.length} songs${totalSecs ? `, ${fmtTotal(totalSecs)}` : ''}` : undefined
	);

	function more(e: MouseEvent) {
		const list = $state.snapshot(songs) as SongItem[];
		openMenu(e, [
			{ label: 'Add to queue', icon: QueueIcon, onSelect: () => addToQueue(list, title) },
			{ label: 'Play next', icon: ArrowBendDownRightIcon, onSelect: () => playNext(list, title) },
			{ type: 'separator' },
			{ label: savedId ? 'Remove from Your Library' : 'Save to Your Library', icon: MusicNotesPlusIcon, onSelect: onSave },
			{ label: 'Refresh radio', icon: ArrowClockwiseIcon, onSelect: () => load(kind, id, true) }
		]);
	}
</script>

<StickyHeader {title} tint={tint?.color} {playing} {onPlay} {sentinel} />
{#if error}
	<div class="pt-16"><ErrorState message={error} onRetry={() => load(kind, id, true)} /></div>
{:else}
	<PageHeader
		type="Playlist"
		{title}
		image={art}
		description={radio?.description}
		owner={{ name: 'Ztunes', logo: true }}
		{details}
		bind:tintOut={tint}
	>
		{#snippet imageSnippet()}
			<!-- Spotify's radio cover: the seed's art in a circle on its own colour, "RADIO" under it. -->
			<div class="relative flex size-full flex-col items-center justify-center gap-[6%] overflow-hidden" style="background:{tint?.color ?? '#535353'}" data-testid="radio-cover">
				{#if art}
					<img
						src={thumb(art, 544) ?? art}
						alt=""
						class="aspect-square w-[62%] rounded-full object-cover shadow-[0_8px_24px_rgba(0,0,0,.5)]"
					/>
				{/if}
				<span class="text-[clamp(10px,9%,22px)] font-black tracking-[0.2em] text-white uppercase">Radio</span>
			</div>
		{/snippet}
	</PageHeader>
	<ActionBar
		{playing}
		{onPlay}
		playLabel={`Play ${title}`}
		{shuffle}
		onShuffle={() => (shuffle = !shuffle)}
		saved={!!savedId}
		onSave={radio ? onSave : undefined}
		saveLabel={savedId ? 'Remove from Your Library' : 'Save to Your Library'}
		onMore={more}
		tint={tint?.rgb}
		bind:sentinel
	>
		{#if !radio}
			<Skeleton variant="row" count={10} />
		{:else if !songs.length}
			<EmptyState size="sm" title="This radio is empty right now" body="Try again in a moment." />
		{:else}
			<TrackTable
				tracks={songs}
				variant="queue"
				context={{ id: key, title, kind: 'playlist' }}
				stickyTop={64}
				bleed="var(--content-spacing)"
				isPlaying={(s) => current && playback.now?.videoId === s.video_id}
				onPlay={(_list, pos) => play(pos)}
			/>
		{/if}
	</ActionBar>
{/if}
