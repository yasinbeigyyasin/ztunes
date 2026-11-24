<script lang="ts">
	/**
	 * Now Playing "Lyrics preview" card (now-playing-panel.md §3): track lyrics colour, radius 8,
	 * padding 16, gap 16, ≈177px tall. Heading 16/700 white; lines 24/700 in the light tint of the
	 * hue (a11y stream: measured live on open.spotify.com, e.g. #ffbdbc lines on a #650011 card —
	 * the old dark line colour was 1.7:1), the current line white, bottom fade. Hover → "Show lyrics" white pill bottom-right. Click opens
	 * the full lyrics view. Hidden when the song has no (non-instrumental) lyrics. A Share button
	 * sits at the top-right, as on the iPhone's lyrics card: the song's share dialog.
	 */
	import * as api from '$lib/api';
	import { openShare, playback } from '$lib/player.svelte';
	import Icon from '$lib/kit/Icon.svelte';
	import ExportIcon from 'phosphor-svelte/lib/ExportIcon';
	import { thumb } from '$lib/thumb';
	import { lyr, ensureLyrics, activeLine } from './lyrics.svelte';
	import { LyricsTint } from './palette.svelte';
	import { openExpanded } from './state.svelte';

	const tint = new LyricsTint(() => thumb(playback.now?.thumbnail, 120));

	$effect(() => {
		playback.now?.videoId;
		ensureLyrics();
	});

	const lyrics = $derived(
		lyr.id === playback.now?.videoId && lyr.status === 'ready' ? lyr.lyrics : null
	);
	const usable = $derived(
		!!lyrics && !lyrics.instrumental && lyrics.lines.some((l) => l.text.trim())
	);
	const active = $derived(
		lyrics?.synced
			? activeLine(lyrics.lines, playback.position * 1000 - (lyrics.offset_ms ?? 0))
			: -1
	);
	function share(e: MouseEvent) {
		e.stopPropagation();
		const n = playback.now;
		if (!n) return;
		openShare({ kind: 'song', id: n.videoId, title: n.title, subtitle: n.artists, thumbnail: n.thumbnail });
	}

	/** The current line and what follows (or the opening lines before the first cue). */
	const shown = $derived.by(() => {
		if (!lyrics) return [];
		const out: { text: string; current: boolean }[] = [];
		for (let i = Math.max(0, active); i < lyrics.lines.length && out.length < 4; i++) {
			const text = lyrics.lines[i].text.trim();
			// Unsynced lyrics: every line white, nothing highlighted (as in the full view).
			if (text) out.push({ text, current: !lyrics.synced || i === active });
		}
		return out;
	});
</script>

{#if usable}
	<div
		role="button"
		tabindex="0"
		class="group/lyr relative flex h-[177px] cursor-pointer flex-col gap-4 overflow-hidden rounded-lg p-4 transition-colors duration-300"
		style="background-color:{tint.bg}"
		onclick={() => openExpanded('lyrics')}
		onkeydown={(e) => (e.key === 'Enter' || e.key === ' ') && (e.preventDefault(), openExpanded('lyrics'))}
	>
		<div class="flex shrink-0 items-center justify-between gap-2">
			<h3 class="text-base font-bold text-white">Lyrics preview</h3>
			{#if playback.now && !api.isLocalId(playback.now.videoId)}
				<button
					type="button"
					aria-label="Share lyrics"
					class="-my-1 grid size-8 place-items-center rounded-full bg-black/30 text-white transition-transform hover:scale-[1.04]"
					onclick={share}
					onkeydown={(e) => e.stopPropagation()}
				>
					<Icon icon={ExportIcon} size={16} />
				</button>
			{/if}
		</div>
		<!-- a11y: the scrolling preview lines are decorative here (they change every few seconds);
		     the button opens the full, readable lyrics view. Its name comes from the visible
		     heading + pill: "Lyrics preview Show lyrics". -->
		<div
			aria-hidden="true"
			class="zt-lyrics min-h-0 flex-1 overflow-hidden text-xl leading-8 font-bold tracking-[-0.01em]"
			style="mask-image:linear-gradient(to bottom,#000 55%,transparent);-webkit-mask-image:linear-gradient(to bottom,#000 55%,transparent)"
		>
			{#each shown as l, i (i)}
				<p dir="auto" class="text-start transition-colors duration-100" style="color:{l.current ? '#fff' : tint.soft}">
					{l.text}
				</p>
			{/each}
		</div>
		<span
			class="absolute right-4 bottom-4 grid h-8 place-items-center rounded-full bg-white px-4 text-sm font-bold text-black opacity-0 transition-[opacity,transform] duration-200 group-hover/lyr:opacity-100 hover:scale-[1.04] group-focus-visible/lyr:opacity-100"
		>
			Show lyrics
		</span>
	</div>
{/if}
