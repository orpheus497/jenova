<script lang="ts">
	import { AlertTriangle, Server } from '@lucide/svelte';
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import { serverProps, serverLoading, serverError } from '$lib/stores/server.svelte';
	import { singleModelName } from '$lib/stores/models.svelte';

	import { TauriService } from '$lib/services/tauri.service';
	import { toast } from 'svelte-sonner';

	interface Props {
		class?: string;
		showActions?: boolean;
	}

	let { class: className = '', showActions = false }: Props = $props();

	let error = $derived(serverError());
	let loading = $derived(serverLoading());
	let model = $derived(singleModelName());
	let serverData = $derived(serverProps());

	const isTauri = TauriService.isTauri();

	async function handleStart() {
		try {
			toast.promise(TauriService.startBackend(), {
				loading: 'Starting backend...',
				success: 'Backend started successfully',
				error: (err) => `Failed to start backend: ${err}`
			});
		} catch (e) {
			console.error(e);
		}
	}

	async function handleStop() {
		try {
			toast.promise(TauriService.stopBackend(), {
				loading: 'Stopping backend...',
				success: 'Backend stopped successfully',
				error: (err) => `Failed to stop backend: ${err}`
			});
		} catch (e) {
			console.error(e);
		}
	}

	function getStatusColor() {
		if (loading) return 'bg-yellow-500';
		if (error) return 'bg-red-500';
		if (serverData) return 'bg-green-500';

		return 'bg-gray-500';
	}

	function getStatusText() {
		if (loading) return 'Connecting...';
		if (error) return 'Connection Error';
		if (serverData) return 'Connected';

		return 'Unknown';
	}
</script>

<div class="flex items-center space-x-3 {className}">
	<div class="flex items-center space-x-2">
		<div class="h-2 w-2 rounded-full {getStatusColor()}"></div>

		<span class="text-sm text-muted-foreground">{getStatusText()}</span>
	</div>

	{#if serverData && !error}
		<Badge variant="outline" class="text-xs">
			<Server class="mr-1 h-3 w-3" />

			{model || 'Unknown Model'}
		</Badge>

		{#if serverData?.default_generation_settings?.n_ctx}
			<Badge variant="secondary" class="text-xs">
				ctx: {serverData.default_generation_settings.n_ctx.toLocaleString()}
			</Badge>
		{/if}
	{/if}

	{#if showActions && error}
		<div class="flex items-center space-x-2">
			<Button variant="outline" size="sm" class="text-destructive">
				<AlertTriangle class="h-4 w-4" />

				{error}
			</Button>

			{#if isTauri}
				<Button variant="outline" size="sm" onclick={handleStart} class="text-green-500">
					Start Backend
				</Button>
			{/if}
		</div>
	{:else if showActions && serverData && isTauri}
		<Button variant="ghost" size="sm" onclick={handleStop} class="text-muted-foreground hover:text-destructive">
			Stop Backend
		</Button>
	{/if}
</div>
