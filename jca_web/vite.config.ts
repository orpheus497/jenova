import tailwindcss from "@tailwindcss/vite";
import { sveltekit } from "@sveltejs/kit/vite";
import { dirname, resolve } from "path";
import { fileURLToPath } from "url";

import { defineConfig, searchForWorkspaceRoot } from "vite";
import devtoolsJson from "vite-plugin-devtools-json";
import { storybookTest } from "@storybook/addon-vitest/vitest-plugin";

const __dirname = dirname(fileURLToPath(import.meta.url));

/**
 * the maximum size of an embedded asset in bytes,
 * e.g. maximum size of embedded font (see node_modules/katex/dist/fonts/*.woff2)
 */
const MAX_ASSET_SIZE = 32000;

/** public/index.html minified flag */
const ENABLE_JS_MINIFICATION = true;

export default defineConfig({
  resolve: {
    alias: {
      "katex-fonts": resolve("node_modules/katex/dist/fonts"),
    },
  },
  build: {
    assetsInlineLimit: MAX_ASSET_SIZE,
    chunkSizeWarningLimit: 3072,
    minify: ENABLE_JS_MINIFICATION,
    rollupOptions: {
      output: {
        manualChunks: undefined,
        inlineDynamicImports: true,
      },
    },
  },
  css: {
    preprocessorOptions: {
      scss: {
        additionalData: `
					$use-woff2: true;
					$use-woff: false;
					$use-ttf: false;
				`,
      },
    },
  },
  plugins: [tailwindcss(), sveltekit(), devtoolsJson()],
  test: {
    projects: [
      {
        extends: "./vite.config.ts",
        test: {
          name: "client",
          environment: "browser",
          browser: {
            enabled: true,
            provider: "playwright",
            instances: [{ browser: "chromium" }],
          },
          include: ["tests/client/**/*.svelte.{test,spec}.{js,ts}"],
          setupFiles: ["./vitest-setup-client.ts"],
        },
      },
      {
        extends: "./vite.config.ts",
        test: {
          name: "unit",
          environment: "node",
          include: ["tests/unit/**/*.{test,spec}.{js,ts}"],
        },
      },
      {
        extends: "./vite.config.ts",
        test: {
          name: "ui",
          environment: "browser",
          browser: {
            enabled: true,
            provider: "playwright",
            instances: [{ browser: "chromium", headless: true }],
          },
          include: ["tests/stories/**/*.stories.{js,ts,svelte}"],
          setupFiles: ["./.storybook/vitest.setup.ts"],
        },
        plugins: [
          storybookTest({
            storybookScript: "pnpm run storybook --no-open",
          }),
        ],
      },
    ],
  },

  server: {
    proxy: {
      "/v1": "http://localhost:8080",
      "/api/storage": "http://localhost:8080",
      "/api/workspaces": "http://localhost:8080",
      "/props": "http://localhost:8080",
      "/models": "http://localhost:8080",
      "/cors-proxy": "http://localhost:8080",
    },
    headers: {
      "Cross-Origin-Embedder-Policy": "require-corp",
      "Cross-Origin-Opener-Policy": "same-origin",
    },
    fs: {
      allow: [
        searchForWorkspaceRoot(process.cwd()),
        resolve(__dirname, "tests"),
      ],
    },
  },
});
