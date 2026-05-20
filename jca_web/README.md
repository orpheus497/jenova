# Jenova Cognitive Architecture (JCA) - Web UI

A modern, high-performance web interface for the **Jenova Cognitive Architecture (JCA)**, built with SvelteKit 5. This system provides an intuitive, elegant, and secure cognitive interface for interacting with local JCA nodes.
## Key Features

### Cognitive Capabilities
- **Sophisticated Persona**: Operates as Jenova, a poised and direct AI agent.
- **Deep Reasoning**: Integrated support for models with `<think>` reasoning blocks.
- **Cache AG**: Advanced response caching for instantaneous retrieval of previous insights.
- **Network Resilience**: Automatic 3-stage retry logic for stable operation over unreliable networks.

### Workspaces
- **Note Management**: Create, organize, and edit rich text notes.
- **File Assets**: Support for PDF, images, audio, and source code.
- **Context Injection**: Automatic injection of workspace artifacts (notes and files) into the AI's cognitive context.

### Precision Chat Interface
- **Branching History**: Fork conversations at any point to explore alternate reasoning paths.
- **Streaming Responses**: Real-time token streaming with performance metrics (TPS, TTFT).
- **Advanced Rendering**: Full GFM support, KaTeX math formulas, and high-fidelity syntax highlighting.

### PWA & Mobile Optimization
- **WakeLock API**: Prevents system sleep during deep reasoning or long generations.
- **Adaptive UI**: Fully responsive design that feels native on both desktop and mobile.

---

## 🛠️ Tech Stack

| Layer             | Technology                      | Purpose                                                  |
| ----------------- | ------------------------------- | -------------------------------------------------------- |
| **Framework**     | SvelteKit + Svelte 5            | Reactive UI with runes (`$state`, `$derived`, `$effect`) |
| **UI Components** | shadcn-svelte + bits-ui         | Accessible, high-fidelity component library              |
| **Styling**       | TailwindCSS 4                   | Utility-first CSS with design tokens                     |
| **Database**      | IndexedDB (Dexie)               | Persistent client-side cognitive storage                 |
| **Testing**       | Playwright + Vitest + Storybook | E2E, unit, and visual validation                         |

---

## 🏁 Getting Started

### Prerequisites
- **Node.js** 20+
- **npm** 10+
- **JCA Node**

### 1. Installation
```bash
npm install
```

### 2. Development
```bash
npm run dev
```
The interface will be available at `http://localhost:5173`.

### 3. Build for Production
```bash
npm run build
```
Optimized assets will be generated in the `build/` directory, ready for deployment.

---

## 🔒 Security & Privacy
- **Local First**: Your conversations and files are stored in your browser's IndexedDB, not on our servers.
- **Clean Logging**: Security-hardened logging prevents leakage of API keys or sensitive request metadata.
- **Git Protection**: Robust `.gitignore` prevents accidental upload of `.env` files or local databases.

---

## 📜 Documentation
Detailed architectural diagrams and data flow specifications can be found in the `docs/` directory:
- [High-Level Architecture](docs/architecture/high-level-architecture-simplified.md)
- [Chat Lifecycle Flow](docs/flows/chat-flow.md)
- [Workspace Context Flow](docs/flows/database-flow.md)

---
© 2026 Jenova Cognitive Architecture. Portions based on the JCA open-source project.
