<script lang="ts">
	import { FileText, Trash2 } from '@lucide/svelte';
	import { cn } from '$lib/utils';

	interface Props {
		note: any;
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
            "flex-1 flex items-center gap-2 px-2 py-2 rounded-lg text-sm transition-all text-left truncate",
            isActive ? "bg-foreground/5 text-accent font-medium shadow-sm" : "text-muted-foreground hover:bg-sidebar-accent hover:text-foreground"
        )}
    >
        <FileText size={14} class="shrink-0" />
        <span class="truncate">{note.title}</span>
    </button>
    <button 
        onclick={(e) => { e.stopPropagation(); onDelete(); }}
        class="absolute right-2 opacity-0 group-hover/item:opacity-100 p-1 hover:text-destructive transition-opacity"
    >
        <Trash2 size={12} />
    </button>
</div>
