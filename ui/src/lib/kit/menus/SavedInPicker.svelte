<script lang="ts">
	/**
	 * Spotify's "Saved in" picker: what the accent "liked" check opens (track rows, player bar).
	 * Search "Find a playlist", "+ New playlist", then a "Saved in" list (Liked Songs first, then
	 * your playlists) with round accent checkboxes, and Cancel / Done at the bottom. Nothing changes
	 * until Done; Done applies the difference (like/unlike, add to / remove from playlists).
	 */
	import { untrack } from 'svelte';
	import * as api from '$lib/api';
	import type { BrowseItem, SongItem } from '$lib/api';
	import Icon from '../Icon.svelte';
	import PlusIcon from 'phosphor-svelte/lib/PlusIcon';
	import MagnifyingGlassIcon from 'phosphor-svelte/lib/MagnifyingGlassIcon';
	import CheckIcon from 'phosphor-svelte/lib/CheckIcon';
	import HeartIcon from 'phosphor-svelte/lib/HeartIcon';
	import MusicNotesIcon from 'phosphor-svelte/lib/MusicNotesIcon';
	import { thumb } from '$lib/thumb';
	import { addToPlaylist, createPlaylist, editablePlaylists, isLiked, likeSongs, removeFromPlaylist, unlikeSongs } from '../actions';

	let { song: songProp, close }: { song: SongItem; close: () => void } = $props();
	// A plain copy: rows hand in reactive proxies, which the IPC layer can't clone.
	const song: SongItem = untrack(() => $state.snapshot(songProp) as SongItem);

	const LIKED = '__liked__';
	const playlists = editablePlaylists();
	let q = $state('');
	// stream: tilefix — a cover that fails to load shows the placeholder, not a broken image.
	let failedArt = $state<Record<string, true>>({});
	// Where the song is now: Liked Songs at once; local playlists after a quick look-up.
	// Snapshot at open: the picker edits a draft and applies it on Done.
	const initial = new Set<string>(isLiked(song) ? [LIKED] : []);
	let picked = $state(new Set<string>(initial));
	const entries = new Map<string, SongItem[]>();
	$effect(() => {
		let stale = false;
		for (const p of playlists) {
			if (!api.isLocalPlaylist(p.id)) continue;
			api
				.getPlaylist(p.id)
				.then((page) => {
					if (stale) return;
					const rows = page.items.filter((s) => s.video_id === song.video_id);
					if (!rows.length) return;
					entries.set(p.id, rows);
					initial.add(p.id);
					picked = new Set([...picked, p.id]);
				})
				.catch(() => {});
		}
		return () => (stale = true);
	});

	const list = $derived.by(() => {
		const n = q.trim().toLowerCase();
		return n ? playlists.filter((p) => p.title.toLowerCase().includes(n)) : playlists;
	});
	function flip(id: string) {
		const next = new Set(picked);
		if (next.has(id)) next.delete(id);
		else next.add(id);
		picked = next;
	}
	async function done() {
		close();
		const want = picked;
		if (want.has(LIKED) !== initial.has(LIKED)) await (want.has(LIKED) ? likeSongs([song]) : unlikeSongs([song]));
		for (const p of playlists) {
			if (want.has(p.id) && !initial.has(p.id)) await addToPlaylist($state.snapshot(p) as BrowseItem, [song]);
			else if (!want.has(p.id) && initial.has(p.id)) await removeFromPlaylist(p.id, entries.get(p.id) ?? []);
		}
	}
	const keep = (e: KeyboardEvent) => {
		if (e.key.length === 1 || e.key === 'Backspace') e.stopPropagation();
	};
</script>

{#snippet row(id: string, label: string, image: string | null | undefined, liked = false)}
	{@const on = picked.has(id)}
	<button
		type="button"
		role="menuitemcheckbox"
		aria-checked={on}
		class="flex h-12 w-full items-center gap-3 rounded-sm px-2 text-left text-sm text-white hover:bg-bg-tinted focus-visible:bg-bg-tinted focus-visible:outline-none"
		onclick={() => flip(id)}
	>
		<span class="grid size-8 shrink-0 place-items-center overflow-hidden rounded-sm bg-bg-elevated-highlight text-text-subdued">
			{#if liked}
				<span class="grid size-full place-items-center bg-[linear-gradient(135deg,#ff4b4b,#6a1b9a)] text-white"><Icon icon={HeartIcon} size={14} fill /></span>
			{:else if image && !failedArt[image]}
				<img
					src={thumb(image, 64)}
					alt=""
					class="size-full object-cover"
					onerror={() => (failedArt = { ...failedArt, [image]: true })}
				/>
			{:else}
				<Icon icon={MusicNotesIcon} size={16} />
			{/if}
		</span>
		<span class="min-w-0 flex-1 truncate">{label}</span>
		<span
			class="grid size-4 shrink-0 place-items-center rounded-full {on
				? 'bg-accent text-black'
				: 'border border-text-subdued'}"
		>
			{#if on}<Icon icon={CheckIcon} size={10} weight="bold" />{/if}
		</span>
	</button>
{/snippet}

<div class="w-[330px] p-1" role="group" aria-label="Saved in">
	<div class="relative pb-1">
		<Icon icon={MagnifyingGlassIcon} size={16} class="pointer-events-none absolute top-4 left-2 -translate-y-1/2 text-white/70" />
		<input
			bind:value={q}
			placeholder="Find a playlist"
			class="h-8 w-full rounded-sm bg-white/10 py-2 pr-2 pl-8 text-sm text-white outline-none placeholder:text-white/60 focus:bg-white/15"
			onkeydown={keep}
		/>
	</div>
	<button
		type="button"
		class="flex h-10 w-full items-center gap-3 rounded-sm px-2 text-left text-sm text-white hover:bg-bg-tinted"
		onclick={() => {
			close();
			createPlaylist([song], false);
		}}
	>
		<Icon icon={PlusIcon} size={16} />New playlist
	</button>
	<div class="my-1 h-px bg-white/10"></div>
	<p class="px-2 pt-2 pb-1 text-xs font-bold text-text-subdued">Saved in</p>
	<div class="max-h-[min(calc(100vh-360px),336px)] overflow-y-auto">
		{#if !q.trim() || 'liked songs'.includes(q.trim().toLowerCase())}
			{@render row(LIKED, 'Liked Songs', null, true)}
		{/if}
		{#each list as p (p.id)}{@render row(p.id, p.title, (p as BrowseItem).thumbnail)}{/each}
	</div>
	<div class="mt-1 flex items-center justify-end gap-4 border-t border-white/10 px-2 pt-3 pb-2">
		<button type="button" class="text-sm font-bold text-text-subdued hover:scale-[1.04] hover:text-white" onclick={close}>Cancel</button>
		<button
			type="button"
			class="h-8 rounded-full bg-white px-4 text-sm font-bold text-black hover:scale-[1.04]"
			onclick={done}>Done</button
		>
	</div>
</div>
