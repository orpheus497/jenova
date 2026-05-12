<script lang="ts">
	import { Rocket, RefreshCw, AlertCircle, Play } from '@lucide/svelte';
	import { serverStore } from '$lib/stores/server.svelte';
	import { Button } from '$lib/components/ui/button';
	import { fade, fly } from 'svelte/transition';
	import { onMount } from 'svelte';
	import { TauriService } from '$lib/services/tauri.service';

	interface Props {
		class?: string;
	}

	let { class: className = '' }: Props = $props();

	let status = $derived(serverStore.status);
	let error = $derived(serverStore.error);
	let loading = $derived(serverStore.loading);

	async function handleStartServer() {
		await serverStore.startBackend();
	}

	async function handleRetry() {
		await serverStore.fetch();
	}

	onMount(() => {
		if (TauriService.isTauri() && status === 'stopped') {
			handleStartServer();
		}
	});
</script>

<div class="flex h-full items-center justify-center {className}">
	<div class="w-full max-w-md px-4 text-center">
		<div class="mb-8" in:fade={{ duration: 300 }}>
			<div
				class="mx-auto mb-6 flex h-24 w-24 items-center justify-center rounded-full bg-primary/10"
			>
				{#if status === 'starting' || loading}
					<Rocket class="h-12 w-12 animate-bounce text-primary" />
				{:else if status === 'stopped'}
					<Play class="h-12 w-12 text-muted-foreground" />
				{:else if error}
					<AlertCircle class="h-12 w-12 text-destructive" />
				{:else}
					<Rocket class="h-12 w-12 text-primary" />
				{/if}
			</div>

			<h1 class="mb-3 text-2xl font-bold tracking-tight">
				{#if status === 'starting'}
					Starting Jenova Server...
				{:else if status === 'stopped'}
					Server is Offline
				{:else if error}
					Startup Failed
				{:else}
					Welcome to Jenova
				{/if}
			</h1>

			<p class="text-muted-foreground">
				{#if status === 'starting'}
					The backend server is initializing. This usually takes a few seconds.
				{:else if status === 'stopped'}
					The Jenova backend server is currently not running. Would you like to start it?
				{:else if error}
					{error}
				{:else}
					Connecting to the Jenova backend services...
				{/if}
			</p>
		</div>

		<div class="space-y-3" in:fly={{ y: 20, duration: 400, delay: 200 }}>
			{#if status === 'stopped'}
				<Button onclick={handleStartServer} class="w-full gap-2 py-6 text-lg" size="lg">
					<Play class="h-5 w-5 fill-current" />
					Start Server
				</Button>
			{:else if status === 'starting' || loading}
				<div class="flex items-center justify-center gap-3 rounded-lg bg-muted/50 p-4 text-sm font-medium">
					<RefreshCw class="h-4 w-4 animate-spin" />
					Please wait while the server prepares...
				</div>
			{:else if error}
				<Button onclick={handleRetry} class="w-full gap-2">
					<RefreshCw class="h-4 w-4" />
					Retry Connection
				</Button>
			{/if}
			
			<div class="pt-4 text-xs text-muted-foreground">
				Jenova Workstation v1.0.0
			</div>
		</div>
	</div>
</div>
