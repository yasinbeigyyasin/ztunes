<script lang="ts">
	import { ownerName } from '$lib/localuser.svelte';
	// Local Files (Spotify: the "Local Files" playlist in Your Library). Music on this machine,
	// from the folders chosen here or in Settings; works signed out and offline (Rust `local.rs`).
	import { onMount } from 'svelte';
	import { open } from '@tauri-apps/plugin-dialog';
	import * as api from '$lib/api';
	import type { SongItem } from '$lib/api';
	import {
		ActionBar,
		EmptyState,
		ErrorState,
		Icon,
		PageHeader,
		Skeleton,
		StickyHeader,
		TrackTable,
		openMenu,
		toast,
		type Tint
	} from '$lib/kit';
	import FolderSimpleIcon from 'phosphor-svelte/lib/FolderSimpleIcon';
	import FolderSimplePlusIcon from 'phosphor-svelte/lib/FolderSimplePlusIcon';
	import ArrowClockwiseIcon from 'phosphor-svelte/lib/ArrowClockwiseIcon';
	import FolderMinusIcon from 'phosphor-svelte/lib/FolderMinusIcon';
	import MagnifyingGlassIcon from 'phosphor-svelte/lib/MagnifyingGlassIcon';
	import type { MenuEntry } from '$lib/kit/menus';
	import { addLocalFolder, local, openPlayer, playback, removeLocalFolder, scanLocal } from '$lib/player.svelte';
	import { indexSongs, match } from '$lib/localsearch';

	const NAME = 'Local Files';
	const TINT = 'rgb(83 83 83)';

	onMount(() => {
		scanLocal();
	});

	let query = $state('');
	let searching = $state(false);
	const ix = $derived(indexSongs(local.songs));
	const songs = $derived(query.trim() ? match(ix, query.trim()) : local.songs);

	const secs = (d?: string) =>
		(d ?? '').split(':').reduce((acc, part) => acc * 60 + (Number(part) || 0), 0);
	const total = $derived(local.songs.reduce((n, s) => n + secs(s.duration), 0));
	const totalText = $derived.by(() => {
		const h = Math.floor(total / 3600);
		const m = Math.floor((total % 3600) / 60);
		return h ? `about ${h} hr ${m} min` : `${m} min ${Math.floor(total % 60)} sec`;
	});

	// One queue named "Local Files", no sourceId: there is no YouTube radio to continue it with.
	const ours = $derived(!!playback.now && playback.queue.sourceName === NAME && !playback.queue.sourceId);
	const playing = $derived(ours && !playback.paused);
	const shuffleOn = $derived(ours && !!playback.queue.shuffle);

	function playList(list: SongItem[], start: number | null, shuffle = false) {
		if (!list.length) return;
		openPlayer();
		api.playPlaylist(list, start, undefined, NAME, shuffle);
	}
	function play() {
		if (ours) return api.togglePause();
		playList(songs, 0);
	}
	function shuffle() {
		if (ours) return api.toggleShuffle();
		playList(songs, null, true);
	}

	async function pickFolder() {
		const picked = await open({ directory: true, multiple: false, title: 'Add a music folder' });
		if (typeof picked === 'string') await addLocalFolder(picked);
	}

	function more(e: MouseEvent) {
		const entries: MenuEntry[] = [
			{ label: 'Add a folder', icon: FolderSimplePlusIcon, onSelect: pickFolder },
			{ label: local.loading ? 'Scanning…' : 'Rescan folders', icon: ArrowClockwiseIcon, disabled: local.loading || !local.folders.length, onSelect: () => scanLocal() }
		];
		if (local.folders.length) {
			entries.push(
				{ type: 'separator' },
				{
					type: 'sub',
					label: 'Remove folder',
					icon: FolderMinusIcon,
					width: 320,
					items: local.folders.map((f) => ({
						label: f,
						onSelect: async () => {
							await removeLocalFolder(f);
							toast('Folder removed');
						}
					}))
				}
			);
		}
		openMenu(e, entries);
	}

	let tint = $state<Tint>();
	let sentinel = $state<HTMLElement>();
	let searchEl = $state<HTMLInputElement>();
</script>

<svelte:head><title>{NAME}</title></svelte:head>

<StickyHeader title={NAME} tint={tint?.color} {playing} onPlay={local.songs.length ? play : undefined} {sentinel} />
<PageHeader
	type="Playlist"
	title={NAME}
	tint={TINT}
	bind:tintOut={tint}
	owner={{ name: ownerName(), noAvatar: true }}
	details={local.songs.length ? `${local.songs.length} song${local.songs.length === 1 ? '' : 's'}, ${totalText}` : null}
>
	{#snippet imageSnippet()}
		<div class="grid size-full place-items-center bg-[linear-gradient(135deg,#535353,#1f1f1f)] text-white">
			<Icon icon={FolderSimpleIcon} size={80} fill />
		</div>
	{/snippet}
</PageHeader>

<ActionBar
	bind:sentinel
	tint={tint?.color}
	{playing}
	onPlay={local.songs.length ? play : undefined}
	playLabel="Play Local Files"
	shuffle={local.songs.length ? shuffleOn : undefined}
	onShuffle={shuffle}
	onMore={more}
	moreLabel="More options for Local Files"
>
	{#snippet right()}
		{#if local.songs.length}
			<div class="flex items-center">
				{#if searching || query}
					<div class="flex h-8 w-[200px] items-center gap-2 rounded-sm bg-bg-tinted px-2">
						<Icon icon={MagnifyingGlassIcon} size={16} class="text-text-subdued" />
						<input
							bind:this={searchEl}
							bind:value={query}
							placeholder="Search in Local Files"
							class="min-w-0 flex-1 bg-transparent text-sm text-white outline-none placeholder:text-text-subdued"
							onblur={() => (searching = false)}
							onkeydown={(e) => e.key === 'Escape' && ((query = ''), searchEl?.blur())}
						/>
					</div>
				{:else}
					<button
						type="button"
						class="grid size-8 place-items-center rounded-full text-text-subdued hover:text-white"
						aria-label="Search in Local Files"
						onclick={async () => {
							searching = true;
							await Promise.resolve();
							searchEl?.focus();
						}}
					>
						<Icon icon={MagnifyingGlassIcon} size={16} />
					</button>
				{/if}
			</div>
		{/if}
	{/snippet}

	<div class="px-[var(--content-spacing)] pb-10">
		{#if local.error}
			<ErrorState message={local.error} onRetry={() => scanLocal()} />
		{:else if local.loading && !local.scanned && !local.songs.length}
			<Skeleton variant="row" count={8} />
		{:else if local.songs.length}
			<TrackTable
				tracks={songs}
				variant="queue"
				stickyTop={64}
				bleed="var(--content-spacing)"
				scroller={document.querySelector('[data-main-scroll]') as HTMLElement | null}
				onPlay={(list, pos) => playList(list, pos)}
			>
				{#snippet empty()}
					<div class="py-10">
						<EmptyState size="sm" title={`Couldn't find "${query}"`} body="Try searching again using a different spelling or keyword." />
					</div>
				{/snippet}
			</TrackTable>
		{:else}
			<div class="py-16">
				<EmptyState
					icon={FolderSimpleIcon}
					title={local.folders.length ? 'No music found in your folders' : 'Add your local music'}
					body={local.folders.length
						? 'Ztunes plays MP3, FLAC, M4A, OGG, WAV and more. Add another folder or rescan.'
						: 'Choose a folder on this Mac and its songs show up here. Nothing is uploaded.'}
					actionLabel="Add a folder"
					onAction={pickFolder}
				/>
			</div>
		{/if}
	</div>
</ActionBar>
