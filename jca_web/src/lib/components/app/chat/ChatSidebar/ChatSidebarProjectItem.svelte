<script lang="ts">
	import { FolderOpen, FolderPlus, Plus, Trash2, ChevronDown, ChevronRight, LayoutGrid } from '@lucide/svelte';
	import type { Snippet } from 'svelte';
	import type { DatabaseProject } from '$lib/types/database';
	import { slide } from 'svelte/transition';

	interface Props {
		project: DatabaseProject;
		workspaceId: string;
		isExpanded: boolean;
		onToggle: () => void;
		onDelete?: () => void;
		onNewChat: () => void;
		onNewNote: () => void;
		onNewFolder?: () => void;
		chats?: Snippet;
		notes?: Snippet;
		folders?: Snippet;
	}

	let {
		project, workspaceId, isExpanded, onToggle, onDelete,
		onNewChat, onNewNote, onNewFolder, chats, notes, folders
	}: Props = $props();
</script>

<div class="rounded-lg border border-white/5 bg-surface/30 mt-1">
	<!-- Header row -->
	<div class="flex items-center justify-between p-2 hover:bg-sidebar-accent transition-colors group">
		<button
			onclick={onToggle}
			class="flex items-center gap-2 min-w-0 flex-1 text-left"
			aria-expanded={isExpanded}
		>
			{#if isExpanded}
				<ChevronDown size={14} class="text-primary shrink-0" />
			{:else}
				<ChevronRight size={14} class="text-primary shrink-0" />
			{/if}
			<LayoutGrid size={14} class="text-primary shrink-0" />
			<h5 class="font-medium text-xs text-foreground truncate">{project.name}</h5>
		</button>

		<div class="flex items-center gap-1.5 shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
			<a
				href={`#/files?workspaceId=${workspaceId}&projectId=${project.id}`}
				onclick={(e) => e.stopPropagation()}
				class="p-1 hover:text-primary text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-primary rounded transition-all"
				title="Explore Project Files"
			>
				<FolderOpen size={12} />
			</a>
			{#if onNewFolder}
				<button
					onclick={(e) => { e.stopPropagation(); onNewFolder!(); }}
					class="p-1 hover:text-secondary text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-secondary rounded transition-all"
					title="New Folder in Project"
				>
					<FolderPlus size={12} />
				</button>
			{/if}
			<button
				onclick={(e) => { e.stopPropagation(); onNewChat(); }}
				class="p-1 hover:text-primary text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-primary rounded transition-all"
				title="New Chat in Project"
			>
				<Plus size={12} />
			</button>
			{#if onDelete}
				<button
					onclick={(e) => { e.stopPropagation(); onDelete!(); }}
					class="p-1 hover:text-error text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-error rounded transition-all"
					title="Delete Project"
				>
					<Trash2 size={12} />
				</button>
			{/if}
		</div>
	</div>

	<!-- Expanded content -->
	{#if isExpanded}
		<div class="pl-2 pr-1 pb-2 space-y-2 relative" transition:slide>
			<div class="absolute left-1.5 top-0 bottom-0 w-px bg-border/40"></div>

			<!-- Direct chats -->
			{#if chats}
				<div>
					<div class="flex items-center justify-between group/pchats px-2 text-[10px] uppercase font-bold text-[#7b52ab] opacity-80 hover:opacity-100 mb-1">
						<span>Chats</span>
						<button aria-label="New chat in {project.name}" onclick={onNewChat} class="opacity-0 group-hover/pchats:opacity-100 p-1 -m-1">
							<Plus size={10} />
						</button>
					</div>
					{@render chats()}
				</div>
			{/if}

			<!-- Direct notes -->
			{#if notes}
				<div>
					<div class="flex items-center justify-between group/pnotes px-2 text-[10px] uppercase font-bold text-accent/70 hover:text-accent mb-1">
						<span>Notes</span>
						<button aria-label="New note in {project.name}" onclick={onNewNote} class="opacity-0 group-hover/pnotes:opacity-100 p-1 -m-1">
							<Plus size={10} />
						</button>
					</div>
					{@render notes()}
				</div>
			{/if}

			<!-- Folders -->
			{#if folders}
				{@render folders()}
			{/if}

			<!-- Files quick-link -->
			<button
				onclick={(e) => { e.stopPropagation(); window.location.hash = `#/files?workspaceId=${workspaceId}&projectId=${project.id}`; }}
				class="w-full flex items-center gap-2 px-2 py-1.5 rounded-lg text-xs transition-all text-secondary/70 hover:bg-sidebar-accent hover:text-secondary"
			>
				<FolderOpen size={11} /> Files
			</button>
		</div>
	{/if}
</div>
