<script lang="ts">
	import { FileText, Trash2, Pin } from '@lucide/svelte';
	import { cn } from '$lib/utils';

	import type { DatabaseNote } from '$lib/types/database';

	interface Props {
		note: DatabaseNote;
		isActive?: boolean;
		onSelect: () => void;
		onDelete: () => void;
	}

	let { note, isActive = false, onSelect, onDelete }: Props = $props();
</script>

<div class="relative group/item flex items-center mb-0.5">
    <button
        onclick={onSelect}
        class={cn(
            "flex-1 flex items-center gap-2 px-2 py-2 rounded-lg text-[10px] transition-all text-left truncate",
            note.isFocusNote
                ? "text-red-400 font-medium hover:bg-red-500/10"
                : isActive
                    ? "bg-foreground/5 text-accent font-medium shadow-sm"
                    : "text-muted-foreground hover:bg-sidebar-accent hover:text-foreground"
        )}
    >
        {#if note.isFocusNote}
            <Pin size={14} class="shrink-0 text-red-500" />
        {:else}
            <FileText size={14} class="shrink-0" />
        {/if}
        <span class="truncate">{note.title}</span>
    </button>
    {#if !note.isFocusNote}
        <button 
            onclick={(e) => { e.stopPropagation(); onDelete(); }}
            class="absolute right-2 opacity-0 group-hover/item:opacity-100 p-1 hover:text-destructive transition-opacity"
        >
            <Trash2 size={12} />
        </button>
    {/if}
</div>
