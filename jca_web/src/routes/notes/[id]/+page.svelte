<script lang="ts">
    import { page } from '$app/state';
    import { FileText, Edit3, X, Check, Trash2 } from '@lucide/svelte';
    import { workspaceStore, notes } from '$lib/stores/workspace.svelte';
    import { MarkdownContent } from '$lib/components/app';
    import { Button } from '$lib/components/ui/button';
    import { DialogConfirmation } from '$lib/components/app';
    import { cn } from '$lib/utils';
    import { goto } from '$app/navigation';

    let id = $derived(page.params.id);
    let selectedNote = $derived(notes().find(n => n.id === id));
    
    let isEditing = $state(false);
    let editTitle = $state("");
    let editContent = $state("");
    let showDeleteDialog = $state(false);

    $effect(() => {
        if (selectedNote) {
            editTitle = selectedNote.title;
            editContent = selectedNote.content;
            isEditing = false;
        }
    });

    function saveNote() {
        if (!selectedNote) return;
        workspaceStore.updateNote(selectedNote.id, { title: editTitle, content: editContent });
        isEditing = false;
    }

    function handleDelete() {
        if (!selectedNote) return;
        workspaceStore.deleteNote(selectedNote.id);
        goto('/notes');
    }
</script>

<div class="flex flex-col h-full w-full bg-background relative">
    {#if selectedNote}
        <div class="p-4 border-b border-border/40 flex items-center justify-between bg-background/50">
            {#if isEditing}
                <input 
                    bind:value={editTitle}
                    class="bg-transparent text-lg font-bold text-foreground focus:outline-none border-b border-primary/50 px-1 w-1/2"
                    placeholder="Note Title"
                />
            {:else}
                <h1 class="text-lg font-bold text-foreground flex items-center gap-3">
                    <FileText size={18} class="text-yellow-500" />
                    {selectedNote.title}
                </h1>
            {/if}
            <div class="flex items-center gap-2">
                {#if isEditing}
                    <Button variant="ghost" size="icon" onclick={() => isEditing = false} title="Cancel">
                        <X size={16} />
                    </Button>
                    <Button variant="default" size="sm" onclick={saveNote} class="flex items-center gap-2">
                        <Check size={16} /> Save
                    </Button>
                {:else}
                    <Button variant="ghost" size="sm" onclick={() => isEditing = true} class="text-yellow-500 hover:text-yellow-600 hover:bg-yellow-500/10 gap-2">
                        <Edit3 size={16} /> Edit
                    </Button>
                    <Button variant="ghost" size="icon" onclick={() => showDeleteDialog = true} class="text-muted-foreground hover:text-destructive hover:bg-destructive/10">
                        <Trash2 size={16} />
                    </Button>
                {/if}
            </div>
        </div>
        <div class="flex-1 p-6 overflow-y-auto">
            {#if isEditing}
                <textarea
                    bind:value={editContent}
                    class="w-full h-full bg-transparent resize-none focus:outline-none text-foreground font-mono text-sm leading-relaxed"
                    placeholder="Start typing your note in Markdown..."
                ></textarea>
            {:else}
                <div class="prose dark:prose-invert max-w-none font-mono whitespace-pre-wrap">
                    {#if selectedNote.content}
                        <MarkdownContent content={selectedNote.content} />
                    {:else}
                        <span class="text-muted-foreground italic">Empty note... Click "Edit" to add content.</span>
                    {/if}
                </div>
            {/if}
        </div>
    {:else}
        <div class="h-full flex flex-col items-center justify-center text-muted-foreground opacity-50">
            <FileText size={48} class="mb-4" />
            <p class="text-sm border border-border/50 px-4 py-2 rounded-lg bg-sidebar/50">Note not found</p>
        </div>
    {/if}
</div>

<DialogConfirmation
    bind:open={showDeleteDialog}
    title="Delete Note"
    description="Are you sure you want to delete this note? This action cannot be undone."
    confirmText="Delete"
    variant="destructive"
    icon={Trash2}
    onConfirm={handleDelete}
    onCancel={() => showDeleteDialog = false}
/>
