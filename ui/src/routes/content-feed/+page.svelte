<script lang="ts">
	/**
	 * What's New (stream smart2), Spotify's `/content-feed`: the newest releases of artists you
	 * follow and episodes of podcasts you follow. Title, one-line description, Music / Podcasts &
	 * Shows chips, then "New" (since your last visit, blue dot) and "Earlier". Opening the page
	 * marks everything seen, which clears the bell's dot.
	 */
	import { onMount } from 'svelte';
	import * as api from '$lib/api';
	import type { WhatsNew } from '$lib/api';
	import { EmptyState, ErrorState, FilterChips, Skeleton } from '$lib/kit';
	import EpisodeRow from '$lib/discover/EpisodeRow.svelte';
	import ReleaseRow from '$lib/smart/ReleaseRow.svelte';
	import { feed, type FeedFilter } from '$lib/smart/whatsnew';
	import { bell } from '$lib/smart/bell.svelte';
	import BellIcon from 'phosphor-svelte/lib/BellIcon';

	let data = $state<WhatsNew | null>(null);
	let error = $state(false);
	let filter = $state<FeedFilter | null>(null);

	async function load(refresh = false) {
		error = false;
		try {
			data = await api.whatsNew(refresh);
			await api.whatsNewMarkSeen();
			bell.count = 0;
		} catch {
			if (!data) error = true;
		}
	}
	onMount(() => {
		void load();
		// A scan may still be running from launch; pick its results up when it lands.
		let un: (() => void) | undefined;
		// (Our own mark-seen fires it with 0; keep this visit's "New" group until the next visit.)
		void api.onWhatsNewChanged((n) => n > 0 && load()).then((u) => (un = u));
		return () => un?.();
	});

	const groups = $derived(feed(data, filter));
	const empty = $derived(!!data && !groups.fresh.length && !groups.earlier.length);
</script>

<svelte:head><title>What's New | Ztunes</title></svelte:head>

<div class="wn px-[var(--content-spacing)] pt-16 pb-10">
	<h1 class="text-2xl font-bold text-white">What's New</h1>
	<p class="mt-2 text-sm text-text-subdued">The latest releases from artists, podcasts, and shows you follow.</p>
	<FilterChips
		class="mt-6"
		options={[
			{ id: 'music', label: 'Music' },
			{ id: 'podcasts', label: 'Podcast & Shows' }
		]}
		bind:value={filter}
	/>

	{#if error}
		<div class="pt-16"><ErrorState message="Check your connection and try again." onRetry={() => load(true)} /></div>
	{:else if !data}
		<div class="mt-10"><Skeleton variant="row" count={6} /></div>
	{:else if empty}
		<EmptyState
			icon={BellIcon}
			title="We don't have any updates for you yet"
			body="Follow artists and podcasts you like to hear about their new releases here."
			class="py-16"
		/>
	{:else}
		{#each [{ title: 'New', items: groups.fresh }, { title: 'Earlier', items: groups.earlier }] as g (g.title)}
			{#if g.items.length}
				<h2 class="mt-10 flex h-[41px] items-center text-xl font-bold text-white">{g.title}</h2>
				<div class="divide-y divide-white/10 border-t border-white/10">
					{#each g.items as it (it.key)}
						<!-- leftovers: release rows carry Spotify's own 16px padding (rows ~200px). -->
						<div class={it.kind === 'release' ? '' : 'py-2'}>
							{#if it.kind === 'release'}
								<ReleaseRow release={it.release} />
							{:else}
								<EpisodeRow episode={it.episode} />
							{/if}
						</div>
					{/each}
				</div>
			{/if}
		{/each}
	{/if}
</div>

<style>
	/* parity3: Spotify's What's New chips are #b3b3b3 at rest */
	.wn :global(.chip:not([aria-checked='true'], [aria-pressed='true'])) {
		color: var(--color-text-subdued);
	}
</style>
