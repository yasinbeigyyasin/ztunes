<script lang="ts">
	// "Import from Spotify" (#375), restyled to Spotify's modal (overlays.md) by stream p-settings.
	// The step on screen is read off the import itself, not kept here, so closing the dialog
	// mid-import and coming back (from the avatar menu, Settings, or after a toast) lands on whatever
	// the import is doing now. Closing never stops anything; Stop does.
	// Liked Songs land in your likes, playlists as local playlists (or on YouTube Music when signed
	// in and chosen), saved albums / followed artists in Your Library (library.md).
	import { untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import Modal from '$lib/kit/Modal.svelte';
	import ImportStart from '$lib/import/ImportStart.svelte';
	import { LINE, PRIMARY, QUIET, SECONDARY, TITLE } from '$lib/import/onboard';
	import Icon from '$lib/kit/Icon.svelte';
	import Pill from '$lib/kit/Pill.svelte';
	import IconButton from '$lib/kit/IconButton.svelte';
	import * as api from '$lib/api';
	import { copyText } from '$lib/clipboard';
	import { thumb } from '$lib/thumb';
	import { parseYtLink } from '$lib/ytlink';
	import { rowScroller } from '$lib/rows.svelte';
	import { rowWindow } from '$lib/rows';
	import { t } from '$lib/i18n.svelte';
	import { auth, toast } from '$lib/player.svelte';
	import {
		clockTime,
		cooldownUntil,
		dismissImport,
		imp,
		importError,
		startImport
	} from '$lib/import.svelte';
	import CheckCircleIcon from 'phosphor-svelte/lib/CheckCircleIcon';
	import MusicNoteIcon from 'phosphor-svelte/lib/MusicNoteIcon';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import CheckIcon from 'phosphor-svelte/lib/CheckIcon';
	import CaretLeftIcon from 'phosphor-svelte/lib/CaretLeftIcon';
	import MagnifyingGlassIcon from 'phosphor-svelte/lib/MagnifyingGlassIcon';
	import HeartIcon from 'phosphor-svelte/lib/HeartIcon';
	import ClockCounterClockwiseIcon from 'phosphor-svelte/lib/ClockCounterClockwiseIcon';

	const signedIn = $derived(!!auth.account?.signedIn);
	// An "Update from Spotify" runs as the same kind of job but never takes the dialog over.
	const job = $derived(imp.snapshot?.phase && !imp.snapshot.update ? imp.snapshot : null);
	const view = $derived(job ? job.phase : imp.preview ? 'pick' : 'source');
	const listName = (l: { kind: api.ImportListKind; name: string }) =>
		l.kind === 'liked' ? t('import.liked_songs') : l.kind === 'history' ? t('import.history') : l.name;
	// stream: import2: the second line of a list in the picker.
	const listLine = (l: api.ImportListPreview) =>
		l.kind === 'history'
			? t('import.history_line', { plays: (imp.preview?.history?.plays ?? 0).toLocaleString(), count: l.count })
			: l.lazy
				? `Playlist${l.owner ? ` • ${l.owner}` : ''}`
				: `${l.kind === 'liked' ? 'Liked Songs' : 'Playlist'} • ${t('import.songs_count', { count: l.count })}`;
	const pct = (done: number, total: number) => (total ? Math.round((done / total) * 100) : 100);
	const mmss = (ms?: number | null) => {
		if (!ms) return '';
		const s = Math.round(ms / 1000);
		return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
	};

	// --- pick ------------------------------------------------------------------------------------

	let picked = $state<boolean[]>([]);
	// Everything ticked whenever a new read lands.
	$effect(() => {
		picked = (imp.preview?.lists ?? []).map(() => true);
	});
	const pickedIdx = $derived(picked.flatMap((p, i) => (p ? [i] : [])));
	const pickedSongs = $derived(pickedIdx.reduce((n, i) => n + (imp.preview?.lists[i]?.count ?? 0), 0));
	const extras = $derived.by(() => {
		const p = imp.preview as (api.ImportPreview & { albums?: number; artists?: number }) | null;
		return { albums: p?.albums ?? 0, artists: p?.artists ?? 0 };
	});

	/** The one small print line under the checklist: what else comes along, what a profile leaves out. */
	const pickNote = $derived.by(() => {
		const p = imp.preview;
		if (!p) return '';
		const parts: string[] = [];
		if (p.history && pickedIdx.includes(p.lists.findIndex((l) => l.kind === 'history')))
			parts.push(t('import.history_hint', { from: new Date(p.history.from * 1000).toLocaleDateString(undefined, { month: 'short', year: 'numeric' }) }));
		if (extras.albums || extras.artists)
			parts.push(`Your ${extras.albums} saved ${extras.albums === 1 ? 'album' : 'albums'} and ${extras.artists} followed ${extras.artists === 1 ? 'artist' : 'artists'} come along too.`);
		if (p.profile && p.profile.total > p.profile.playlists.length) parts.push(t('import.profile_more', { shown: p.profile.playlists.length }));
		return parts.join(' ');
	});

	// --- matching --------------------------------------------------------------------------------

	// When matching started, from this side: the time left is measured, not guessed.
	let clock = $state<{ at: number; done: number } | null>(null);
	$effect(() => {
		if (view !== 'matching') clock = null;
		else if (!clock && job) clock = { at: Date.now(), done: job.done };
	});
	const minutesLeft = $derived.by(() => {
		if (!job || !clock) return null;
		const did = job.done - clock.done;
		if (did < 5) return null;
		return Math.max(1, Math.round((((Date.now() - clock.at) / did) * (job.total - job.done)) / 60000));
	});

	// --- review (stream onboard: a summary first, the rows behind "Check …") ---------------------

	type Tab = 'check' | 'missing' | 'matched';
	let checking = $state(false);
	let tiers = $state<Partial<Record<Tab, api.ImportRow[]>>>({});
	let rowsLoading = $state(false);
	// Rows the user has settled in this sitting, so they read as done without leaving the list.
	let settled = $state<Record<string, 'kept' | 'out'>>({});
	/** Uncertain first, then not found, then (once asked for) the matched ones. */
	const rows = $derived([...(tiers.check ?? []), ...(tiers.missing ?? []), ...(tiers.matched ?? [])]);

	async function loadTier(tier: Tab) {
		if (tiers[tier]) return;
		rowsLoading = true;
		try {
			tiers[tier] = await api.importRows(tier);
		} catch (e) {
			toast.error(importError(e));
		} finally {
			rowsLoading = false;
		}
	}

	async function openCheck() {
		checking = true;
		open = null;
		if (job?.check) await loadTier('check');
		if (job?.missing) await loadTier('missing');
		if (!job?.check && !job?.missing) await loadTier('matched');
	}

	// A new review starts on the summary.
	$effect(() => {
		if (view !== 'review') return;
		untrack(() => {
			settled = {};
			tiers = {};
			checking = false;
		});
	});

	// The summary's numbers and its quiet link.
	const ready = $derived(job ? job.matched + job.check : 0);
	const addsLine = $derived.by(() => {
		if (!job) return '';
		const parts: string[] = [];
		const n = job.lists.filter((l) => l.kind === 'playlist' || l.kind === 'album').length;
		if (n) parts.push(n === 1 ? t('onboard.adds_playlist') : t('onboard.adds_playlists', { count: n }));
		if (job.lists.some((l) => l.kind === 'liked')) parts.push(t('onboard.adds_liked'));
		if (job.lists.some((l) => l.kind === 'history')) parts.push(t('onboard.adds_history'));
		if (!parts.length) return '';
		const what = parts.length > 1 ? parts.slice(0, -1).join(', ') + t('onboard.and') + parts[parts.length - 1] : parts[0];
		return t('onboard.adds', { what });
	});
	const checkLabel = $derived(
		job?.check
			? t('onboard.check_uncertain', { count: job.check })
			: job?.missing
				? t('onboard.see_missing', { count: job.missing })
				: t('onboard.see_all')
	);

	async function choose(row: api.ImportRow, song: api.SongItem | null) {
		try {
			imp.snapshot = await api.importPick(row.key, song);
			for (const tier of ['check', 'missing', 'matched'] as Tab[]) {
				const list = tiers[tier];
				const i = list?.findIndex((r) => r.key === row.key) ?? -1;
				if (list && i >= 0) list[i] = { ...list[i], pick: song ?? list[i].pick };
			}
			settled[row.key] = song ? 'kept' : 'out';
			open = null;
		} catch (e) {
			toast.error(importError(e));
		}
	}

	const sc = rowScroller();
	const win = $derived(rowWindow(sc.scrollTop, sc.viewportPx, rows.length, sc.rowPx));

	// The one row whose picker is open (it replaces the list), and its search.
	let open = $state<string | null>(null);
	const openRow = $derived(open ? rows.find((r) => r.key === open) : undefined);
	let query = $state('');
	let results = $state<api.SongItem[]>([]);
	let searching = $state(false);
	$effect(() => {
		if (open) {
			const row = untrack(() => rows.find((r) => r.key === open));
			query = row ? `${row.title} ${row.artists}` : '';
			results = [];
		}
	});
	async function search(e: Event) {
		e.preventDefault();
		if (!query.trim()) return;
		// A pasted YouTube link (#441): the track may only be up as a video, which a song search
		// never turns up.
		const ytLink = parseYtLink(query);
		searching = true;
		try {
			results = ytLink?.kind === 'song' ? [await api.song(ytLink.id)] : await api.search(query.trim());
		} catch (e) {
			toast.error(importError(e));
		} finally {
			searching = false;
		}
	}

	// --- create ----------------------------------------------------------------------------------

	let name = $state('');
	// Local first: no account is needed for anything. Signed-in users can pick YouTube Music.
	let where = $state<'account' | 'device'>('device');
	$effect(() => {
		if (view === 'review') untrack(() => (name = job?.lists.length === 1 ? listName(job.lists[0]) : ''));
	});
	const onlyLiked = $derived(!!job && job.lists.every((l) => l.kind === 'liked' || l.kind === 'history'));
	const playlistCount = $derived(job ? job.lists.filter((l) => l.kind !== 'liked' && l.kind !== 'history').length : 0);

	async function create() {
		if (!job) return;
		const names: Record<number, string> = {};
		job.lists.forEach((l, i) => {
			if (l.kind === 'liked') names[i] = t('import.liked_songs_playlist');
		});
		if (job.lists.length === 1 && job.lists[0].kind === 'playlist' && name.trim()) names[0] = name.trim();
		try {
			await api.importCreate({ names, local: !signedIn || where === 'device' });
		} catch (e) {
			toast.error(importError(e));
		}
	}

	// --- done ------------------------------------------------------------------------------------

	function openResult(r: api.ImportResult) {
		imp.open = false;
		goto(r.kind === 'history' ? '/history' : `/playlist/${encodeURIComponent(r.id)}`);
		dismissImport();
	}

	async function copyMissing() {
		const missing = await api.importRows('missing').catch(() => []);
		if (!missing.length) return;
		// Tab-separated, so it pastes into a spreadsheet as two columns.
		await copyText(missing.map((r) => `${r.artists}\t${r.title}`).join('\n'));
		toast.success(t('import.copied', { count: missing.length }));
	}

	function finish() {
		imp.open = false;
		dismissImport();
	}

	// The failed view's clock, so "Try again at 18:40" turns back into "Try again" on its own.
	let now = $state(Date.now());
	$effect(() => {
		if (view !== 'failed') return;
		now = Date.now();
		const timer = setInterval(() => (now = Date.now()), 15_000);
		return () => clearInterval(timer);
	});

	// stream: onboard: the views carry their own big centred title; the modal's own title only on
	// the check list (a working view).
	const modalTitle = $derived(view === 'review' && checking ? t('onboard.check_title') : undefined);

	const width = $derived(view === 'review' && checking ? 720 : 524);
	const INPUT =
		'h-10 w-full min-w-0 rounded-sm bg-bg-tinted px-3 text-sm text-white outline-none placeholder:text-text-subdued focus:bg-bg-tinted-highlight focus:shadow-[inset_0_0_0_1px_#535353]';
</script>

{#snippet bar(done: number, total: number)}
	<div class="h-1 w-full overflow-hidden rounded-full bg-progress-track">
		<div class="h-full rounded-full bg-accent transition-[width] duration-300" style="width: {pct(done, total)}%"></div>
	</div>
{/snippet}

{#snippet art(url: string | null | undefined, size: number)}
	{#if url}
		<img src={thumb(url, 96)} alt="" style="width:{size}px;height:{size}px" class="shrink-0 rounded-sm bg-bg-menu object-cover" loading="lazy" />
	{:else}
		<div style="width:{size}px;height:{size}px" class="grid shrink-0 place-items-center rounded-sm bg-bg-elevated-highlight text-text-subdued">
			<Icon icon={MusicNoteIcon} size={16} />
		</div>
	{/if}
{/snippet}

{#snippet songLine(s: api.SongItem)}
	<div class="flex min-w-0 items-center gap-3">
		{@render art(s.thumbnail, 40)}
		<div class="min-w-0">
			<div class="truncate text-base text-white">{s.title}</div>
			<div class="truncate text-sm text-text-subdued">
				{[s.artists, s.album, s.duration].filter(Boolean).join(' • ')}
			</div>
		</div>
	</div>
{/snippet}

{#snippet check(on: boolean)}
	<span
		class="grid size-4 shrink-0 place-items-center rounded-[2px] {on
			? 'bg-accent text-black'
			: 'shadow-[inset_0_0_0_1px_#7c7c7c]'}"
	>
		{#if on}<Icon icon={CheckIcon} size={12} weight="bold" />{/if}
	</span>
{/snippet}

<!-- stream: onboard — one idea per view, one big accent button, short copy; same flow as iOS. -->
<Modal bind:open={imp.open} title={modalTitle} {width}>
	<div class="flex flex-col gap-4 text-sm">
		{#if view === 'source'}
			<ImportStart onNotNow={() => (imp.open = false)} />
		{:else if view === 'pick' && imp.preview}
			{@const p = imp.preview}
			{#if p.lists.length === 1}
				{@const l = p.lists[0]}
				<!-- One playlist or album: no checklist, just what it is. -->
				<div class="flex flex-col items-center gap-3 pt-2 text-center">
					<div class="shadow-card-image">{@render art(l.cover, 160)}</div>
					<h2 class="{TITLE} mt-2">{listName(l)}</h2>
					<p class={LINE}>
						{#if l.owner}{t('import.by', { owner: l.owner })} • {/if}{t('import.songs_count', { count: l.count })}
					</p>
					{#if l.truncated}<p class="max-w-[380px] text-xs text-text-subdued">{t('import.truncated')}</p>{/if}
				</div>
			{:else}
				<div class="flex flex-col gap-1">
					{#if p.profile}
						<!-- stream: import2: a profile link's public playlists -->
						<div class="mb-2 flex items-center gap-3">
							{#if p.profile.avatar}
								<img src={p.profile.avatar} alt="" class="size-10 shrink-0 rounded-full object-cover" />
							{:else}
								<div class="grid size-10 shrink-0 place-items-center rounded-full bg-bg-elevated-highlight text-base font-bold text-white">{p.profile.name.slice(0, 1).toUpperCase()}</div>
							{/if}
							<span class="text-base font-bold text-white">{p.profile.name}</span>
						</div>
					{/if}
					<h2 class={TITLE}>{t('onboard.pick_title')}</h2>
					<p class={LINE}>{t('onboard.pick_line')}</p>
				</div>
				<div class="flex items-center justify-between text-text-subdued">
					<span>{t('onboard.selected', { count: pickedIdx.length, total: p.lists.length })}</span>
					<button class="font-bold text-white hover:underline" onclick={() => (picked = picked.map(() => !pickedIdx.length))}>
						{pickedIdx.length ? t('import.select_none') : t('import.select_all')}
					</button>
				</div>
				<div class="scroll-area max-h-[45vh] overflow-y-auto">
					{#each p.lists as l, i (i)}
						<button
							type="button"
							role="checkbox"
							aria-checked={picked[i]}
							class="flex h-14 w-full items-center gap-3 rounded-sm px-2 text-left hover:bg-bg-tinted {picked[i] ? '' : 'opacity-60'}"
							onclick={() => (picked[i] = !picked[i])}
						>
							{#if l.kind === 'history'}
								<div class="grid size-10 shrink-0 place-items-center rounded-sm bg-bg-elevated-highlight text-white"><Icon icon={ClockCounterClockwiseIcon} size={20} /></div>
							{:else}
								{@render art(l.cover, 40)}
							{/if}
							<div class="min-w-0 flex-1">
								<div class="truncate text-base text-white">{listName(l)}</div>
								<div class="truncate text-sm text-text-subdued">{listLine(l)}</div>
							</div>
							{@render check(picked[i])}
						</button>
					{/each}
				</div>
				{#if pickNote}<p class="text-xs text-text-subdued">{pickNote}</p>{/if}
			{/if}
			<div class="mt-2 flex flex-col gap-1">
				<button class={PRIMARY} onclick={() => startImport(pickedIdx)} disabled={!pickedIdx.length}>
					{pickedIdx.some((i) => p.lists[i]?.lazy) ? t('import.start_lists', { count: pickedIdx.length }) : t('import.start_count', { count: pickedSongs })}
				</button>
				<button class={QUIET} onclick={() => (imp.preview = null)}>{t('common.back')}</button>
			</div>
		{:else if job && (view === 'matching' || view === 'creating')}
			{@const creating = view === 'creating'}
			{@const done = creating ? job.step[0] : job.done}
			{@const total = creating ? job.step[1] : job.total}
			<div class="flex flex-col items-center gap-2 pt-2 text-center">
				<h2 class={TITLE}>{creating ? t('onboard.creating_title') : t('onboard.matching_title')}</h2>
				<p class={LINE}>{creating ? t('onboard.creating_line') : t('onboard.matching_line')}</p>
				<div class="mt-6 text-5xl font-bold text-white tabular-nums">{pct(done, total)}%</div>
				<div class="w-full max-w-[360px]">{@render bar(done, total)}</div>
				<p class="text-text-subdued tabular-nums">
					{#if !creating}{t('import.progress', { done: done.toLocaleString(), total: total.toLocaleString() })}{#if minutesLeft && !job.waitingUntil}{` • ${t('import.eta', { minutes: minutesLeft })}`}{/if}{/if}
				</p>
				<p class="h-5 max-w-full truncate text-text-subdued">
					{#if !creating && job.recent[0]}{job.recent[0].title} • {job.recent[0].artists}{/if}
				</p>
				{#if job.waitingUntil}
					<p class="text-xs text-text-subdued">{t('import.waiting', { time: clockTime(job.waitingUntil) })}</p>
				{/if}
			</div>
			<div class="mt-4 flex flex-col gap-1">
				<p class="text-center text-xs text-text-subdued">{t('onboard.keep_going')}</p>
				<button class={SECONDARY} onclick={() => (imp.open = false)}>{t('onboard.hide')}</button>
				<button class={QUIET} onclick={() => api.importCancel()}>{t('import.stop')}</button>
			</div>
		{:else if job && view === 'review' && !checking}
			<!-- The summary: what is ready, one button, the details behind a quiet link. -->
			<div class="flex flex-col items-center gap-2 pt-2 text-center">
				<div class="mb-4 grid size-20 place-items-center rounded-full bg-accent text-black">
					<Icon icon={CheckIcon} size={40} weight="bold" />
				</div>
				<h2 class={TITLE}>{t('onboard.matched_title', { count: ready.toLocaleString() })}</h2>
				{#if addsLine}<p class={LINE}>{addsLine}</p>{/if}
				{#if job.missing}<p class="text-sm text-text-subdued">{t('onboard.missing_line', { count: job.missing })}</p>{/if}
			</div>
			{#if (job.lists.length === 1 && !onlyLiked) || (signedIn && !onlyLiked)}
				<div class="flex flex-col gap-3 rounded-md bg-bg-highlight p-4">
					{#if job.lists.length === 1 && !onlyLiked}
						<input bind:value={name} class={INPUT} aria-label={t('import.name_label')} placeholder={t('import.name_label')} />
					{/if}
					{#if signedIn && !onlyLiked}
						<div class="flex items-center gap-3 text-text-subdued">
							<span>Save playlists</span>
							<Pill variant="chip" selected={where === 'device'} onclick={() => (where = 'device')}>On this Mac</Pill>
							<Pill variant="chip" selected={where === 'account'} onclick={() => (where = 'account')}>On YouTube Music</Pill>
						</div>
					{/if}
				</div>
			{/if}
			<div class="mt-2 flex flex-col gap-1">
				<button class={PRIMARY} onclick={create}>{t('onboard.looks_good')}</button>
				<button class={QUIET} onclick={openCheck}>{checkLabel}</button>
			</div>
		{:else if job && view === 'review'}
			<div class="h-[min(52vh,440px)] min-h-[240px]">
				{#if openRow}
					<!-- The picker for one row, in place of the list. -->
					<div class="flex h-full flex-col gap-3">
						<div class="flex items-center gap-2">
							<IconButton icon={CaretLeftIcon} label="Back" onclick={() => (open = null)} />
							<div class="min-w-0">
								<div class="truncate text-base font-bold text-white">{openRow.title}</div>
								<div class="truncate text-text-subdued">{[openRow.artists, openRow.album, mmss(openRow.durationMs)].filter(Boolean).join(' • ')}</div>
							</div>
						</div>
						<form class="flex items-center gap-3" onsubmit={search}>
							<div class="relative flex-1">
								<Icon icon={MagnifyingGlassIcon} size={16} class="pointer-events-none absolute top-3 left-3 text-text-subdued" />
								<input bind:value={query} class="{INPUT} pl-9" aria-label={t('import.search_ytm')} />
							</div>
							<button type="submit" class="btn-white sm shrink-0" disabled={searching}>{t('import.search_ytm')}</button>
						</form>
						<p class="text-xs text-text-subdued">{t('import.paste_link_hint')}</p>
						<div class="scroll-area min-h-0 flex-1 overflow-y-auto">
							{#each results.length ? results : openRow.candidates as c (c.video_id)}
								<button class="flex h-14 w-full items-center rounded-sm px-2 text-left hover:bg-bg-tinted" onclick={() => choose(openRow, c)}>
									{@render songLine(c)}
								</button>
							{:else}
								<p class="px-2 py-2 text-text-subdued">{searching ? t('common.searching') : t('import.no_candidates')}</p>
							{/each}
						</div>
						{#if openRow.pick && settled[openRow.key] !== 'out'}
							<button class="btn-outline self-center" onclick={() => choose(openRow, null)}>{t('import.skip')}</button>
						{/if}
					</div>
				{:else}
					<div class="scroll-area h-full overflow-y-auto" {@attach sc.attach}>
						<p class="px-2 pb-3 {LINE}">{t('onboard.check_line')}</p>
						<div style="height: {win.padTop}px"></div>
						{#each rows.slice(win.start, win.end) as row (row.key)}
							{@const mark = settled[row.key]}
							<div data-row class="group flex h-16 items-center gap-3 rounded-sm px-2 hover:bg-bg-tinted {mark === 'out' ? 'opacity-40' : ''}">
								<button class="flex min-w-0 flex-1 items-center gap-3 text-left" onclick={() => (open = row.key)}>
									{#if row.pick && mark !== 'out'}{@render art(row.pick.thumbnail, 40)}{:else}{@render art(null, 40)}{/if}
									<div class="min-w-0 flex-1">
										<div class="truncate text-base text-white">{row.title}</div>
										<div class="truncate text-sm text-text-subdued">
											{#if mark === 'out'}{t('import.left_out')}{:else if row.pick}{`${row.artists} → ${row.pick.title}${row.pick.duration ? ` • ${row.pick.duration}` : ''}`}{:else}{`${row.artists} • ${t('import.not_found_row')}`}{/if}
										</div>
									</div>
								</button>
								<div class="flex shrink-0 items-center gap-1">
									<span class="hidden text-xs text-text-subdued group-hover:inline">
										{row.tier === 'check' ? t('onboard.section_check') : row.tier === 'missing' ? '' : t('onboard.section_matched')}
									</span>
									{#if row.pick && mark !== 'out'}
										<IconButton icon={PlayIcon} label={t('import.preview_play')} fill onclick={() => row.pick && api.play(row.pick)} />
									{/if}
									{#if mark !== 'out' && row.pick && row.tier === 'check' && mark !== 'kept'}
										<IconButton icon={CheckIcon} label={t('import.keep')} onclick={() => choose(row, row.pick ?? null)} />
									{:else if mark === 'kept'}
										<Icon icon={CheckCircleIcon} size={20} fill class="mx-1.5 text-accent" />
									{/if}
								</div>
							</div>
						{/each}
						<div style="height: {win.padBottom}px"></div>
						{#if rowsLoading}<p class="p-2 text-text-subdued">{t('import.reading')}</p>{/if}
						{#if !tiers.matched && job.matched && !rowsLoading}
							<button class={QUIET} onclick={() => loadTier('matched')}>{t('onboard.show_matched', { count: job.matched.toLocaleString() })}</button>
						{/if}
					</div>
				{/if}
			</div>
			<button class={PRIMARY} onclick={() => ((checking = false), (open = null))}>{t('common.done')}</button>
		{:else if job && (view === 'done' || view === 'cancelled')}
			{@const added = job.results.filter((r) => r.kind !== 'history').reduce((n, r) => n + r.added, 0)}
			<div class="flex flex-col items-center gap-2 pt-2 text-center">
				{#if view === 'done'}
					<div class="mb-4 grid size-20 place-items-center rounded-full bg-accent text-black">
						<Icon icon={CheckIcon} size={40} weight="bold" />
					</div>
					<h2 class={TITLE}>{t('import.done_title')}</h2>
					<p class={LINE}>{added ? t('onboard.done_line', { count: added.toLocaleString() }) : t('onboard.done_none')}</p>
				{:else}
					<h2 class={TITLE}>{t('import.cancelled_title')}</h2>
					<p class={LINE}>{t('import.cancelled_desc')}</p>
				{/if}
			</div>
			{#if job.results.length}
				<div class="scroll-area flex max-h-[36vh] flex-col overflow-y-auto">
					{#each job.results as r (r.id)}
						<div class="flex h-16 items-center gap-3 rounded-sm px-2 hover:bg-bg-tinted">
							{#if r.id === api.LIKED_ID}
								<div class="grid size-12 shrink-0 place-items-center rounded-sm bg-[linear-gradient(135deg,#ff4b4b,#6a1b9a)] text-white"><Icon icon={HeartIcon} size={20} fill /></div>
							{:else if r.kind === 'history'}
								<div class="grid size-12 shrink-0 place-items-center rounded-sm bg-bg-elevated-highlight text-white"><Icon icon={ClockCounterClockwiseIcon} size={20} /></div>
							{:else}
								{@render art(job.lists.find((l) => l.name === r.name)?.cover, 48)}
							{/if}
							<div class="min-w-0 flex-1">
								<div class="truncate text-base text-white">{r.id === api.LIKED_ID ? 'Liked Songs' : r.kind === 'history' ? t('import.history') : r.name}</div>
								<div class="text-sm text-text-subdued">
									{r.kind === 'history' ? t('import.history_result', { count: r.added.toLocaleString() }) : r.updated ? t('import.result_updated', { count: r.added }) : t('import.result_added', { count: r.added })}{r.missing ? ` • ${t('import.result_missing', { count: r.missing })}` : ''}
								</div>
							</div>
							<Pill variant="outline" onclick={() => openResult(r)}>{t('import.open')}</Pill>
						</div>
					{/each}
				</div>
			{/if}
			<div class="mt-2 flex flex-col gap-1">
				<button class={PRIMARY} onclick={finish}>{t('common.done')}</button>
				{#if job.missing}
					<button class={QUIET} onclick={copyMissing}>{t('import.copy_missing')}</button>
				{/if}
			</div>
		{:else if job && view === 'failed'}
			{@const until = cooldownUntil(job.message)}
			{@const waiting = !!until && until * 1000 > now}
			<div class="flex flex-col items-center gap-2 pt-2 text-center">
				<h2 class={TITLE}>{t('import.failed_title')}</h2>
				<p class="text-base text-white">{importError(job.message)}</p>
				<p class={LINE}>{t('import.failed_hint')}</p>
			</div>
			<div class="mt-2 flex flex-col gap-1">
				<!-- Not before the cooldown is over: someone pressing it again and again is exactly the
				     traffic it is there to stop. -->
				<button class={PRIMARY} onclick={() => startImport(imp.picked)} disabled={waiting}>
					{waiting && until ? t('import.try_again_at', { time: clockTime(until) }) : t('import.try_again')}
				</button>
				<button class={QUIET} onclick={finish}>{t('common.close')}</button>
			</div>
		{/if}
	</div>
</Modal>
