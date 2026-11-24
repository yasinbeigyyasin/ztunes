<script lang="ts" module>
	/** Open/close state, so any page (Made for you heroes, the queue) can open the one dialog. */
	export const aboutRecs = $state({ open: false });
	export function openAboutRecommendations() {
		aboutRecs.open = true;
	}
</script>

<script lang="ts">
	/**
	 * Spotify's "About recommendations" dialog (the link under a Made for you hero), for Ztunes:
	 * how the recommendations are made (on this Mac, from your own listening) and the switches
	 * that control them. Kit Modal at Spotify's 544px; the body scrolls, one white pill at the end.
	 */
	import { Modal, Pill } from '$lib/kit';
	import { goSettings } from '$lib/settings/actions';

	function go(section: string) {
		aboutRecs.open = false;
		goSettings(section);
	}
</script>

{#snippet link(section: string, text: string)}
	<button type="button" class="font-bold text-white underline-offset-2 hover:underline" onclick={() => go(section)}
		>{text}</button
	>
{/snippet}

<Modal bind:open={aboutRecs.open} title="About recommendations" width={544}>
	<div class="-mx-6 max-h-[50vh] overflow-y-auto px-6 text-base leading-6 text-text-subdued">
		<p>
			Ztunes's recommendations help you find music you'll love: your mixes, Weekly Discoveries,
			New Release Mix, Smart Shuffle, radio and autoplay.
		</p>
		<p class="mt-4">
			They're worked out on this Mac, from your own listening: what you play and how often, the
			songs you like, what you skip, what's in your playlists, the artists you follow, and any
			listening history you imported from Spotify. That history stays on this Mac. Ztunes only asks
			YouTube Music for songs related to a few of the tracks you play, then picks and orders them
			here. There are no ads and no paid promotion in your recommendations.
		</p>
		<h3 class="mt-6 text-base font-bold text-white">You're in control</h3>
		<ul class="mt-2 flex flex-col gap-3">
			<li>
				{@render link('social', 'Private session')}: nothing you play counts toward your history or
				recommendations while it's on.
			</li>
			<li>
				{@render link('explicit', 'Explicit content')}: turn it off and explicit songs are left out
				of your mixes and skipped in playback.
			</li>
			<li>
				{@render link('clear-history', 'Clear listening history')}: forget every play counted on this
				Mac. Your mixes start over from your likes and playlists.
			</li>
		</ul>
	</div>
	<div class="mt-8 flex justify-center">
		<Pill variant="white" large onclick={() => go('social')}>Open Settings</Pill>
	</div>
</Modal>
