<script lang="ts">
	/** Liked Songs artwork (liked-songs.md): purple → mint gradient with a white heart ≈ 40%. */
	import Icon from '$lib/kit/Icon.svelte';
	import HeartIcon from 'phosphor-svelte/lib/HeartIcon';
	let { size = 232 }: { size?: number } = $props();
</script>

<div class="grid size-full place-items-center bg-[linear-gradient(135deg,#ff4b4b,#6a1b9a)] text-white">
	<Icon icon={HeartIcon} size={Math.round(size * 0.4)} fill />
</div>
