<script lang="ts">
	/**
	 * Spotify "Edit details" (overlays.md, ref/edit-details-modal.jpg): 524px #282828 modal, 180px
	 * cover (hover: pencil + "Choose photo"; "…" → Change photo / Remove photo) left, Name input and
	 * Description textarea right, "Make private" outline pill (YouTube playlists only) and the white
	 * Save pill. Esc / ✕ / backdrop cancel; Enter in Name saves. Nothing is written until Save.
	 */
	import type { Snippet } from 'svelte';
	import { open as pickFile } from '@tauri-apps/plugin-dialog';
	import { convertFileSrc } from '@tauri-apps/api/core';
	import * as api from '$lib/api';
	import { lib } from '$lib/library.svelte';
	import { thumb } from '$lib/thumb';
	import { Icon, Modal, openMenu, toast } from '$lib/kit';
	import PencilSimpleIcon from 'phosphor-svelte/lib/PencilSimpleIcon';
	import DotsThreeIcon from 'phosphor-svelte/lib/DotsThreeIcon';
	import LockSimpleIcon from 'phosphor-svelte/lib/LockSimpleIcon';
	import GlobeSimpleIcon from 'phosphor-svelte/lib/GlobeSimpleIcon';
	import MusicNotesIcon from 'phosphor-svelte/lib/MusicNotesIcon';
	import ImageIcon from 'phosphor-svelte/lib/ImageIcon';
	import TrashIcon from 'phosphor-svelte/lib/TrashIcon';

	const NAME_MAX = 100;
	const DESC_MAX = 300;

	let {
		open = $bindable(false),
		id,
		title,
		description,
		privacy,
		cover,
		fallback,
		onSaved
	}: {
		open?: boolean;
		id: string;
		title: string;
		description?: string;
		/** `PUBLIC` / `PRIVATE` / `UNLISTED` for a YouTube playlist; absent for one on this Mac. */
		privacy?: string;
		/** The custom picture, if any. */
		cover?: string | null;
		/** What shows when there is no custom picture (mosaic / first cover / note icon). */
		fallback?: Snippet;
		/** After a successful save, with what changed. */
		onSaved?: (patch: { title?: string; description?: string; privacy?: string; cover?: string | null }) => void;
	} = $props();

	let name = $state('');
	let desc = $state('');
	let isPublic = $state(false);
	/** undefined = unchanged; string = new file path; null = remove. */
	let pending = $state<string | null | undefined>(undefined);
	let saving = $state(false);
	let nameFocus = $state(false);
	let descFocus = $state(false);
	let nameEl = $state<HTMLInputElement | null>(null);

	const local = $derived(api.isLocalPlaylist(id));

	$effect(() => {
		if (!open) return;
		name = title ?? '';
		desc = description ?? '';
		isPublic = privacy === 'PUBLIC';
		pending = undefined;
	});

	const preview = $derived(
		pending === null
			? null
			: pending
				? convertFileSrc(pending)
				: cover
					? thumb(cover, 400)
					: null
	);
	const hasPicture = $derived(pending === undefined ? !!cover : pending !== null);

	async function choose() {
		try {
			const picked = await pickFile({
				multiple: false,
				title: 'Choose photo',
				filters: [{ name: 'Images', extensions: ['jpg', 'jpeg', 'png'] }]
			});
			if (typeof picked === 'string') pending = picked;
		} catch (e) {
			toast.error(String(e));
		}
	}

	function coverMenu(e: MouseEvent) {
		e.stopPropagation();
		openMenu(e.currentTarget as HTMLElement, [
			{ label: 'Change photo', icon: ImageIcon, onSelect: choose },
			{ label: 'Remove photo', icon: TrashIcon, disabled: !hasPicture, onSelect: () => (pending = null) }
		]);
	}

	async function save() {
		if (saving) return;
		const n = name.trim();
		if (!n) {
			toast.error('Playlist name is required.');
			nameEl?.focus();
			return;
		}
		saving = true;
		const patch: { title?: string; description?: string; privacy?: string; cover?: string | null } = {};
		try {
			const nameChanged = n !== title;
			const descChanged = desc !== (description ?? '');
			if (local) {
				if (nameChanged || descChanged) await lib.updatePlaylist(id, { name: n, description: desc });
			} else {
				const changes: { name?: string; description?: string; public?: boolean } = {};
				if (nameChanged) changes.name = n;
				if (descChanged) changes.description = desc;
				if (privacy !== undefined && isPublic !== (privacy === 'PUBLIC')) changes.public = isPublic;
				if (Object.keys(changes).length) await api.editPlaylistDetails(id, changes);
				if (changes.public !== undefined) patch.privacy = isPublic ? 'PUBLIC' : 'PRIVATE';
			}
			if (nameChanged) patch.title = n;
			if (descChanged) patch.description = desc;
			if (pending !== undefined) {
				const r = await api.setPlaylistCover(id, pending);
				patch.cover = r.cover ?? null;
			}
			open = false;
			onSaved?.(patch);
		} catch (e) {
			toast.error(String(e));
		} finally {
			saving = false;
		}
	}
</script>

<Modal bind:open title="Edit details">
	<div class="grid grid-cols-[180px_1fr] gap-4" data-keep-selection>
		<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
		<div
			class="group relative size-[180px] cursor-pointer overflow-hidden rounded-sm bg-bg-menu shadow-header-cover"
			onclick={choose}
		>
			{#if preview}
				<img src={preview} alt="" class="size-full object-cover" />
			{:else if pending === undefined && fallback}
				{@render fallback()}
			{:else}
				<div class="grid size-full place-items-center text-text-subdued">
					<Icon icon={MusicNotesIcon} size={64} />
				</div>
			{/if}
			<div
				class="absolute inset-0 flex flex-col items-center justify-center gap-2 bg-black/70 text-white opacity-0 transition-opacity duration-100 group-hover:opacity-100"
			>
				<Icon icon={PencilSimpleIcon} size={48} />
				<span class="text-base">Choose photo</span>
			</div>
			<button
				type="button"
				aria-label="Photo options"
				class="absolute top-2 right-2 grid size-8 place-items-center rounded-full bg-black/50 text-white opacity-0 group-hover:opacity-100 hover:scale-[1.04]"
				onclick={coverMenu}
			>
				<Icon icon={DotsThreeIcon} size={20} />
			</button>
		</div>
		<div class="flex min-w-0 flex-col gap-2">
			<div class="relative">
				{#if nameFocus}
					<span
						class="absolute -top-2 left-2.5 rounded-sm px-1 text-xs font-bold text-text-subdued"
						style="background:linear-gradient(transparent 45%, var(--color-bg-elevated-highlight) 45%)">Name</span
					>
				{/if}
				<input
					bind:this={nameEl}
					bind:value={name}
					maxlength={NAME_MAX}
					placeholder="Add a name"
					aria-label="Name"
					class="h-10 w-full rounded-sm border border-transparent bg-bg-tinted px-3 text-sm text-white outline-none placeholder:text-text-subdued focus:border-[#535353] focus:bg-bg-elevated-highlight"
					onfocus={() => (nameFocus = true)}
					onblur={() => (nameFocus = false)}
					onkeydown={(e) => e.key === 'Enter' && save()}
				/>
			</div>
			<div class="relative flex-1">
				{#if descFocus}
					<span
						class="absolute -top-2 left-2.5 z-[1] rounded-sm px-1 text-xs font-bold text-text-subdued"
						style="background:linear-gradient(transparent 45%, var(--color-bg-elevated-highlight) 45%)">Description</span
					>
				{/if}
				<textarea
					bind:value={desc}
					maxlength={DESC_MAX}
					placeholder="Add an optional description"
					aria-label="Description"
					class="h-[124px] w-full resize-none rounded-sm border border-transparent bg-bg-tinted p-2 pb-7 text-sm text-white outline-none placeholder:text-text-subdued focus:border-[#535353] focus:bg-bg-elevated-highlight"
					onfocus={() => (descFocus = true)}
					onblur={() => (descFocus = false)}
				></textarea>
				{#if descFocus}
					<span class="absolute right-2 bottom-2 text-xs text-text-subdued">{desc.length}/{DESC_MAX}</span>
				{/if}
			</div>
		</div>
	</div>
	<div class="mt-2 flex items-center justify-between gap-4">
		{#if privacy !== undefined && !local}
			<button type="button" class="btn-outline" onclick={() => (isPublic = !isPublic)}>
				<Icon icon={isPublic ? LockSimpleIcon : GlobeSimpleIcon} size={16} />
				{isPublic ? 'Make private' : 'Make public'}
			</button>
		{:else}
			<span></span>
		{/if}
		<button type="button" class="btn-white" disabled={saving} onclick={save}>Save</button>
	</div>
	<p class="mt-3 text-xs font-bold text-white">
		{local
			? 'The picture you choose is copied into Ztunes and stays on this Mac.'
			: 'The picture you choose is also uploaded to your YouTube Music playlist. Make sure you have the right to use it.'}
	</p>
</Modal>
