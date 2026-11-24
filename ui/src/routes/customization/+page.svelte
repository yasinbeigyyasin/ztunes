<script lang="ts">
    import { goto } from '$app/navigation';
    import { ACCENTS, accentState, appearance, setAccent, setAppearance, type AccentName } from '$lib/theme.svelte';
    import Row from '$lib/settings/Row.svelte';
    import Switch from '$lib/settings/Switch.svelte';

    const choices = Object.entries(ACCENTS) as [AccentName, (typeof ACCENTS)[AccentName]][];
</script>

<svelte:head><title>Customization · Ztunes</title></svelte:head>

<div class="max-w-[804px] px-8 pt-8 pb-16">
    <header class="pb-3"><h1 class="text-2xl font-bold text-white">Customization</h1></header>
    <nav aria-label="Settings pages" class="flex gap-2 border-b border-white/10 pb-4">
        <button class="rounded-full bg-bg-highlight px-4 py-2 text-sm font-bold text-white hover:bg-bg-elevated-highlight" onclick={() => goto('/settings')}>Settings</button>
        <button class="rounded-full bg-white px-4 py-2 text-sm font-bold text-black" aria-current="page">Customization</button>
    </nav>

    <section class="mt-8" aria-labelledby="accent-heading">
        <p class="text-xs font-bold uppercase tracking-[0.16em] text-accent-text">Make it yours</p>
        <h2 id="accent-heading" class="mt-2 text-xl font-bold text-white">Accent color</h2>
        <p class="mt-2 max-w-lg text-sm text-text-subdued">Choose the color for controls and highlights. Your choice stays on this device.</p>
        <div class="mt-5 flex flex-wrap gap-3" role="group" aria-label="Accent color">
            {#each choices as [name, palette] (name)}
                <button
                    type="button"
                    aria-pressed={accentState.name === name}
                    aria-label={`${palette.label} accent`}
                    class="flex min-w-[100px] items-center gap-2 rounded-xl border px-3 py-3 text-sm font-bold text-white transition-colors hover:bg-bg-elevated-highlight {accentState.name === name ? 'border-white bg-bg-highlight' : 'border-white/10 bg-bg-base'}"
                    onclick={() => setAccent(name)}
                >
                    <span class="size-6 rounded-full" style={`background:${palette.base}`} aria-hidden="true"></span>
                    {palette.label}
                </button>
            {/each}
        </div>
    </section>

    <section class="mt-10" aria-labelledby="appearance-heading">
        <h2 id="appearance-heading" class="text-xl font-bold text-white">Appearance</h2>
        <p class="mt-2 mb-4 text-sm text-text-subdued">Fine-tune your listening space.</p>
        <div class="rounded-xl bg-bg-highlight px-4 py-2">
            <Row label="Show artwork behind the full-screen player" hint="Use the current cover as a background when available.">
                {#snippet control()}<Switch label="Full-screen artwork background" checked={appearance.artworkBackground} onchange={(v) => setAppearance({ artworkBackground: v })} />{/snippet}
            </Row>
            <Row label="Compact page margins" hint="Use narrower margins on album, artist and other pages.">
                {#snippet control()}<Switch label="Compact page margins" checked={appearance.compactLayout} onchange={(v) => setAppearance({ compactLayout: v })} />{/snippet}
            </Row>
            <Row label="Reduce interface motion" hint="Shorten animations and transitions.">
                {#snippet control()}<Switch label="Reduce interface motion" checked={appearance.reducedMotion} onchange={(v) => setAppearance({ reducedMotion: v })} />{/snippet}
            </Row>
            <Row label="Open the player when playback starts">
                {#snippet control()}<Switch label="Open player on play" checked={appearance.openPlayerOnPlay} onchange={(v) => setAppearance({ openPlayerOnPlay: v })} />{/snippet}
            </Row>
        </div>
        <p class="mt-4 text-xs text-text-subdued">Ztunes currently uses a dark interface. Accent colors and appearance settings are saved locally.</p>
    </section>
</div>
