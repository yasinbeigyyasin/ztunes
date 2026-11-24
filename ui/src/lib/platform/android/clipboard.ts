export async function writeText(text: string): Promise<void> {
	if (navigator.clipboard?.writeText) return navigator.clipboard.writeText(text);
	throw new Error('Clipboard access is unavailable');
}
