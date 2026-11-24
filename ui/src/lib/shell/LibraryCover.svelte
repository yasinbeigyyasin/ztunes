<script lang="ts">
	/** Library artwork: the item image, or Spotify-style generated covers for Liked Songs (purple →
	 *  mint gradient + heart), Your Episodes (deep pink + bookmark), folders and empty playlists. */
	import Icon from '$lib/kit/Icon.svelte';
	import HeartIcon from 'phosphor-svelte/lib/HeartIcon';
	import BookmarkSimpleIcon from 'phosphor-svelte/lib/BookmarkSimpleIcon';
	import FolderSimpleIcon from 'phosphor-svelte/lib/FolderSimpleIcon';
	import MusicNotesIcon from 'phosphor-svelte/lib/MusicNotesIcon';
	import UserIcon from 'phosphor-svelte/lib/UserIcon';
	import { thumb } from '$lib/thumb';
	import type { LibRow } from './libraryItems.svelte';

	let { row, size = 48, radius = 4 }: { row: LibRow; size?: number; radius?: number } = $props();
	const round = $derived(row.kind === 'artist');
	const glyph = $derived(Math.round(size * 0.42));
	let failed = $state(false);
</script>

<div
	class="relative shrink-0 overflow-hidden"
	style="width:{size}px;height:{size}px;border-radius:{round ? '50%' : `${radius}px`}"
>
	{#if row.kind === 'liked'}
		<div class="grid size-full place-items-center bg-[linear-gradient(135deg,#ff4b4b,#6a1b9a)] text-white">
			<Icon icon={HeartIcon} size={glyph} fill />
		</div>
	{:else if row.kind === 'episodes'}
		<div class="grid size-full place-items-center bg-accent-tile text-accent">
			<Icon icon={BookmarkSimpleIcon} size={glyph} fill />
		</div>
	{:else if row.kind === 'local'}
		<div class="grid size-full place-items-center bg-[linear-gradient(135deg,#535353,#1f1f1f)] text-white">
			<Icon icon={FolderSimpleIcon} size={glyph} fill />
		</div>
	{:else if row.kind === 'folder'}
		<div class="grid size-full place-items-center bg-bg-menu text-text-subdued">
			<Icon icon={FolderSimpleIcon} size={glyph} />
		</div>
	{:else if row.image && !failed}
		<img
			src={/^https?:/.test(row.image) ? thumb(row.image, size * 2) : row.image}
			alt=""
			class="size-full bg-bg-menu object-cover"
			loading="lazy"
			draggable="false"
			onerror={() => (failed = true)}
		/>
	{:else}
		<div class="grid size-full place-items-center bg-bg-menu text-text-subdued">
			<Icon icon={round ? UserIcon : MusicNotesIcon} size={glyph} />
		</div>
	{/if}
</div>
