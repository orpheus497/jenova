<script lang="ts">
    import { page } from '$app/state';
    import FilesView from '$lib/components/app/content/FilesView.svelte';

    let folderId = $derived(page.params.folderId);
</script>

<FilesView currentFolderId={folderId} />
