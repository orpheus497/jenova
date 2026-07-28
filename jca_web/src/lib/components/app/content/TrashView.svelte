<script lang="ts">
	import { ArchiveRestore, Trash2, AlertTriangle, Layers, File, MessageSquare, Loader2 } from '@lucide/svelte';
	import { FileSystemService, type TrashedItem } from '$lib/services/filesystem.service';
	import { DatabaseService } from '$lib/services/database.service';
	import { conversationsStore } from '$lib/stores/conversations.svelte';
	import { DialogConfirmation } from '$lib/components/app';
	import type { DatabaseConversation } from '$lib/types/database';
	import { onMount } from 'svelte';
	import { slide } from 'svelte/transition';
	
	let trashItems = $state<TrashedItem[]>([]);
	let deletedConversations = $state<DatabaseConversation[]>([]);
	let isLoading = $state(true);
	let isActioning = $state(false);

	let showEmptyDialog = $state(false);

	let totalCount = $derived(trashItems.length + deletedConversations.length);
	
	async function loadTrash() {
		isLoading = true;
		try {
			const [fsItems, convItems] = await Promise.all([
				FileSystemService.getTrash().catch(() => [] as TrashedItem[]),
				DatabaseService.getDeletedConversations().catch(() => [] as DatabaseConversation[]),
			]);
			trashItems = fsItems || [];
			deletedConversations = convItems || [];
		} catch (e) {
			console.error("Failed to load trash", e);
		} finally {
			isLoading = false;
		}
	}

	onMount(() => {
		loadTrash();
	});

	async function handleRestore(item: TrashedItem) {
		isActioning = true;
		try {
			const original_path = item.path.replace(/\/\.trash\/[0-9]+_/, "/");
			await FileSystemService.restoreTrash(item.path, original_path);
			await loadTrash();
		} catch (e) {
			console.error("Restore failed", e);
		} finally {
			isActioning = false;
		}
	}

	async function handleRestoreConversation(conv: DatabaseConversation) {
		isActioning = true;
		try {
			await DatabaseService.restoreConversation(conv.id);
			await conversationsStore.loadConversations();
			await loadTrash();
		} catch (e) {
			console.error("Conversation restore failed", e);
		} finally {
			isActioning = false;
		}
	}

	async function handleEmptyTrash() {
		isActioning = true;
		try {
			await FileSystemService.emptyTrash();
			await loadTrash();
		} catch (e) {
			console.error("Empty trash failed", e);
		} finally {
			isActioning = false;
			showEmptyDialog = false;
		}
	}
</script>

<div class="flex-1 overflow-y-auto px-6 md:px-margin-desktop pt-10 pb-10 flex flex-col gap-8 w-full max-w-5xl mx-auto custom-scrollbar">
	<div class="flex flex-col gap-4">
		
		<div class="flex flex-col sm:flex-row justify-between items-start sm:items-end mb-4 gap-4">
			<div>
				<div class="flex items-center gap-4 mb-2">
					<h2 class="text-3xl font-bold text-error tracking-tight flex items-center gap-2">
						<Trash2 size={28} /> Trash Bin
					</h2>
				</div>
				<p class="text-on-surface-variant mt-2 font-mono text-sm">Manage deleted conversations, workspaces, projects, folders, and assets.</p>
			</div>
			<div class="flex gap-4">
				<button 
					onclick={() => showEmptyDialog = true}
					disabled={isLoading || isActioning || totalCount === 0}
					class="px-4 py-2 rounded-lg bg-error-container text-error hover:bg-error hover:text-on-error font-bold flex items-center gap-2 transition-colors disabled:opacity-50"
				>
					<AlertTriangle size={18} /> Empty Trash
				</button>
			</div>
		</div>

		{#if isLoading}
			<div class="flex justify-center items-center py-12 text-outline">
				<Loader2 size={32} class="animate-spin" />
			</div>
		{:else if totalCount === 0}
			<div class="flex flex-col items-center justify-center py-16 text-outline bg-surface-container/20 rounded-xl border border-dashed border-white/10">
				<Trash2 size={48} class="mb-4 opacity-50" />
				<p class="font-mono">Trash is empty.</p>
			</div>
		{:else}
			<div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4" transition:slide>
				<!-- Soft-deleted conversations -->
				{#each deletedConversations as conv (conv.id)}
					<div class="glass-panel p-4 rounded-xl border border-white/10 flex items-center justify-between group hover:border-primary/50 hover:bg-primary/5 transition-all">
						<div class="flex items-center gap-3 overflow-hidden">
							<div class="w-10 h-10 shrink-0 rounded-lg bg-surface-container flex items-center justify-center text-primary">
								<MessageSquare size={20} />
							</div>
							<div class="min-w-0">
								<h3 class="font-semibold text-sm text-on-surface truncate" title={conv.name}>{conv.name || 'Untitled conversation'}</h3>
								<p class="text-[10px] text-outline font-mono mt-0.5">Chat · {new Date(conv.lastModified).toLocaleDateString()}</p>
							</div>
						</div>
						<button disabled={isActioning} class="p-1.5 rounded-md bg-surface-container hover:bg-primary/20 text-outline hover:text-primary transition-colors" onclick={() => handleRestoreConversation(conv)} title="Restore" aria-label="Restore item">
							<ArchiveRestore size={16} />
						</button>
					</div>
				{/each}
				<!-- Filesystem-trashed items (notes, files, workspaces, etc.) -->
				{#each trashItems as item (item.path)}
					<div class="glass-panel p-4 rounded-xl border border-white/10 flex items-center justify-between group hover:border-error/50 hover:bg-error/5 transition-all">
						<div class="flex items-center gap-3 overflow-hidden">
							<div class="w-10 h-10 shrink-0 rounded-lg bg-surface-container flex items-center justify-center text-outline">
								{#if item.type === 'global'}
									<Layers size={20} />
								{:else}
									<File size={20} />
								{/if}
							</div>
							<div class="min-w-0">
								<h3 class="font-semibold text-sm text-on-surface truncate" title={item.name}>{item.name}</h3>
								<p class="text-[10px] text-outline font-mono mt-0.5">{item.workspace || 'Global'}</p>
							</div>
						</div>
						<button disabled={isActioning} class="p-1.5 rounded-md bg-surface-container hover:bg-primary/20 text-outline hover:text-primary transition-colors" onclick={() => handleRestore(item)} title="Restore" aria-label="Restore item">
							<ArchiveRestore size={16} />
						</button>
					</div>
				{/each}
			</div>
		{/if}

	</div>
</div>

<DialogConfirmation
	bind:open={showEmptyDialog}
	title="Empty Trash"
	description="Are you sure you want to permanently delete all items in the trash? This action cannot be undone."
	confirmText="Empty Trash"
	cancelText="Cancel"
	variant="destructive"
	icon={Trash2}
	onConfirm={handleEmptyTrash}
	onCancel={() => showEmptyDialog = false}
/>

