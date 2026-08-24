<script lang="ts">
	import { FolderOpen, Plus, Trash2, ChevronDown, ChevronRight, Layers, LayoutGrid } from '@lucide/svelte';
	import type { Snippet } from 'svelte';
	import type { DatabaseWorkspace } from '$lib/types/database';
	import { slide } from 'svelte/transition';

	interface Props {
		workspace: DatabaseWorkspace;
		isExpanded: boolean;
		onToggle: () => void;
		onDelete?: () => void;
		onNewChat: () => void;
		onNewNote: () => void;
		onNewProject?: () => void;
		chats?: Snippet;
		notes?: Snippet;
		projects?: Snippet;
		focusNote?: Snippet;
	}

	let {
		workspace, isExpanded, onToggle, onDelete,
		onNewChat, onNewNote, onNewProject, chats, notes, projects, focusNote
	}: Props = $props();
</script>

<div class="rounded-lg border border-white/5 bg-surface/20">
	<!-- Header row -->
	<div class="flex items-center justify-between p-2 hover:bg-sidebar-accent transition-colors group">
		<button
			onclick={onToggle}
			class="flex items-center gap-2 min-w-0 flex-1 text-left"
			aria-expanded={isExpanded}
		>
			{#if isExpanded}
				<ChevronDown size={14} class="text-secondary shrink-0" />
			{:else}
				<ChevronRight size={14} class="text-secondary shrink-0" />
			{/if}
			<Layers size={14} class="text-secondary shrink-0" />
			<h4 class="font-medium text-sm text-foreground truncate">{workspace.name}</h4>
		</button>

		<div class="flex items-center gap-1.5 shrink-0 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
			<a
				href={`#/files?workspaceId=${workspace.id}`}
				onclick={(e) => e.stopPropagation()}
				class="p-1 hover:text-primary text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-primary rounded transition-all"
				title="Explore Workspace Files"
				aria-label="Explore files in {workspace.name}"
			>
				<FolderOpen size={12} />
			</a>
			{#if onNewProject}
				<button
					onclick={(e) => { e.stopPropagation(); onNewProject!(); }}
					class="p-1 hover:text-accent text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-accent rounded transition-all"
					title="New Project in Workspace"
					aria-label="New project in {workspace.name}"
				>
					<LayoutGrid size={12} />
				</button>
			{/if}
			<button
				onclick={(e) => { e.stopPropagation(); onNewChat(); }}
				class="p-1 hover:text-primary text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-primary rounded transition-all"
				title="New Chat in Workspace"
				aria-label="New chat in {workspace.name}"
			>
				<Plus size={12} />
			</button>
			{#if onDelete}
				<button
					onclick={(e) => { e.stopPropagation(); onDelete!(); }}
					class="p-1 hover:text-error text-outline focus-visible:outline-hidden focus-visible:ring-1 focus-visible:ring-error rounded transition-all"
					title="Delete Workspace"
					aria-label="Delete workspace {workspace.name}"
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

			<!-- FOCUS / RULES note (always first) -->
			{#if focusNote}
				{@render focusNote()}
			{/if}

			<!-- Direct workspace chats -->
			{#if chats}
				<div>
					<div class="flex items-center justify-between group/wschats px-2 text-[10px] uppercase font-bold text-[#7b52ab] opacity-80 hover:opacity-100 mb-1">
						<span>Chats</span>
						<button aria-label="New chat in {workspace.name}" onclick={onNewChat} class="opacity-0 group-hover/wschats:opacity-100 p-1 -m-1">
							<Plus size={10} />
						</button>
					</div>
					{@render chats()}
				</div>
			{/if}

			<!-- Direct workspace notes -->
			{#if notes}
				<div>
					<div class="flex items-center justify-between group/wsnotes px-2 text-[10px] uppercase font-bold text-accent/70 hover:text-accent mb-1">
						<span>Notes</span>
						<button aria-label="New note in {workspace.name}" onclick={onNewNote} class="opacity-0 group-hover/wsnotes:opacity-100 p-1 -m-1">
							<Plus size={10} />
						</button>
					</div>
					{@render notes()}
				</div>
			{/if}

			<!-- Projects -->
			{#if projects}
				{@render projects()}
			{/if}

			<!-- Files quick-link -->
			<button
				onclick={(e) => { e.stopPropagation(); window.location.hash = `#/files?workspaceId=${workspace.id}`; }}
				class="w-full flex items-center gap-2 px-2 py-1.5 rounded-lg text-xs transition-all text-secondary/70 hover:bg-sidebar-accent hover:text-secondary"
				aria-label="Explore files in {workspace.name}"
			>
				<FolderOpen size={11} /> Files
			</button>
		</div>
	{/if}
</div>
