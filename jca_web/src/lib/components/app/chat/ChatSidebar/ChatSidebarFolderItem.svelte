<script lang="ts">
	import { Folder, FolderOpen, ChevronRight, ChevronDown, Trash2, Plus, Archive } from '@lucide/svelte';
	import type { Snippet } from 'svelte';
	import type { DatabaseFolder } from '$lib/types/database';
	import { slide } from 'svelte/transition';

	interface Props {
		folder: DatabaseFolder;
		workspaceId?: string;
		projectId?: string;
		isExpanded: boolean;
		onToggle: () => void;
		onDelete: () => void;
		onNewChat: () => void;
		onNewNote: () => void;
		onViewFiles?: () => void;
		chats?: Snippet;
		notes?: Snippet;
	}

	let {
		folder, workspaceId, projectId, isExpanded, onToggle,
		onDelete, onNewChat, onNewNote, onViewFiles, chats, notes
	}: Props = $props();

	function goToFiles() {
		if (onViewFiles) { onViewFiles(); return; }
		// eslint-disable-next-line svelte/prefer-svelte-reactivity -- imperative handler, not reactive state
		const params = new URLSearchParams();
		if (workspaceId) params.set('workspaceId', workspaceId);
		if (projectId)   params.set('projectId', projectId);
		params.set('folderId', folder.id);
		window.location.hash = `#/files?${params}`;
	}
</script>

<div class="rounded-lg border border-white/5 bg-surface/40 mt-1">
	<!-- Header row -->
	<div class="flex items-center p-2 hover:bg-sidebar-accent transition-colors group">
		<button
			onclick={onToggle}
			class="flex items-center gap-2 min-w-0 flex-1 text-left"
			aria-expanded={isExpanded}
		>
			{#if isExpanded}
				<ChevronDown size={14} class="text-accent shrink-0" />
				<FolderOpen size={14} class="text-accent shrink-0" />
			{:else}
				<ChevronRight size={14} class="text-muted-foreground shrink-0" />
				<Folder size={14} class="text-accent shrink-0" />
			{/if}
			<span class="font-medium text-xs text-foreground truncate">{folder.name}</span>
		</button>

		<div class="flex items-center gap-1.5 shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
			<button onclick={(e) => { e.stopPropagation(); goToFiles(); }} class="p-1 hover:text-primary text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-primary rounded transition-all" title="View Folder Files">
				<Archive size={12} />
			</button>
			<button onclick={(e) => { e.stopPropagation(); onNewChat(); }} class="p-1 hover:text-primary text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-primary rounded transition-all" title="New Chat">
				<Plus size={12} />
			</button>
			<button onclick={(e) => { e.stopPropagation(); onDelete(); }} class="p-1 hover:text-error text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-error rounded transition-all" title="Delete Folder">
				<Trash2 size={12} />
			</button>
		</div>
	</div>

	{#if isExpanded}
		<div class="pl-6 mt-1 pb-2 space-y-3 relative" transition:slide>
			<div class="absolute left-4 top-0 bottom-2 w-px bg-border/40"></div>

			<!-- Chats in Folder -->
			<div>
				<div class="flex items-center justify-between group/fchats px-2 text-[10px] uppercase font-bold text-[#7b52ab] opacity-80 hover:opacity-100 mb-1">
					<span>Chats</span>
					<button aria-label="New chat in {folder.name}" onclick={onNewChat} class="opacity-0 group-hover/fchats:opacity-100 p-1 -m-1">
						<Plus size={10} />
					</button>
				</div>
				{#if chats}
					{@render chats()}
				{/if}
			</div>

			<!-- Notes in Folder -->
			<div>
				<div class="flex items-center justify-between group/fnotes px-2 text-[10px] uppercase font-bold text-accent/70 hover:text-accent mb-1">
					<span>Notes</span>
					<button aria-label="New note in {folder.name}" onclick={onNewNote} class="opacity-0 group-hover/fnotes:opacity-100 p-1 -m-1">
						<Plus size={10} />
					</button>
				</div>
				{#if notes}
					{@render notes()}
				{/if}
			</div>

			<!-- Files quick-link -->
			<button
				onclick={goToFiles}
				class="w-full flex items-center gap-2 px-2 py-1.5 rounded-lg text-xs transition-all text-secondary/70 hover:bg-sidebar-accent hover:text-secondary"
			>
				<Archive size={11} /> Files
			</button>
		</div>
	{/if}
</div>
