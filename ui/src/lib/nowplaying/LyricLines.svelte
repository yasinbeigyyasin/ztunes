<script lang="ts">
	/**
	 * Spotify's full lyrics (lyrics-and-expanded-player.md): 48px/700 lines, left aligned with 64px
	 * side padding, wrap at ~963px, pitch 82px (58 line + 24 gap). Past lines = white at .6,
	 * current = white, upcoming = the palette's dark line colour; colour/opacity transition 100ms ease-out. Hover a
	 * line → white; click → seek to its cue. The current line is kept ~40% down the view with a
	 * smooth scroll; a manual scroll (wheel, touch, keys, scrollbar) pauses the follow for 3s.
	 * Word-timed lyrics light word by word on the current line (Limusic's sync data).
	 * States: loading bars, unsynced (all white + note), instrumental, none, error + retry.
	 *
	 * Props: `line` (the tint colour), `fadeTop` (mask the lines under an overlaid toolbar),
	 * `compact` (fullscreen side column: 32px lines, 32px padding).
	 */
	import * as api from '$lib/api';
	import { playback } from '$lib/player.svelte';
	import { lyr, ensureLyrics, retryLyrics, activeLine, attribution } from './lyrics.svelte';
	import { PlayClock } from './state.svelte';

	let {
		line: lineColour,
		fadeTop = false,
		fadeBottom = false,
		compact = false
	}: { line: string; fadeTop?: boolean; fadeBottom?: boolean; compact?: boolean } = $props();
	const mask = $derived(
		fadeTop || fadeBottom
			? `linear-gradient(to bottom,${fadeTop ? 'transparent 0,#000 104px' : '#000 0'},${fadeBottom ? '#000 calc(100% - 96px),transparent 100%' : '#000 100%'})`
			: ''
	);

	$effect(() => {
		playback.now?.videoId;
		ensureLyrics();
	});

	const lyrics = $derived(lyr.id === playback.now?.videoId ? lyr.lyrics : null);
	const status = $derived(lyr.id === playback.now?.videoId ? lyr.status : 'loading');
	const synced = $derived(!!lyrics?.synced && !lyrics.instrumental);
	const offset = $derived(lyrics?.offset_ms ?? 0);
	const wordTimed = $derived(synced && !!lyrics?.lines.some((l) => (l.words?.length ?? 0) > 0));

	const clock = new PlayClock(() => wordTimed);
	const posMs = $derived(clock.secs * 1000 - offset);
	const active = $derived(synced && lyrics ? activeLine(lyrics.lines, posMs) : -1);

	let scroller = $state<HTMLElement>();
	let userUntil = 0;
	let glided = false;
	const pause = () => (userUntil = Date.now() + 3000);

	// New lyrics (track change, source change): jump, don't glide.
	$effect(() => {
		lyrics;
		glided = false;
		userUntil = 0;
		scroller?.scrollTo({ top: 0, behavior: 'instant' });
	});

	$effect(() => {
		const i = active;
		const box = scroller;
		if (i < 0 || !box || Date.now() < userUntil) return;
		const el = box.querySelector<HTMLElement>(`[data-line="${i}"]`);
		if (!el) return;
		const r = el.getBoundingClientRect();
		const b = box.getBoundingClientRect();
		box.scrollTo({
			top: box.scrollTop + (r.top - b.top) - b.height * 0.4 + r.height / 2,
			behavior: glided ? 'smooth' : 'instant'
		});
		glided = true;
	});

	function seek(l: api.LyricLine) {
		if (!synced || l.time_ms === undefined) return;
		const secs = Math.max(0, (l.time_ms + offset) / 1000);
		playback.position = secs;
		userUntil = 0;
		api.seek(secs);
	}

	function onKey(e: KeyboardEvent) {
		if (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End'].includes(e.key)) pause();
	}

	const size = $derived(
		compact
			? 'text-[32px] leading-[40px] tracking-[-0.01em]'
			: 'text-[48px] leading-[58px] tracking-[-0.02em]'
	);
	// Full-width view: Spotify's lines start at x 186 of a 1395px window (12.9% of the view). parity3
	const pad = $derived(compact ? 'px-8' : 'pr-16 pl-[max(64px,12.9%)]');
</script>

<!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_static_element_interactions -- the scroller takes arrow keys -->
<div
	bind:this={scroller}
	class="scroll-area h-full overflow-y-auto {pad}"
	style={mask ? `mask-image:${mask};-webkit-mask-image:${mask}` : ''}
	tabindex="0"
	onwheel={pause}
	ontouchmove={pause}
	onkeydown={onKey}
	onpointerdown={(e) => {
		// The scrollbar: a press on the scroller itself, not on a line.
		if (e.target === scroller) pause();
	}}
>
	{#if status === 'loading'}
		<div class="flex max-w-[963px] flex-col gap-6 pt-24" aria-busy="true" aria-label="Loading lyrics">
			{#each [72, 58, 84, 64, 76, 52] as w, i (i)}
				<div
					class="h-11 animate-pulse rounded-lg"
					style="width:{w}%;background:{lineColour};opacity:.18"
				></div>
			{/each}
		</div>
	{:else if status === 'error'}
		<div class="flex h-full flex-col items-center justify-center gap-4 text-center">
			<p class="text-2xl font-bold text-white">Couldn't load the lyrics</p>
			<p class="text-base" style="color:{lineColour}">Check your connection and try again.</p>
			<button
				type="button"
				class="h-8 rounded-full bg-white px-4 text-sm font-bold text-black transition-transform hover:scale-[1.04] active:scale-100"
				onclick={retryLyrics}>Try again</button
			>
		</div>
	{:else if !lyrics || lyrics.instrumental || !lyrics.lines.some((l) => l.text.trim())}
		<div class="flex h-full items-center justify-center px-4 text-center">
			<p class="max-w-[600px] text-2xl font-bold text-white">
				{lyrics?.instrumental
					? 'Looks like this one is an instrumental. Enjoy the music.'
					: "Hmm. We don't know the lyrics for this one."}
			</p>
		</div>
	{:else}
		<div class="zt-lyrics max-w-[963px] pt-24 pb-[50vh] font-bold {size}">
			{#if !synced}
				<p class="mb-8 text-base font-normal tracking-normal" style="color:{lineColour}">
					These lyrics aren't synced to the song yet.
				</p>
			{/if}
			{#each lyrics.lines as l, i (i)}
				{@const isActive = i === active}
				{@const isPast = synced && active >= 0 && i < active}
				{#if synced}
					<button
						type="button"
						data-line={i}
                        dir="auto"
						class="block w-full py-3 text-start transition-[color,opacity] duration-100 ease-out hover:!text-white hover:!opacity-100 {l.text.trim()
							? ''
							: 'h-[82px]'}"
						style="color:{isActive || isPast ? '#fff' : lineColour};opacity:{isPast ? 0.6 : 1}"
						onclick={() => seek(l)}
					>
						{#if isActive && l.words?.length}
							{#each l.words as w, k (k)}<span
									class="transition-colors duration-100"
									style="color:{posMs >= w.start_ms ? '#fff' : lineColour}">{w.text}</span
								>{/each}
						{:else}
							{l.text.trim() || '♪'}
						{/if}
					</button>
				{:else}
					<p dir="auto" class="py-3 text-start text-white">{l.text || ' '}</p>
				{/if}
			{/each}
			<p class="mt-10 text-xs font-normal tracking-normal text-text-subdued">{attribution(lyrics)}</p>
		</div>
	{/if}
</div>
