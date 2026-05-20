<script lang="ts">
	import { CheckCircle, Zap } from '@lucide/svelte';
	import { cn } from '$lib/utils';
	import { config, settingsStore } from '$lib/stores/settings.svelte';

	let fileInputRef: HTMLInputElement;

	let flashModelLoaded = $derived(!!config().audioModelDownloaded);
	let flashModelName = $derived(config().flashModelIp || '');

	function handleFileChange(e: Event) {
		const target = e.target as HTMLInputElement;
		const file = target.files?.[0];
		if (file) {
			console.log('Uploaded: ', file.name);
			settingsStore.updateMultipleConfig({
				flashModelIp: file.name,
				audioModelDownloaded: true,
				// useAudioVoice: true
			});
		}
	}
</script>

<div class="px-4 py-3">
	<button
		onclick={() => fileInputRef.click()}
		class={cn(
			'flex w-full items-center gap-3 rounded-xl border p-3 transition-all active:scale-[0.98]',
			flashModelLoaded
				? 'border-brand-gold/30 bg-brand-gold/10 text-brand-gold'
				: 'border-border bg-muted/30 text-muted-foreground hover:border-brand-purple/50'
		)}
	>
		<div
			class={cn(
				'flex h-8 w-8 shrink-0 items-center justify-center rounded-lg',
				flashModelLoaded ? 'bg-brand-gold/20' : 'bg-background/50'
			)}
		>
			{#if flashModelLoaded}
				<CheckCircle size={16} />
			{:else}
				<Zap size={16} />
			{/if}
		</div>

		<div class="overflow-hidden text-left">
			<p class="truncate text-xs font-semibold text-foreground">
				{flashModelLoaded ? flashModelName : 'Flash Model'}
			</p>

			<p class="truncate text-[10px] opacity-70">
				{flashModelLoaded ? 'Model Optimized & Loaded' : 'Upload weights (.gguf)'}
			</p>
		</div>
	</button>

	<input
		type="file"
		bind:this={fileInputRef}
		onchange={handleFileChange}
		class="hidden"
		accept=".gguf"
	/>
</div>
