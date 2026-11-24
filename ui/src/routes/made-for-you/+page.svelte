<script lang="ts">
	/**
	 * Browse ▸ Made for you (stream smart2), Spotify's "Made for you" category page: a 96/800 title
	 * on the plain dark panel (no wash, no kicker), then fixed 4-card grid shelves, in the same order
	 * and with the same titles as the iPhone: "Your Mixes", "Discover new music" (New Release Mix,
	 * Weekly Discoveries), "Unique for you" (Your Rotation, Throwback Mix). Cards open the playlist pages; the accent button plays.
	 * Measured (parity3): title top 123px below the panel top, first shelf heading 325px (h2 box).
	 */
	import { onMount } from 'svelte';
	import * as api from '$lib/api';
	import type { MfyCard } from '$lib/api';
	import { Card, EmptyState, ErrorState, Shelf, Skeleton } from '$lib/kit';
	import { playlistHref } from '$lib/kit/actions';
	import { openItemMenu } from '$lib/kit/menus';
	import { isPlaying, playBrowse, toggle } from '$lib/discover/play.svelte';
	import SparkleIcon from 'phosphor-svelte/lib/SparkleIcon';

	let cards = $state<MfyCard[] | null>(null);
	let error = $state(false);

	async function load() {
		error = false;
		try {
			cards = await api.madeForYou();
		} catch {
			if (!cards) error = true;
		}
	}
	onMount(() => {
		void load();
		let un: (() => void) | undefined;
		void api.onMadeForYouChanged(load).then((u) => (un = u));
		return () => un?.();
	});

	const pick = (kinds: MfyCard['kind'][]) =>
		kinds.flatMap((k) => (cards ?? []).filter((c) => c.kind === k));
	const sections = $derived(
		[
			{ title: 'Your Mixes', items: pick(['daily']) },
			{ title: 'Discover new music', items: pick(['release_radar', 'discover_weekly']) },
			{ title: 'Unique for you', items: pick(['on_repeat', 'repeat_rewind']) }
		].filter((s) => s.items.length)
	);
	const asItem = (c: MfyCard) => ({
		kind: 'playlist' as const,
		id: c.id,
		title: c.title,
		subtitle: c.description,
		thumbnail: c.thumbnail ?? undefined
	});
</script>

<svelte:head><title>Made for you | Ztunes</title></svelte:head>

{#snippet mfyCard(c: MfyCard)}
	<Card
		title={c.title}
		subtitle={c.description}
		image={c.thumbnail}
		kind="playlist"
		href={playlistHref(c.id)}
		playing={isPlaying(c.id)}
		onPlay={() => toggle(c.id, () => playBrowse(asItem(c)))}
		oncontextmenu={(e) => openItemMenu(e, asItem(c))}
	/>
{/snippet}

<div class="relative isolate min-h-full pb-10">
	<header class="px-[var(--content-spacing)] pt-[123px] pb-[101px]">
		<h1 class="font-title text-5xl leading-[1.05] font-extrabold text-white">Made for you</h1>
	</header>
	<div class="flex flex-col gap-8 px-[var(--content-spacing)]">
		{#if error}
			<ErrorState message="Try reloading the page." onRetry={load} />
		{:else if !cards}
			{#each Array(2) as _, s (s)}
				<section aria-hidden="true" class="flex flex-col gap-3">
					<Skeleton width="220px" height={20} />
					<div class="-mx-3 grid grid-cols-5 overflow-hidden"><Skeleton variant="card" count={5} /></div>
				</section>
			{/each}
		{:else if !cards.length}
			<EmptyState
				icon={SparkleIcon}
				title="Your mixes are on their way"
				body="Play some music, like songs or import your Spotify library, and your mixes and Weekly Discoveries appear here."
				class="py-16"
			/>
		{:else}
			{#each sections as sec (sec.title)}
				<Shelf title={sec.title} items={sec.items} mode="fit" minCard={190} rows={Math.ceil(sec.items.length / 4)} key={(c) => c.id}>
					{#snippet card(c)}{@render mfyCard(c)}{/snippet}
				</Shelf>
			{/each}
		{/if}
	</div>
</div>
