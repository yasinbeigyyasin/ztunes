<script lang="ts">
	/**
	 * Desktop uses the attached Google sign-in window; Android cannot use an embedded Google
	 * WebView and instead accepts a user-transferred browser Cookie header in a native dialog.
	 */
	import Modal from '$lib/kit/Modal.svelte';
	import { cancelSignIn, startSignIn, ui } from '$lib/player.svelte';
	import { isAndroidHost } from '$lib/platform/android/host';

	const androidSessionImport = isAndroidHost();
	let open = $state(false);
	$effect(() => {
		open = ui.signIn.kind !== 'idle';
	});
</script>

<Modal
	bind:open
	title={androidSessionImport ? 'Connect your account' : 'Sign in to YouTube Music'}
	width={androidSessionImport ? 440 : 360}
	panelClass={androidSessionImport ? '' : '!top-auto !bottom-6 !left-6 !translate-x-0 !translate-y-0'}
	onClose={cancelSignIn}
>
	{#if ui.signIn.kind === 'failed'}
		{#if androidSessionImport}
			<p class="font-bold text-white">Couldn't connect your account</p>
			<p class="mt-2 text-sm text-text-subdued">{ui.signIn.message}</p>
		{:else}
			<p class="text-sm text-text-subdued">Spotless isn't signed in.</p>
			<p class="mt-2 text-sm text-white">{ui.signIn.message}</p>
		{/if}
	{:else if androidSessionImport}
		<div class="rounded-2xl border border-white/10 bg-bg-base p-5">
			<div class="mb-4 flex items-center gap-3">
				<span class="grid size-10 place-items-center rounded-full bg-accent text-lg font-bold text-black">Z</span>
				<div><p class="font-bold text-white">Ztunes</p><p class="text-xs text-text-subdued">Optional account connection</p></div>
			</div>
			<div class="flex items-center gap-3">
				<span class="grid size-6 shrink-0 place-items-center rounded-full bg-white/10 text-sm text-accent" aria-hidden="true">i</span>
				<p class="text-sm font-bold text-white">Import a browser session</p>
			</div>
			<p class="mt-3 text-sm text-text-subdued">Google blocks sign-in inside Android WebViews. To keep your YouTube Music library, sign in to music.youtube.com in Chrome or Edge on a computer. In DevTools → Network, select a /youtubei/v1/browse request, open Headers → Request Headers, and copy the Cookie value into Ztunes. This does not open the YouTube Music app.</p>
			<p class="mt-3 text-xs text-text-subdued">A session cookie is as sensitive as a password. Ztunes sends it directly to YouTube Music for account access, never to a Ztunes server or the WebView, and keeps it encrypted with Android Keystore. It can expire. Do not share it or paste it into chat.</p>
			<p class="mt-3 text-xs text-text-subdued">Experimental sign-in; not yet verified on an Android device.</p>
		</div>
	{:else}
		<div class="flex items-center gap-3">
			<span
				class="size-5 shrink-0 animate-spin rounded-full border-2 border-white/25 border-t-white"
				aria-hidden="true"
			></span>
			<p class="text-sm text-white">Signing in…</p>
		</div>
		<p class="mt-3 text-sm text-text-subdued">
			Sign in to Google in the window in front. Spotless picks up your YouTube Music account as soon
			as you're in, and closes it.
		</p>
	{/if}
	{#snippet footer()}
		{#if ui.signIn.kind === 'failed'}
			<button class="btn-outline" onclick={cancelSignIn}>Close</button>
			<button class="btn-white" onclick={() => startSignIn()}>{androidSessionImport ? 'Reconnect account' : 'Try again'}</button>
		{:else}
			<button class="btn-outline" onclick={() => startSignIn()}>{androidSessionImport ? 'Paste browser session' : 'Show sign-in window'}</button>
			<button class="btn-white" onclick={cancelSignIn}>Cancel</button>
		{/if}
	{/snippet}
</Modal>
