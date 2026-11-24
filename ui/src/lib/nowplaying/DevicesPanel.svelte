<script lang="ts">
	/**
	 * Connect view of the right panel (audit 15-lyrics-and-connect.jpg): the device playing now in a
	 * highlighted card (accent icon + name, "Ztunes" with the equaliser), then "Select another
	 * output" with every output device mpv reports (`audio_devices`), 56px rows; a click switches
	 * output (`set_audio_device`). `auto` follows the macOS default output. Refreshes on open and
	 * when devices come and go (audio store events). The device being switched to shows a spinner.
	 */
	import { onMount } from 'svelte';
	import { audio, pickDevice, refreshDevices } from '$lib/audio.svelte';
	import { playback } from '$lib/player.svelte';
	import Icon from '$lib/kit/Icon.svelte';
	import Equalizer from '$lib/kit/Equalizer.svelte';
	import { toast } from '$lib/kit/toast';
	import LaptopIcon from 'phosphor-svelte/lib/LaptopIcon';
	import SpeakerHifiIcon from 'phosphor-svelte/lib/SpeakerHifiIcon';
	import HeadphonesIcon from 'phosphor-svelte/lib/HeadphonesIcon';
	import TelevisionIcon from 'phosphor-svelte/lib/TelevisionIcon';
	import BluetoothConnectedIcon from 'phosphor-svelte/lib/BluetoothConnectedIcon';

	let loading = $state(true);
	let failed = $state(false);
	let switching = $state<string | null>(null);

	onMount(() => {
		refreshDevices()
			.catch(() => (failed = true))
			.finally(() => (loading = false));
	});

	const list = $derived(audio.devices.devices.filter((d) => d.name !== 'auto'));
	const active = $derived(audio.devices.active || 'auto');
	const selected = $derived(audio.devices.selected || 'auto');
	const nameOf = (id: string) =>
		id === 'auto' ? 'This Mac' : (list.find((d) => d.name === id)?.description ?? id);
	const currentSub = $derived(
		selected === 'auto'
			? 'Ztunes · System output'
			: active !== selected
				? `Ztunes · ${nameOf(selected)} unavailable, using system output`
				: 'Ztunes'
	);
	const others = $derived([
		...(selected !== 'auto' ? [{ name: 'auto', description: 'This Mac (system output)' }] : []),
		...list.filter((d) => d.name !== selected)
	]);

	function iconFor(desc: string) {
		const d = desc.toLowerCase();
		if (d.includes('airpods') || d.includes('headphone') || d.includes('buds')) return HeadphonesIcon;
		if (d.includes('bluetooth')) return BluetoothConnectedIcon;
		if (d.includes('tv') || d.includes('hdmi') || d.includes('display') || d.includes('airplay'))
			return TelevisionIcon;
		if (d.includes('macbook') || d.includes('built-in') || d.includes('internal')) return LaptopIcon;
		return SpeakerHifiIcon;
	}

	async function pick(id: string) {
		switching = id;
		try {
			await pickDevice(id);
		} catch (e) {
			toast.error(`Couldn't switch output: ${e}`);
		} finally {
			switching = null;
		}
	}
</script>

<div class="px-2 pb-4">
	<div class="flex items-center gap-4 rounded-md bg-bg-highlight px-4 py-4">
		<Icon icon={selected === 'auto' ? LaptopIcon : iconFor(nameOf(selected))} size={32} class="shrink-0 text-accent" />
		<div class="min-w-0">
			<div class="text-sm font-bold text-white">Current device</div>
			<div class="truncate text-base font-bold text-accent-text">{nameOf(selected)}</div>
			<div class="flex items-center gap-2 text-sm text-text-subdued">
				{#if playback.now}<Equalizer size={12} playing={!playback.paused} />{/if}
				<span class="truncate">{currentSub}</span>
			</div>
		</div>
	</div>

	<h3 class="px-2 pt-8 pb-2 text-base font-bold text-white">Select another output</h3>
	{#if loading && !list.length}
		{#each [0, 1, 2] as i (i)}
			<div class="flex h-14 items-center gap-4 px-2">
				<div class="size-6 animate-pulse rounded bg-white/10"></div>
				<div class="h-3 animate-pulse rounded-full bg-white/10" style="width:{50 - i * 10}%"></div>
			</div>
		{/each}
	{:else if failed && !list.length}
		<p class="px-2 text-sm text-text-subdued">
			Couldn't list the output devices.
			<button type="button" class="font-bold text-white hover:underline" onclick={() => refreshDevices().then(() => (failed = false)).catch(() => {})}
				>Try again</button
			>
		</p>
	{:else}
		{#each others as d (d.name)}
			<button
				type="button"
				class="flex h-14 w-full items-center gap-4 rounded-md px-2 text-left hover:bg-bg-tinted disabled:opacity-60"
				disabled={switching !== null}
				onclick={() => pick(d.name)}
			>
				<Icon
					icon={d.name === 'auto' ? LaptopIcon : iconFor(d.description || d.name)}
					size={24}
					class="shrink-0 text-text-subdued"
				/>
				<span class="min-w-0 flex-1 truncate text-base text-white">{d.description || d.name}</span>
				{#if switching === d.name}
					<span class="size-4 animate-spin rounded-full border-2 border-white/30 border-t-white"></span>
				{/if}
			</button>
		{:else}
			<p class="px-2 text-sm text-text-subdued">No other output devices found.</p>
		{/each}
	{/if}
	<p class="px-2 pt-8 text-sm text-text-subdued">
		Ztunes plays on this Mac. Pick the speakers or headphones the sound should come out of.
	</p>
</div>
