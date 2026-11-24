<script lang="ts">
	import * as api from '$lib/api';
	import { playback, toggleNowPlayingRating, ui } from '$lib/player.svelte';
	import { thumb } from '$lib/thumb';
	import Icon from '$lib/kit/Icon.svelte';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import PauseIcon from 'phosphor-svelte/lib/PauseIcon';
	import PlusCircleIcon from 'phosphor-svelte/lib/PlusCircleIcon';
	import CheckCircleIcon from 'phosphor-svelte/lib/CheckCircleIcon';

	const now = $derived(playback.now);
	const liked = $derived(playback.rating === 'like');
	const likeable = $derived(!!now && !api.isLocalId(now.videoId));
	const progress = $derived(
		playback.duration > 0 ? Math.min(1, Math.max(0, playback.position / playback.duration)) : 0
	);
	const openPlayer = () => (ui.theaterOpen = true);
</script>

{#if now}
	<aside class="android-mini-player" aria-label="Now playing">
		<button class="android-mini-art" type="button" aria-label="Open player" onclick={openPlayer}>
			{#if now.thumbnail}<img src={thumb(now.thumbnail, 120)} alt="" />{:else}<span>♪</span>{/if}
		</button>
		<button class="android-mini-meta" type="button" aria-label="Open player" onclick={openPlayer}>
			<strong>{now.title}</strong>
			<span>{now.artists}</span>
		</button>
		{#if likeable}
			<button class="android-mini-control" type="button" aria-label={liked ? 'Unlike' : 'Like'} onclick={() => toggleNowPlayingRating()}>
				<Icon icon={liked ? CheckCircleIcon : PlusCircleIcon} size={22} fill={liked} />
			</button>
		{/if}
		<button class="android-mini-control" type="button" aria-label={playback.paused ? 'Play' : 'Pause'} onclick={() => api.togglePause()}>
			{#if now.loading}
				<span class="android-spinner" aria-hidden="true"></span>
			{:else}
				<Icon icon={playback.paused ? PlayIcon : PauseIcon} size={23} fill />
			{/if}
		</button>
		<div class="android-mini-progress" aria-hidden="true"><span style="width:{progress * 100}%"></span></div>
	</aside>
{/if}
