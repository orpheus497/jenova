<script lang="ts">
	import { onMount } from 'svelte';

	let canvas: HTMLCanvasElement;

	onMount(() => {
		const ctx = canvas.getContext('2d');
		if (!ctx) return;

		let animationFrameId: number;
		const particles: { x: number; y: number; vx: number; vy: number }[] = [];
		const numParticles = 80;

		const resize = () => {
			canvas.width = window.innerWidth;
			canvas.height = window.innerHeight;
		};
		window.addEventListener('resize', resize);
		resize();

		for (let i = 0; i < numParticles; i++) {
			particles.push({
				x: Math.random() * canvas.width,
				y: Math.random() * canvas.height,
				vx: (Math.random() - 0.5) * 0.5,
				vy: (Math.random() - 0.5) * 0.5
			});
		}

		const render = () => {
			ctx.clearRect(0, 0, canvas.width, canvas.height);
			ctx.lineWidth = 1;

			for (let i = 0; i < numParticles; i++) {
				const p = particles[i];
				p.x += p.vx;
				p.y += p.vy;

				if (p.x < 0 || p.x > canvas.width) p.vx *= -1;
				if (p.y < 0 || p.y > canvas.height) p.vy *= -1;

				ctx.beginPath();
				ctx.arc(p.x, p.y, 1.5, 0, Math.PI * 2);
				ctx.fillStyle = 'rgba(221, 183, 255, 0.4)'; // Primary color with opacity
				ctx.fill();

				for (let j = i + 1; j < numParticles; j++) {
					const p2 = particles[j];
					const dx = p.x - p2.x;
					const dy = p.y - p2.y;
					const dist = Math.sqrt(dx * dx + dy * dy);

					if (dist < 150) {
						ctx.beginPath();
						ctx.moveTo(p.x, p.y);
						ctx.lineTo(p2.x, p2.y);
						ctx.strokeStyle = `rgba(185, 199, 228, ${1 - dist / 150})`; // Tertiary color
						ctx.stroke();
					}
				}
			}
			animationFrameId = requestAnimationFrame(render);
		};
		render();

		return () => {
			window.removeEventListener('resize', resize);
			cancelAnimationFrame(animationFrameId);
		};
	});
</script>

<canvas
	bind:this={canvas}
	class="absolute inset-0 z-0 pointer-events-none opacity-30"
	style="mix-blend-mode: screen;"
></canvas>
