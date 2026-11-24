<script lang="ts">
    let { size = 32, class: className = '' }: { size?: number; class?: string } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 100 100" aria-hidden="true" class="shrink-0 {className}">
    <circle cx="50" cy="50" r="48" fill="var(--color-accent, #ff4b4b)" />
    <path d="M27 27h46v10L43 64h31v10H26V63l30-26H27z" fill="#000" />
</svg>
