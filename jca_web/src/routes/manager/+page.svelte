<script lang="ts">
	import { onMount } from 'svelte';
	import { Activity, Play, Square, RefreshCcw, Cpu, HardDrive, Network } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Badge } from '$lib/components/ui/badge';
	import { TauriService } from '$lib/services/tauri.service';
	import { serverProps, serverLoading, serverError } from '$lib/stores/server.svelte';
	import { toast } from 'svelte-sonner';

	let backendStatus = $state('unknown');
	let isTauri = TauriService.isTauri();

	async function updateStatus() {
		if (isTauri) {
			backendStatus = await TauriService.getBackendStatus();
		}
	}

	async function handleStart() {
		try {
			await TauriService.startBackend();
			toast.success('Backend started');
			updateStatus();
		} catch (e) {
			toast.error(`Failed to start: ${e}`);
		}
	}

	async function handleStop() {
		try {
			await TauriService.stopBackend();
			toast.success('Backend stopped');
			updateStatus();
		} catch (e) {
			toast.error(`Failed to stop: ${e}`);
		}
	}

	onMount(async () => {
		await updateStatus();
		if (isTauri && backendStatus !== 'running') {
			toast.info('Auto-starting Jenova Backend...');
			handleStart();
		}
		const interval = setInterval(updateStatus, 3000);
		return () => clearInterval(interval);
	});
</script>

<div class="flex flex-col h-full p-8 space-y-8 overflow-y-auto bg-gradient-to-br from-[#1f1f28] to-[#16161d] text-[#dcd7ba]">
	<div class="flex flex-col md:flex-row md:items-end justify-between gap-4">
		<div class="space-y-2">
			<div class="flex items-center gap-3">
				<div class="p-2 rounded-xl bg-purple-500/10 border border-purple-500/20 shadow-[0_0_20px_rgba(120,81,169,0.15)]">
					<Activity class="w-8 h-8 text-[#7851a9]" />
				</div>
				<h1 class="text-4xl font-extrabold tracking-tight bg-gradient-to-r from-[#7851a9] to-[#938aa9] bg-clip-text text-transparent">
					Jenova Manager
				</h1>
			</div>
			<p class="text-[#a6a69a] text-lg max-w-2xl font-medium">
				Cognitive Architecture Control Center. Monitor synaptic throughput and backend neural states.
			</p>
		</div>
		
		<div class="flex items-center gap-3">
			{#if !isTauri}
				<div class="flex items-center gap-2 px-4 py-2 rounded-full border border-yellow-500/30 bg-yellow-500/5 text-yellow-500/80 text-sm font-bold backdrop-blur-md">
					<div class="w-2 h-2 rounded-full bg-yellow-500 animate-pulse"></div>
					Browser Instance
				</div>
			{:else}
				<div class="flex items-center gap-2 px-4 py-2 rounded-full border border-purple-500/30 bg-purple-500/5 text-[#7851a9] text-sm font-bold backdrop-blur-md">
					<div class="w-2 h-2 rounded-full bg-[#7851a9] shadow-[0_0_8px_#7851a9]"></div>
					Native Workspace
				</div>
			{/if}
		</div>
	</div>

	<div class="grid gap-6 md:grid-cols-2 lg:grid-cols-3">
		<!-- Status Card -->
		<Card class="relative overflow-hidden border-purple-500/20 bg-[#1f1f28]/60 backdrop-blur-xl group hover:border-purple-500/40 transition-all duration-500">
			<div class="absolute top-0 right-0 p-4 opacity-10 group-hover:opacity-20 transition-opacity">
				<Activity class="w-24 h-24 text-purple-500 -mr-8 -mt-8" />
			</div>
			
			<CardHeader class="pb-2">
				<CardTitle class="text-sm font-bold uppercase tracking-widest text-[#938aa9]">Neural Backend</CardTitle>
			</CardHeader>
			<CardContent class="space-y-6">
				<div class="flex items-baseline gap-2">
					{#if backendStatus === 'running' || serverProps()}
						<span class="text-4xl font-black text-[#76946a] drop-shadow-[0_0_10px_rgba(118,148,106,0.3)]">ACTIVE</span>
					{:else}
						<span class="text-4xl font-black text-[#c34043] drop-shadow-[0_0_10px_rgba(195,64,67,0.3)]">OFFLINE</span>
					{/if}
				</div>
				
				<div class="flex flex-col gap-3">
					<p class="text-xs font-medium text-[#a6a69a]">
						{backendStatus === 'running' ? 'Direct connection established with JCA-01' : 'Backend process is currently dormant'}
					</p>
					
					{#if isTauri}
						<div class="grid grid-cols-2 gap-3 pt-2">
							<Button 
								variant="outline" 
								class="h-10 gap-2 border-[#76946a]/30 bg-[#76946a]/5 hover:bg-[#76946a]/20 text-[#76946a] font-bold transition-all active:scale-95" 
								onclick={handleStart} 
								disabled={backendStatus === 'running'}
							>
								{#if backendStatus !== 'running'}
									<Play class="w-4 h-4 fill-current" /> Initialize
								{:else}
									<Activity class="w-4 h-4 animate-pulse" /> Active
								{/if}
							</Button>
							<Button 
								variant="outline" 
								class="h-10 gap-2 border-[#c34043]/30 bg-[#c34043]/5 hover:bg-[#c34043]/20 text-[#c34043] font-bold transition-all active:scale-95" 
								onclick={handleStop} 
								disabled={backendStatus !== 'running'}
							>
								<Square class="w-4 h-4 fill-current" /> Terminate
							</Button>
						</div>

						{#if backendStatus === 'running'}
							<div class="pt-4">
								<Button 
									class="w-full h-12 gap-2 bg-[#7851a9] hover:bg-[#938aa9] text-white font-bold transition-all active:scale-95 shadow-[0_0_15px_rgba(120,81,169,0.4)]" 
									onclick={() => window.location.hash = '#/'}
								>
									<Play class="w-5 h-5 fill-current" /> Enter Workstation
								</Button>
							</div>
						{/if}
					{/if}
				</div>
			</CardContent>
		</Card>

		<!-- Engine Card -->
		<Card class="border-blue-500/20 bg-[#1f1f28]/60 backdrop-blur-xl group hover:border-blue-500/40 transition-all duration-500">
			<CardHeader class="pb-2">
				<CardTitle class="text-sm font-bold uppercase tracking-widest text-[#938aa9]">Inference Engine</CardTitle>
			</CardHeader>
			<CardContent class="space-y-4">
				<div class="text-3xl font-black text-[#7e9cd8]">llama-hybrid-v3</div>
				<div class="space-y-2">
					<div class="flex justify-between text-xs">
						<span class="text-[#a6a69a]">VRAM Utilization</span>
						<span class="text-[#7e9cd8] font-bold">8.4 / 12 GB</span>
					</div>
					<div class="h-1.5 w-full bg-blue-500/10 rounded-full overflow-hidden">
						<div class="h-full bg-gradient-to-r from-[#7e9cd8] to-[#658594] w-[70%]"></div>
					</div>
					<p class="text-[10px] text-[#a6a69a] italic">Optimized for Royal Purple hardware profiles.</p>
				</div>
			</CardContent>
		</Card>

		<!-- Network Card -->
		<Card class="border-cyan-500/20 bg-[#1f1f28]/60 backdrop-blur-xl group hover:border-cyan-500/40 transition-all duration-500">
			<CardHeader class="pb-2">
				<CardTitle class="text-sm font-bold uppercase tracking-widest text-[#938aa9]">Telemetry Path</CardTitle>
			</CardHeader>
			<CardContent class="space-y-4">
				<div class="text-3xl font-black text-[#6a9589]">LOCAL_LAN</div>
				<div class="grid grid-cols-2 gap-2 text-[11px]">
					<div class="px-2 py-1 rounded bg-cyan-500/5 border border-cyan-500/10">
						<span class="text-[#a6a69a] block">HOST</span>
						<span class="text-[#6a9589] font-bold">127.0.0.1</span>
					</div>
					<div class="px-2 py-1 rounded bg-cyan-500/5 border border-cyan-500/10">
						<span class="text-[#a6a69a] block">PORT</span>
						<span class="text-[#6a9589] font-bold">8080</span>
					</div>
				</div>
			</CardContent>
		</Card>
	</div>

	<!-- Logs Section -->
	<Card class="border-white/5 bg-[#16161d]/80 backdrop-blur-2xl">
		<CardHeader class="flex flex-row items-center justify-between">
			<div class="space-y-1">
				<CardTitle class="text-lg font-bold flex items-center gap-2">
					<HardDrive class="w-4 h-4 text-[#7fb4ca]" />
					Neural Stream Logs
				</CardTitle>
				<CardDescription class="text-[#a6a69a]">Live telemetry from the Jenova Cognitive core.</CardDescription>
			</div>
			<Button variant="ghost" size="sm" class="text-[10px] uppercase font-bold tracking-widest hover:bg-white/5" onclick={updateStatus}>
				<RefreshCcw class="w-3 h-3 mr-2" /> Refresh
			</Button>
		</CardHeader>
		<CardContent>
			<div class="relative group">
				<div class="absolute -inset-1 bg-gradient-to-r from-[#7851a9]/20 to-transparent rounded-lg blur opacity-25"></div>
				<div class="relative font-mono text-[11px] bg-black/60 p-6 rounded-lg h-80 overflow-y-auto border border-white/5 leading-relaxed shadow-inner">
					<div class="flex gap-4">
						<span class="text-[#a6a69a] shrink-0">03:24:45</span>
						<span class="text-[#76946a]">[SYSTEM]</span>
						<span class="text-[#dcd7ba]">Neural initialization sequence complete. All systems nominal.</span>
					</div>
					<div class="flex gap-4 mt-1">
						<span class="text-[#a6a69a] shrink-0">03:24:46</span>
						<span class="text-[#7e9cd8]">[JENOVA]</span>
						<span class="text-[#dcd7ba]">Mounting cognitive workspace @ <span class="text-[#957fb8]">~/Workspaces/default</span></span>
					</div>
					<div class="flex gap-4 mt-1">
						<span class="text-[#a6a69a] shrink-0">03:24:47</span>
						<span class="text-[#957fb8]">[CORE]</span>
						<span class="text-[#dcd7ba]">VRAM footprint verified: <span class="text-[#e6c384]">8.4GB</span> (Ratio: 0.75 GB/1B)</span>
					</div>
					{#if backendStatus === 'running'}
						<div class="flex gap-4 mt-1">
							<span class="text-[#a6a69a] shrink-0">03:24:48</span>
							<span class="text-[#6a9589]">[NET]</span>
							<span class="text-[#dcd7ba]">REST API socket listening on <span class="underline decoration-[#6a9589]/30">http://localhost:8080</span></span>
						</div>
					{:else}
						<div class="flex gap-4 mt-1">
							<span class="text-[#a6a69a] shrink-0">03:25:12</span>
							<span class="text-[#c34043]">[FATAL]</span>
							<span class="text-[#dcd7ba]">Backend connection severed. Retrying in <span class="font-bold">5s</span>...</span>
						</div>
					{/if}
					
					<!-- Auto-scrolling placeholder -->
					<div class="mt-4 flex items-center gap-2 text-[#a6a69a] animate-pulse">
						<div class="w-1 h-1 rounded-full bg-[#a6a69a]"></div>
						<span>Listening for stream...</span>
					</div>
				</div>
			</div>
		</CardContent>
	</Card>
</div>
