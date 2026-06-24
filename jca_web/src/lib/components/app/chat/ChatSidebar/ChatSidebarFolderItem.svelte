<script lang="ts">
	import { Folder, FolderOpen, ChevronRight, ChevronDown, Trash2, Plus, Archive } from '@lucide/svelte';
    import type { Snippet } from 'svelte';

	interface Props {
		folder: any;
		isExpanded: boolean;
		onToggle: () => void;
		onDelete: () => void;
        onNewChat: () => void;
        onNewNote: () => void;
        onViewFiles: () => void;
        chats?: Snippet;
        notes?: Snippet;
	}

	let { 
        folder, isExpanded, onToggle, onDelete, onNewChat, onNewNote, onViewFiles,
        chats, notes
    }: Props = $props();
</script>

<div class="group flex items-center">
    <button 
        onclick={onToggle}
        class="flex-1 flex items-center gap-2 px-2 py-2 rounded-lg text-sm text-foreground font-medium hover:bg-sidebar-accent transition-all text-left"
    >
        {#if isExpanded}
            <ChevronDown size={14} class="text-muted-foreground" />
            <FolderOpen size={14} class="text-secondary" />
        {:else}
            <ChevronRight size={14} class="text-muted-foreground" />
            <Folder size={14} class="text-secondary" />
        {/if}
        <span class="truncate">{folder.name}</span>
    </button>
    <button 
        onclick={(e) => { e.stopPropagation(); onDelete(); }}
        class="opacity-0 group-hover:opacity-100 p-1.5 text-muted-foreground hover:text-destructive transition-opacity"
    >
        <Trash2 size={12} />
    </button>
</div>

{#if isExpanded}
    <div class="pl-6 mt-1 space-y-3 relative">
        <div class="absolute left-4 top-0 bottom-2 w-px bg-border/40"></div>
        
        <!-- Chats in Workspace -->
        <div>
            <div class="flex items-center justify-between group/wschat px-2 text-[10px] uppercase font-bold text-primary/70 hover:text-primary mb-1">
                <span>Chats</span>
                <button onclick={onNewChat} class="opacity-0 group-hover/wschat:opacity-100 p-1 -m-1"><Plus size={10} /></button>
            </div>
            {#if chats}
                {@render chats()}
            {/if}
        </div>

        <!-- Notes in Workspace -->
        <div>
            <div class="flex items-center justify-between group/wsnote px-2 text-[10px] uppercase font-bold text-accent/70 hover:text-accent mb-1">
                <span>Notes</span>
                <button onclick={onNewNote} class="opacity-0 group-hover/wsnote:opacity-100 p-1 -m-1"><Plus size={10} /></button>
            </div>
            {#if notes}
                {@render notes()}
            {/if}
        </div>

        <!-- Files in Workspace -->
        <div>
            <button onclick={onViewFiles} class="w-full flex items-center justify-between group/wsfile px-2 py-2 rounded-lg text-sm transition-all text-secondary/70 hover:bg-sidebar-accent hover:text-secondary">
                <span class="flex items-center gap-2"><Archive size={12} /> Files</span>
            </button>
        </div>
    </div>
{/if}
