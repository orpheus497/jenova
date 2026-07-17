<script lang="ts">
	import { browser } from '$app/environment';
	import { cn, type WithElementRef } from '$lib/components/ui/utils.js';
	import type { HTMLAttributes } from 'svelte/elements';
	import {
		SIDEBAR_COOKIE_MAX_AGE,
		SIDEBAR_COOKIE_NAME,
		SIDEBAR_WIDTH,
		SIDEBAR_WIDTH_ICON,
		SIDEBAR_WIDTH_MIN_PX,
		SIDEBAR_WIDTH_MAX_PX,
		SIDEBAR_WIDTH_STORAGE_KEY
	} from './constants.js';
	import { setSidebar } from './context.svelte.js';

	let {
		ref = $bindable(null),
		open = $bindable(true),
		onOpenChange = () => {},
		class: className,
		style,
		children,
		...restProps
	}: WithElementRef<HTMLAttributes<HTMLDivElement>> & {
		open?: boolean;
		onOpenChange?: (open: boolean) => void;
	} = $props();

	// Resizable sidebar width – read persisted value from localStorage
	let sidebarWidthPx = $state(
		browser
			? Math.min(SIDEBAR_WIDTH_MAX_PX, Math.max(SIDEBAR_WIDTH_MIN_PX,
					parseInt(localStorage.getItem(SIDEBAR_WIDTH_STORAGE_KEY) || '', 10) || 288
				))
			: 288
	);
	let sidebarWidth = $derived(`${sidebarWidthPx}px`);
	let isResizing = $state(false);

	function handleResizeStart(e: MouseEvent) {
		e.preventDefault();
		isResizing = true;

		const onMouseMove = (e: MouseEvent) => {
			const newWidth = Math.min(
				SIDEBAR_WIDTH_MAX_PX,
				Math.max(SIDEBAR_WIDTH_MIN_PX, e.clientX)
			);
			sidebarWidthPx = newWidth;
		};

		const onMouseUp = () => {
			isResizing = false;
			document.removeEventListener('mousemove', onMouseMove);
			document.removeEventListener('mouseup', onMouseUp);
			document.body.style.cursor = '';
			document.body.style.userSelect = '';
			localStorage.setItem(SIDEBAR_WIDTH_STORAGE_KEY, String(sidebarWidthPx));
		};

		document.body.style.cursor = 'col-resize';
		document.body.style.userSelect = 'none';
		document.addEventListener('mousemove', onMouseMove);
		document.addEventListener('mouseup', onMouseUp);
	}

	function handleResizeKeydown(e: KeyboardEvent) {
		const step = 10;
		if (e.key === 'ArrowLeft') {
			e.preventDefault();
			sidebarWidthPx = Math.max(SIDEBAR_WIDTH_MIN_PX, sidebarWidthPx - step);
			localStorage.setItem(SIDEBAR_WIDTH_STORAGE_KEY, String(sidebarWidthPx));
		} else if (e.key === 'ArrowRight') {
			e.preventDefault();
			sidebarWidthPx = Math.min(SIDEBAR_WIDTH_MAX_PX, sidebarWidthPx + step);
			localStorage.setItem(SIDEBAR_WIDTH_STORAGE_KEY, String(sidebarWidthPx));
		}
	}

	const sidebar = setSidebar({
		open: () => open,
		setOpen: (value: boolean) => {
			open = value;
			onOpenChange(value);

			// This sets the cookie to keep the sidebar state.
			document.cookie = `${SIDEBAR_COOKIE_NAME}=${open}; path=/; max-age=${SIDEBAR_COOKIE_MAX_AGE}`;
		}
	});
</script>

<svelte:window onkeydown={sidebar.handleShortcutKeydown} />

<div
	data-slot="sidebar-wrapper"
	style="--sidebar-width: {sidebarWidth}; --sidebar-width-icon: {SIDEBAR_WIDTH_ICON}; {style}"
	class={cn(
		'group/sidebar-wrapper flex min-h-svh w-full has-data-[variant=inset]:bg-transparent',
		className
	)}
	bind:this={ref}
	{...restProps}
>
	{@render children?.()}

	<!-- Resize handle -->
	{#if open && !sidebar.isMobile}
		<div
			class="fixed top-0 bottom-0 z-50 w-1 cursor-col-resize transition-colors duration-150 hover:bg-brand-purple/40 active:bg-brand-purple/60 {isResizing ? 'bg-brand-purple/40' : ''}"
			style="left: {sidebarWidthPx}px;"
			onmousedown={handleResizeStart}
			onkeydown={handleResizeKeydown}
			role="separator"
			aria-orientation="vertical"
			aria-label="Resize sidebar"
			aria-valuenow={sidebarWidthPx}
			aria-valuemin={SIDEBAR_WIDTH_MIN_PX}
			aria-valuemax={SIDEBAR_WIDTH_MAX_PX}
			tabindex="0"
		></div>
	{/if}
</div>
