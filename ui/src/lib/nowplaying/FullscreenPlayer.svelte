<script lang="ts">
	/**
	 * Spotify full-screen mode (lyrics-and-expanded-player.md "Fullscreen"): the window goes
	 * fullscreen (Rust `theater_fullscreen`, which restores the maximised state on exit), black →
	 * cover-colour gradient (or the music video edge to edge). Top-left Back + "Playing from" + context;
	 * top-right lyrics toggle + exit. Bottom-left cover 120 + title 48/800 + artists 16 + like;
	 * then the progress bar and the full controls row (play 56px), volume at the right.
	 * Lyrics toggle shows the lyrics over the stage. Mouse idle 3s hides the chrome (300ms fade)
	 * while playing; any movement/key shows it. Esc exits. Navigating closes it.
	 */
	import { offersLyrics } from '$lib/nowlyrics.svelte';
	import { appearance } from '$lib/theme.svelte';
	import { onMount } from 'svelte';
	import { trapFocus } from '$lib/kit/focustrap';
	import { beforeNavigate } from '$app/navigation';
	import * as api from '$lib/api';
	import {
		commitVolume,
		cycleRepeat,
		dragVolume,
		playback,
		SKIP_SECS,
		skipBy,
		toggleMute,
		ui
	} from '$lib/player.svelte';
	import { thumb } from '$lib/thumb';
	import Icon from '$lib/kit/Icon.svelte';
	import IconButton from '$lib/kit/IconButton.svelte';
	import Slider from '$lib/kit/Slider.svelte';
	import { nowChapters } from '$lib/chapters.svelte';
	import { isLiked, toggleLike } from '$lib/kit/actions';
	import { nowPlayingSong } from '$lib/shell/nowplaying';
	import { showVideo } from '$lib/video.svelte';
	import { menu } from '$lib/kit/menus';
	import { confirmState } from '$lib/kit/confirm.svelte';
	import LyricLines from './LyricLines.svelte';
	import VideoBox from './VideoBox.svelte';
	import SpeedButton from './SpeedButton.svelte';
	import { LyricsTint } from './palette.svelte';
	import { clock, npui } from './state.svelte';
	import { artistInfo } from './info';
	import ShuffleIcon from 'phosphor-svelte/lib/ShuffleIcon';
	import SkipBackIcon from 'phosphor-svelte/lib/SkipBackIcon';
	import SkipForwardIcon from 'phosphor-svelte/lib/SkipForwardIcon';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import PauseIcon from 'phosphor-svelte/lib/PauseIcon';
	import RepeatIcon from 'phosphor-svelte/lib/RepeatIcon';
	import RepeatOnceIcon from 'phosphor-svelte/lib/RepeatOnceIcon';
	import MicrophoneStageIcon from 'phosphor-svelte/lib/MicrophoneStageIcon';
	import CornersInIcon from 'phosphor-svelte/lib/CornersInIcon';
	import CaretLeftIcon from 'phosphor-svelte/lib/CaretLeftIcon';
	import PlusCircleIcon from 'phosphor-svelte/lib/PlusCircleIcon';
	import CheckCircleIcon from 'phosphor-svelte/lib/CheckCircleIcon';
	import ClockCounterClockwiseIcon from 'phosphor-svelte/lib/ClockCounterClockwiseIcon';
	import ClockClockwiseIcon from 'phosphor-svelte/lib/ClockClockwiseIcon';
	import SpeakerSimpleXIcon from 'phosphor-svelte/lib/SpeakerSimpleXIcon';
	import SpeakerSimpleNoneIcon from 'phosphor-svelte/lib/SpeakerSimpleNoneIcon';
	import SpeakerSimpleLowIcon from 'phosphor-svelte/lib/SpeakerSimpleLowIcon';
	import SpeakerSimpleHighIcon from 'phosphor-svelte/lib/SpeakerSimpleHighIcon';

	const close = () => (ui.theaterOpen = false);
	beforeNavigate(close);

	onMount(() => {
		api.theaterFullscreen(true).catch(() => {
			// Browser preview: fall back to the Fullscreen API.
			document.documentElement.requestFullscreen?.().catch(() => {});
		});
		return () => {
			api.theaterFullscreen(false).catch(() => {
				if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
			});
		};
	});

	const now = $derived(playback.now);
	const song = $derived(now ? nowPlayingSong() : null);
	const liked = $derived(song ? isLiked(song) : false);
	const local = $derived(!!now && api.isLocalId(now.videoId));
	const episode = $derived(!!now?.isEpisode);
	const tint = new LyricsTint(() => thumb(playback.now?.thumbnail, 120));
	const video = $derived(showVideo());

	// Spotify's fullscreen backdrop is the artist's image, edge to edge, fading to black at the
	// bottom; the cover-colour gradient stays underneath (and is all you see without an image).
	const artistId = $derived(
		now && !local && !episode ? (now.artistId ?? now.artistRuns?.find((r) => r.id)?.id) : undefined
	);
	let backdrop = $state<string | null>(null);
	let backdropLoaded = $state<string | null>(null);
	$effect(() => {
		const id = artistId;
		backdrop = null;
		if (!id) return;
		let stale = false;
		artistInfo(id)
			.then((a) => {
				if (!stale) backdrop = thumb(a.thumbnail ?? a.avatar, 1920) ?? null;
			})
			.catch(() => {});
		return () => (stale = true);
	});

	// Idle: hide the chrome after 3s of stillness while playing.
	let idle = $state(false);
	let timer: ReturnType<typeof setTimeout>;
	let lx = NaN;
	let ly = NaN;
	function wake() {
		idle = false;
		clearTimeout(timer);
		timer = setTimeout(() => (idle = true), 3000);
	}
	onMount(() => {
		wake();
		return () => clearTimeout(timer);
	});
	const calm = $derived(idle && !playback.paused);

	function onKey(e: KeyboardEvent) {
		wake();
		// A menu or dialog over the player takes its own Esc (tooltips don't count: bits-ui
		// prevents the default on Esc just to close one).
		if (menu.open || confirmState.pending) return;
		if (e.key === 'Escape') {
			e.preventDefault();
			close();
		}
	}

	// Progress
	let scrub = $state<number | null>(null);
	const speed = $derived(playback.speed || 1);
	const duration = $derived(playback.duration / speed);
	const position = $derived((scrub ?? playback.position) / speed);
	function seekCommit(v: number) {
		const secs = v * speed;
		playback.position = secs;
		scrub = null;
		api.seek(secs);
	}
	const shuffleOn = $derived(playback.queue.shuffle ?? false);
	const repeat = $derived(playback.queue.repeat ?? 'off');
	const vol = $derived(playback.volume);
	const volIcon = $derived(
		vol === 0
			? SpeakerSimpleXIcon
			: vol < 34
				? SpeakerSimpleNoneIcon
				: vol < 67
					? SpeakerSimpleLowIcon
					: SpeakerSimpleHighIcon
	);
	const context = $derived(playback.queue.sourceName ?? now?.album ?? null);
</script>

<svelte:window onkeydown={onKey} />

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="fixed inset-0 z-[45] overflow-hidden bg-black text-white select-none {calm ? 'cursor-none' : ''}"
	role="dialog"
	aria-modal="true"
	{@attach trapFocus()}
	aria-label="Full screen player"
	tabindex="-1"
	onpointermove={(e) => {
		if (e.screenX === lx && e.screenY === ly) return;
		lx = e.screenX;
		ly = e.screenY;
		wake();
	}}
	onpointerdown={wake}
>
	{#if video}
		<VideoBox fit="contain" class="absolute inset-0" />
		<div class="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/80 via-transparent to-black/40"></div>
	{:else}
		<div
			class="absolute inset-0 transition-[background] duration-500"
			style="background:linear-gradient(to bottom,{tint.bg} 0%,{tint.deep} 55%,#000 100%)"
		></div>
		{#if appearance.artworkBackground && backdrop && !npui.fullscreenLyrics}
			<img
				src={backdrop}
				alt=""
				class="absolute inset-0 size-full object-cover object-[50%_20%] transition-opacity duration-500 {backdropLoaded ===
				backdrop
					? 'opacity-100'
					: 'opacity-0'}"
				onload={() => (backdropLoaded = backdrop)}
			/>
			<div class="pointer-events-none absolute inset-0 bg-gradient-to-t from-black/90 via-black/20 to-black/40"></div>
		{/if}
	{/if}

	{#if npui.fullscreenLyrics && offersLyrics(now)}
		<div class="absolute inset-x-0 top-20 bottom-[280px]">
			<LyricLines line={tint.soft} fadeTop fadeBottom />
		</div>
	{/if}

	<!-- Top strip -->
	<div
		class="absolute inset-x-0 top-0 flex items-start justify-between px-16 pt-10 transition-opacity duration-300 {calm
			? 'opacity-0'
			: 'opacity-100'}"
	>
		<div class="flex min-w-0 items-center gap-4">
			<!-- Back: the clear way out, same as the exit button at the right (and Esc). -->
			<IconButton
				icon={CaretLeftIcon}
				label="Back"
				tooltip="Back (Esc)"
				tooltipSide="bottom"
				tone="white"
				onclick={close}
			/>
			{#if context}
				<div class="min-w-0">
					<div class="text-xs font-bold tracking-[0.1em] text-white/70 uppercase">Playing from</div>
					<div class="truncate text-base font-bold">{context}</div>
				</div>
			{/if}
		</div>
		<div class="flex items-center gap-2">
			{#if offersLyrics(now)}
				<IconButton
					icon={MicrophoneStageIcon}
					label={npui.fullscreenLyrics ? 'Hide lyrics' : 'Lyrics'}
					tone="white"
					active={npui.fullscreenLyrics}
					dot
					onclick={() => (npui.fullscreenLyrics = !npui.fullscreenLyrics)}
				/>
			{/if}
			<IconButton icon={CornersInIcon} label="Exit full screen" tone="white" onclick={close} />
		</div>
	</div>

	{#if now}
		<!-- Bottom: what's playing, progress, controls -->
		<div class="absolute inset-x-0 bottom-0 px-16 pb-10">
			<div class="flex items-end gap-6">
				{#if !video && !(npui.fullscreenLyrics && offersLyrics(now))}
					<img
						src={thumb(now.thumbnail, 400)}
						alt=""
						class="size-[120px] shrink-0 rounded-md object-cover shadow-[0_8px_24px_rgba(0,0,0,.5)]"
					/>
				{/if}
				<div class="min-w-0 flex-1 pb-1">
					<div class="truncate text-3xl leading-[1.15] font-extrabold tracking-[-0.04em]">{now.title}</div>
					<div class="mt-2 truncate text-base text-white/70">{now.artists}</div>
				</div>
				{#if song && !local}
					<IconButton
						icon={liked ? CheckCircleIcon : PlusCircleIcon}
						fill={liked}
						active={liked}
						tone="white"
						iconSize={24}
						size="lg"
						label={liked ? 'Remove from Liked Songs' : 'Add to Liked Songs'}
						onclick={() => song && toggleLike(song)}
					/>
				{/if}
			</div>

			<div class="transition-opacity duration-300 {calm ? 'opacity-0' : 'opacity-100'}">
				<div class="mt-6 flex items-center gap-3">
					<span class="min-w-10 text-right text-xs text-white/70 tabular-nums">{clock(position)}</span>
					{#if now.live}
						<div class="flex-1 text-center text-xs font-bold">LIVE</div>
					{:else}
						<Slider
							label="Change progress"
							value={position}
							max={duration || 1}
							step={5}
							tooltip={clock}
							marks={now.isEpisode ? nowChapters.list.map((c) => c.startSecs / speed) : []}
							disabled={!duration}
							oninput={(v) => (scrub = v * speed)}
							onchange={seekCommit}
						/>
					{/if}
					<span class="min-w-10 text-xs text-white/70 tabular-nums">{clock(duration)}</span>
				</div>
				<div class="mt-4 grid grid-cols-[1fr_auto_1fr] items-center">
					<div></div>
					<div class="flex items-center gap-6">
						{#if episode}
							<SpeedButton />
							<IconButton icon={ClockCounterClockwiseIcon} tone="white" label="Back {SKIP_SECS} seconds" iconSize={24} size="lg" onclick={() => skipBy(-SKIP_SECS)} />
						{:else}
							<IconButton
								icon={ShuffleIcon}
								tone="white"
								label={shuffleOn ? 'Disable shuffle' : 'Enable shuffle'}
								active={shuffleOn}
								dot
								iconSize={24}
								size="lg"
								onclick={() => api.toggleShuffle()}
							/>
							<IconButton icon={SkipBackIcon} fill tone="white" label="Previous" iconSize={24} size="lg" onclick={() => api.prevTrack()} />
						{/if}
						<button
							type="button"
							aria-label={playback.now?.loading ? 'Loading' : playback.paused ? 'Play' : 'Pause'}
							class="grid size-14 place-items-center rounded-full bg-white text-black transition-transform hover:scale-[1.04] active:scale-100 active:opacity-70"
							onclick={() => api.togglePause()}
						>
							{#if playback.now?.loading}
								<span class="size-6 animate-spin rounded-full border-2 border-black/25 border-t-black" data-loading></span>
							{:else}
								<Icon icon={playback.paused ? PlayIcon : PauseIcon} size={24} fill />
							{/if}
						</button>
						{#if episode}
							<IconButton icon={ClockClockwiseIcon} tone="white" label="Forward {SKIP_SECS} seconds" iconSize={24} size="lg" onclick={() => skipBy(SKIP_SECS)} />
							<IconButton icon={SkipForwardIcon} fill tone="white" label="Next" iconSize={24} size="lg" onclick={() => api.nextTrack()} />
						{:else}
							<IconButton icon={SkipForwardIcon} fill tone="white" label="Next" iconSize={24} size="lg" onclick={() => api.nextTrack()} />
							<IconButton
								icon={repeat === 'one' ? RepeatOnceIcon : RepeatIcon}
								tone="white"
								label={repeat === 'off' ? 'Enable repeat' : repeat === 'all' ? 'Enable repeat one' : 'Disable repeat'}
								active={repeat !== 'off'}
								dot
								iconSize={24}
								size="lg"
								onclick={() => cycleRepeat()}
							/>
						{/if}
					</div>
					<div class="flex items-center justify-end gap-1">
						<IconButton icon={volIcon} tone="white" label={vol === 0 ? 'Unmute' : 'Mute'} onclick={toggleMute} />
						<div class="w-[120px]">
							<Slider label="Change volume" valuetext={(v) => `${Math.round(v)}%`} value={vol} max={100} step={10} oninput={dragVolume} onchange={commitVolume} />
						</div>
					</div>
				</div>
			</div>
		</div>
	{/if}
</div>
