<script lang="ts">
	// The whole UI of the mini-player window (Rust `mini.rs`, always on top, undecorated). Same SPA
	// as the main window; the root layout renders only this when the window label is `mini`.
	//
	// Spotify's miniplayer (lyrics-and-expanded-player.md "Mini player"), restyled by stream
	// p-nowplaying:
	//  - square (300x300): the cover full-bleed; on hover a dark scrim with the controls centred
	//    (previous · play 48px · next), title/artists + like at the bottom, the progress bar, and
	//    window buttons at the top (switch to bar, close back to Ztunes);
	//  - bar (400x100): cover left, title/artists, like, previous · play · next, the square toggle.
	// #121212, radius 8. The layout follows the window's shape; Rust sizes the window.
	// `data-tauri-drag-region="deep"` makes every non-control part a drag handle.
	import * as api from '$lib/api';
	import {
		playback,
		SKIP_SECS,
		skipBy,
		toggleNowPlayingRating
	} from '$lib/player.svelte';
	import { thumb } from '$lib/thumb';
	import Icon from '$lib/kit/Icon.svelte';
	import SkipBackIcon from 'phosphor-svelte/lib/SkipBackIcon';
	import SkipForwardIcon from 'phosphor-svelte/lib/SkipForwardIcon';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import PauseIcon from 'phosphor-svelte/lib/PauseIcon';
	import PlusCircleIcon from 'phosphor-svelte/lib/PlusCircleIcon';
	import CheckCircleIcon from 'phosphor-svelte/lib/CheckCircleIcon';
	import XIcon from 'phosphor-svelte/lib/XIcon';
	import RowsIcon from 'phosphor-svelte/lib/RowsIcon';
	import SquareIcon from 'phosphor-svelte/lib/SquareIcon';
	import ClockCounterClockwiseIcon from 'phosphor-svelte/lib/ClockCounterClockwiseIcon';
	import ClockClockwiseIcon from 'phosphor-svelte/lib/ClockClockwiseIcon';
	import MusicNotesIcon from 'phosphor-svelte/lib/MusicNotesIcon';

	let width = $state(typeof window === 'undefined' ? 300 : window.innerWidth);
	let height = $state(typeof window === 'undefined' ? 300 : window.innerHeight);
	const bar = $derived(width > height * 2);

	const now = $derived(playback.now);
	const episode = $derived(!!now?.isEpisode);
	const likeable = $derived(!!now && !api.isLocalId(now.videoId));
	const liked = $derived(playback.rating === 'like');
	const progress = $derived(
		playback.duration ? Math.min(1, Math.max(0, playback.position / playback.duration)) : 0
	);
	const setBar = (on: boolean) => api.setMiniCompact(on).catch(() => {});
	const back = () => api.closeMini().catch(() => {});

	// Seek on the bottom bar: click / drag along it.
	let bar_el = $state<HTMLElement>();
	let drag = $state<number | null>(null);
	function at(e: PointerEvent) {
		const r = bar_el!.getBoundingClientRect();
		return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width));
	}
	function down(e: PointerEvent) {
		if (!playback.duration || now?.live) return;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		drag = at(e);
	}
	function move(e: PointerEvent) {
		if (drag !== null) drag = at(e);
	}
	function up() {
		if (drag === null) return;
		const secs = drag * playback.duration;
		playback.position = secs;
		drag = null;
		api.seek(secs);
	}
	const shown = $derived(drag ?? progress);

	const base =
		'grid size-8 shrink-0 place-items-center rounded-full transition-[color,transform] hover:scale-[1.04] active:scale-100';
	const btn = `${base} text-white/80 hover:text-white`;
</script>

<svelte:window bind:innerWidth={width} bind:innerHeight={height} />

{#snippet transport(big: boolean)}
	<div class="flex items-center {big ? 'gap-6' : 'gap-2'}">
		{#if episode}
			<button class={btn} aria-label="Back {SKIP_SECS} seconds" onclick={() => skipBy(-SKIP_SECS)}>
				<Icon icon={ClockCounterClockwiseIcon} size={big ? 20 : 16} />
			</button>
		{:else}
			<button class={btn} aria-label="Previous" onclick={() => api.prevTrack()}>
				<Icon icon={SkipBackIcon} size={big ? 20 : 16} fill />
			</button>
		{/if}
		<button
			class="grid {big ? 'size-12' : 'size-8'} place-items-center rounded-full bg-white text-black transition-transform hover:scale-[1.04] active:scale-100 active:opacity-70"
			aria-label={playback.now?.loading ? 'Loading' : playback.paused ? 'Play' : 'Pause'}
			onclick={() => api.togglePause()}
		>
			{#if playback.now?.loading}
				<span class="{big ? 'size-5' : 'size-4'} animate-spin rounded-full border-2 border-black/25 border-t-black" data-loading></span>
			{:else}
				<Icon icon={playback.paused ? PlayIcon : PauseIcon} size={big ? 20 : 16} fill />
			{/if}
		</button>
		{#if episode}
			<button class={btn} aria-label="Forward {SKIP_SECS} seconds" onclick={() => skipBy(SKIP_SECS)}>
				<Icon icon={ClockClockwiseIcon} size={big ? 20 : 16} />
			</button>
		{:else}
			<button class={btn} aria-label="Next" onclick={() => api.nextTrack()}>
				<Icon icon={SkipForwardIcon} size={big ? 20 : 16} fill />
			</button>
		{/if}
	</div>
{/snippet}

{#snippet like()}
	{#if likeable}
		<button
			class="{base} {liked ? 'text-accent' : 'text-white/80 hover:text-white'}"
			aria-label={liked ? 'Remove from Liked Songs' : 'Add to Liked Songs'}
			onclick={() => toggleNowPlayingRating()}
		>
			<Icon icon={liked ? CheckCircleIcon : PlusCircleIcon} size={16} fill={liked} />
		</button>
	{/if}
{/snippet}

{#snippet seekbar(cls: string)}
	<div
		bind:this={bar_el}
		class="group/seek relative flex h-3 cursor-pointer items-center {cls}"
		role="slider"
		tabindex="-1"
		aria-label="Change progress"
		aria-valuemin={0}
		aria-valuemax={100}
		aria-valuenow={Math.round(shown * 100)}
		onpointerdown={down}
		onpointermove={move}
		onpointerup={up}
	>
		<div class="h-1 w-full overflow-hidden rounded-full bg-white/30">
			<div class="h-full rounded-full bg-white group-hover/seek:bg-accent" style="width:{shown * 100}%"></div>
		</div>
	</div>
{/snippet}

<div
	data-tauri-drag-region="deep"
	class="group relative h-screen w-screen overflow-hidden rounded-lg bg-bg-base text-white select-none"
>
	{#if !now}
		<div class="flex h-full flex-col items-center justify-center gap-2 p-4 text-center">
			<Icon icon={MusicNotesIcon} size={32} class="text-text-subdued" />
			<p class="text-sm text-text-subdued">Nothing playing</p>
			<button class="text-sm font-bold hover:underline" onclick={back}>Back to Ztunes</button>
		</div>
	{:else if bar}
		<div class="flex h-full items-center gap-3 pr-3">
			<div class="aspect-square h-full shrink-0 bg-bg-menu">
				{#if now.thumbnail}<img src={thumb(now.thumbnail, 200)} alt="" class="size-full object-cover" />{/if}
			</div>
			<div class="min-w-0 flex-1">
				<div class="truncate text-sm font-bold">{now.title}</div>
				<div class="truncate text-xs text-text-subdued">{now.artists}</div>
			</div>
			{@render like()}
			{@render transport(false)}
			<div class="flex flex-col">
				<button class={btn} aria-label="Square miniplayer" title="Square miniplayer" onclick={() => setBar(false)}>
					<Icon icon={SquareIcon} size={14} />
				</button>
			</div>
		</div>
		<button
			class="absolute top-1 right-1 grid size-6 place-items-center rounded-full bg-black/60 text-white/80 opacity-0 group-hover:opacity-100 hover:text-white"
			aria-label="Close miniplayer"
			onclick={back}
		>
			<Icon icon={XIcon} size={12} />
		</button>
		<div class="absolute inset-x-0 bottom-0 h-0.5 bg-white/20">
			<div class="h-full bg-white" style="width:{progress * 100}%"></div>
		</div>
	{:else}
		{#if now.thumbnail}
			<img src={thumb(now.thumbnail, 600)} alt="" class="absolute inset-0 size-full object-cover" />
		{:else}
			<div class="absolute inset-0 grid place-items-center bg-bg-menu text-text-subdued">
				<Icon icon={MusicNotesIcon} size={64} />
			</div>
		{/if}
		<!-- Resting: a thin progress line along the bottom edge. -->
		<div class="absolute inset-x-0 bottom-0 h-0.5 bg-white/20 transition-opacity group-hover:opacity-0">
			<div class="h-full bg-white" style="width:{progress * 100}%"></div>
		</div>
		<!-- Hover: scrim + controls -->
		<div
			class="absolute inset-0 flex flex-col bg-gradient-to-b from-black/60 via-black/50 to-black/80 opacity-0 transition-opacity duration-200 group-hover:opacity-100"
		>
			<div class="flex items-center justify-between p-2">
				<button class={btn} aria-label="Bar miniplayer" title="Bar miniplayer" onclick={() => setBar(true)}>
					<Icon icon={RowsIcon} size={16} />
				</button>
				<button class={btn} aria-label="Close miniplayer" title="Back to Ztunes" onclick={back}>
					<Icon icon={XIcon} size={16} />
				</button>
			</div>
			<div class="flex flex-1 items-center justify-center">{@render transport(true)}</div>
			<div class="px-4 pb-3">
				<div class="flex items-center gap-2">
					<div class="min-w-0 flex-1">
						<div class="truncate text-base font-bold">{now.title}</div>
						<div class="truncate text-sm text-white/70">{now.artists}</div>
					</div>
					{@render like()}
				</div>
				{@render seekbar('mt-2')}
			</div>
		</div>
	{/if}
</div>
