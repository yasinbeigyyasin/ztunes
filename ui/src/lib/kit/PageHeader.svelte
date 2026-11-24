<script lang="ts">
	/**
	 * Entity page header (playlist / album / artist / podcast / Liked Songs). spec: playlist.md §1,
	 * artist.md §1, liked-songs.md.
	 *
	 * Props
	 *   type: string            label above the title ("Playlist", "Public playlist", "Album", "Single", "Podcast", "Artist")
	 *   title: string           auto-sized 96 → 72 → 48 → 32px (weight 800, no hyphenation, 2 lines max at 32)
	 *   image?: string          cover URL (also the tint source unless `tint` is given)
	 *   imageSnippet?: Snippet  custom cover (Liked Songs gradient, playlist mosaic); fills the square
	 *   round?: boolean         circular cover (artist avatar variant)
	 *   variant?: 'default' | 'artist-hero' | 'hero'   hero = full-bleed `image` behind the text, no
	 *                           cover. 'hero' is Spotify's Made for you header (351px, the playlist's
	 *                           artwork as the backdrop, type + 96px title + description + meta).
	 *   heroPosition?: string   object-position of the hero image (default '50% 20%')
	 *   verified?: boolean      artist: blue seal + "Verified Artist" line instead of `type`
	 *   tint?: string           fixed tint (Liked Songs: LIKED_TINT); else derived from `image`
	 *   tintOut?: Tint          bindable: the tint in use, to feed ActionBar / StickyHeader
	 *   description?: string    14px #b3b3b3, 2 lines (HTML-free)
	 *   owner?: { name: string; image?: string; href?: string; logo?: boolean; noAvatar?: boolean }
	 *                           meta line avatar 24px + bold name; `logo` = Spotless mark (Made for you),
	 *                           `noAvatar` = bold name only (Liked Songs)
	 *   footer?: Snippet        under the meta line (Made for you: "About recommendations")
	 *   details?: string        rest of the meta line, #cdcdcd, joined with " • " (e.g. "2018 • 7 songs, 23 min 43 sec")
	 *   meta?: Snippet          replaces owner/details entirely
	 *   onTitleClick?, onImageClick?   owner editing: image gets the pencil "Choose photo" overlay
 *   maxTitle?: number       largest title step (podcast show/episode pages use 32 even when short)
	 *
	 * Usage
	 *   <PageHeader type="Album" title={a.title} image={a.thumb} owner={{ name: a.artist, image, href }}
	 *     details={`${a.year} • ${n} songs, ${dur}`} bind:tintOut={tint} />
	 */
	import type { Snippet } from 'svelte';
	import Icon from './Icon.svelte';
	import MusicNotesIcon from 'phosphor-svelte/lib/MusicNotesIcon';
	import PencilSimpleIcon from 'phosphor-svelte/lib/PencilSimpleIcon';
	import SealCheckIcon from 'phosphor-svelte/lib/SealCheckIcon';
	import UserIcon from 'phosphor-svelte/lib/UserIcon';
	import Logo from './Logo.svelte';
	import { ArtworkTint, channels, type Tint } from './tint.svelte';

	let {
		type = '',
		title,
		image,
		imageSnippet,
		round = false,
		variant = 'default',
		verified = false,
		tint,
		tintOut = $bindable(),
		description,
		owner,
		details,
		meta,
		footer,
		heroPosition = '50% 20%',
		onTitleClick,
		onImageClick,
		onImageError,
		maxTitle = 96
	}: {
		type?: string;
		title: string;
		image?: string | null;
		imageSnippet?: Snippet;
		round?: boolean;
		variant?: 'default' | 'artist-hero' | 'hero';
		verified?: boolean;
		tint?: string | null;
		tintOut?: Tint;
		description?: string | null;
		owner?: { name: string; image?: string | null; href?: string; logo?: boolean; noAvatar?: boolean } | null;
		details?: string | null;
		meta?: Snippet;
		footer?: Snippet;
		heroPosition?: string;
		onTitleClick?: () => void;
		onImageClick?: () => void;
		/** stream: coverfix — `image` failed to load (the page can swap in a fresh or fallback URL). */
		onImageError?: (src: string) => void;
		maxTitle?: number;
	} = $props();

	const fromArt = new ArtworkTint(() => (tint ? null : image));
	const current: Tint = $derived(
		tint
			? { color: tint, dark: tint, rgb: channels(tint) }
			: { color: fromArt.color, dark: fromArt.dark, rgb: fromArt.rgb }
	);
	$effect(() => {
		tintOut = current;
	});
	// Spotify's meta line ("14 songs, 59 min") is a light tint of the header colour, e.g.
	// rgb(255,190,176) on a red header; neutral headers stay ≈ #cdcdcd.
	const metaColor = $derived(`color-mix(in oklch, ${current.color} 30%, #fff)`);

	// ── Title auto-size: the largest step that fits on one line; 32px wraps to 2 lines max.
	const STEPS = [96, 72, 48, 32];
	let titleEl = $state<HTMLElement | null>(null);
	let size = $state(96);
	function fit() {
		const el = titleEl;
		if (!el) return;
		for (const s of STEPS.filter((x) => x <= maxTitle || x === 32)) {
			el.style.fontSize = `${s}px`;
			el.style.whiteSpace = 'nowrap';
			if (el.scrollWidth <= el.clientWidth + 1 || s === 32) {
				size = s;
				break;
			}
		}
		el.style.whiteSpace = '';
		// Keep the inline size: the template's style attribute is not re-applied when `size` is unchanged.
		el.style.fontSize = `${size}px`;
	}
	$effect(() => {
		void title;
		void maxTitle;
		const el = titleEl;
		if (!el) return;
		fit();
		const ro = new ResizeObserver(() => fit());
		ro.observe(el.parentElement ?? el);
		return () => ro.disconnect();
	});

	// Keyed by URL rather than reset in an effect: a cached image can fire `load` before the
	// reset effect runs, which left it invisible.
	let loadedSrc = $state<string | null | undefined>(null);
	const loaded = $derived(!!image && loadedSrc === image);

	const hero = $derived((variant === 'artist-hero' || variant === 'hero') && !!image);
	const mfyHero = $derived(variant === 'hero');
</script>

{#snippet titleBlock()}
	<span class="text-sm text-white">
		{#if verified}
			<span class="flex items-center gap-2">
				<span class="relative grid place-items-center">
					<span class="absolute size-3 rounded-full bg-white"></span>
					<Icon icon={SealCheckIcon} size={24} fill class="relative text-[#4cb3ff]" />
				</span>
				<span>Verified Artist</span>
			</span>
		{:else}
			{type}
		{/if}
	</span>
	<!-- svelte-ignore a11y_no_noninteractive_element_interactions, a11y_click_events_have_key_events -->
	<h1
		bind:this={titleEl}
		class="w-full overflow-hidden font-title leading-[normal] font-extrabold text-white [hyphens:none] {size ===
		32
			? 'line-clamp-2 [overflow-wrap:anywhere]'
			: 'whitespace-nowrap'} {onTitleClick ? 'cursor-pointer' : ''}"
		style="font-size:{size}px"
		onclick={onTitleClick}
	>
		{title}
	</h1>
	{#if description}
		<p class="line-clamp-2 text-sm text-text-subdued">{description}</p>
	{/if}
	{#if meta}
		<div class="mt-2 flex flex-wrap items-center text-sm" style="color:{metaColor}">{@render meta()}</div>
	{:else if owner || details}
		<div class="mt-2 flex min-w-0 flex-wrap items-center gap-x-1 text-sm" style="color:{metaColor}">
			{#if owner}
				{#if owner.noAvatar}
					<!-- Spotify: bold name only -->
				{:else if owner.logo}
					<Logo size={24} class="mr-1" />
				{:else if owner.image}
					<img src={owner.image} alt="" class="mr-1 size-6 rounded-full object-cover" />
				{:else if (owner.name === 'Spotless' || owner.name === 'Ztunes')}
					<Logo size={24} class="mr-1" />
				{:else}
					<span class="mr-1 grid size-6 shrink-0 place-items-center rounded-full bg-bg-elevated-highlight text-text-subdued" aria-hidden="true">
						<Icon icon={UserIcon} size={14} />
					</span>
				{/if}
				{#if owner.href}
					<a href={owner.href} class="font-bold text-white hover:underline">{owner.name}</a>
				{:else}
					<span class="font-bold text-white">{owner.name}</span>
				{/if}
			{/if}
			{#if details}
				{#if owner}<span aria-hidden="true">•</span>{/if}
				<span class="truncate">{details}</span>
			{/if}
		</div>
	{/if}
	{#if footer}
		<div class="mt-2 flex">{@render footer()}</div>
	{/if}
{/snippet}

{#if hero}
	<header
		class="relative flex w-full items-end overflow-hidden"
		style="height:{mfyHero ? '351px' : 'clamp(340px, 40vh, 500px)'};background-color:{current.dark}"
	>
		<img
			src={image}
			alt=""
			style="object-position:{heroPosition}"
			class="absolute inset-0 size-full object-cover transition-opacity duration-300 {loaded
				? 'opacity-100'
				: 'opacity-0'}"
			onload={() => (loadedSrc = image)}
			onerror={() => image && onImageError?.(image)}
					{@attach (el: HTMLImageElement) => {
						const src = image;
						if (el.complete && el.naturalWidth) loadedSrc = src;
					}}
		/>
		<div
			class="absolute inset-0"
			style="background:{mfyHero
				? 'linear-gradient(rgb(0 0 0 / 0.1), rgb(0 0 0 / 0.5))'
				: 'linear-gradient(transparent 30%, rgb(0 0 0 / 0.55))'}"
		></div>
		<div
			class="relative flex w-full min-w-0 flex-col px-[var(--content-spacing)] {mfyHero ? (footer ? 'pb-5' : 'pb-8') : 'pb-6'}"
		>
			{@render titleBlock()}
		</div>
	</header>
{:else}
	<header
		class="relative flex w-full items-end overflow-hidden"
		style="background-color:{current.dark};background-image:linear-gradient(in oklch, {current.color}, transparent){tint
			? ', linear-gradient(transparent, rgb(0 0 0 / 0.5))'
			: ''};transition:background-color 300ms"
	>
		<div class="noise absolute inset-0"></div>
		<div
			class="relative flex w-full min-w-0 items-end gap-[var(--content-spacing)] px-[var(--content-spacing)] pt-[60px] pb-[var(--content-spacing)]"
		>
			<!-- svelte-ignore a11y_no_static_element_interactions, a11y_click_events_have_key_events -->
			<div
				class="group relative aspect-square shrink-0 self-end overflow-hidden bg-bg-menu shadow-header-cover {round
					? 'rounded-full'
					: 'rounded-sm'} {onImageClick ? 'cursor-pointer' : ''}"
				style="width:clamp(128px, calc(128px + (100cqw - 600px) * 0.2453), 232px)"
				onclick={onImageClick}
			>
				{#if imageSnippet}
					{@render imageSnippet()}
				{:else if image}
					<img
						src={image}
						alt=""
						class="size-full object-cover transition-opacity duration-300 {loaded
							? 'opacity-100'
							: 'opacity-0'}"
						onload={() => (loadedSrc = image)}
						onerror={() => image && onImageError?.(image)}
					{@attach (el: HTMLImageElement) => {
						const src = image;
						if (el.complete && el.naturalWidth) loadedSrc = src;
					}}
					/>
				{:else}
					<div class="grid size-full place-items-center text-text-subdued">
						<Icon icon={MusicNotesIcon} size={64} />
					</div>
				{/if}
				{#if onImageClick}
					<div
						class="absolute inset-0 flex flex-col items-center justify-center gap-2 bg-black/70 text-white opacity-0 transition-opacity duration-100 group-hover:opacity-100"
					>
						<Icon icon={PencilSimpleIcon} size={48} />
						<span class="text-base">Choose photo</span>
					</div>
				{/if}
			</div>
			<div class="flex min-w-0 flex-1 flex-col justify-end">
				{@render titleBlock()}
			</div>
		</div>
	</header>
{/if}
