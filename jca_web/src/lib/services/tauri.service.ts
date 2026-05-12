import { invoke } from '@tauri-apps/api/core';

export class TauriService {
	static isTauri(): boolean {
		return typeof window !== 'undefined' && window.__TAURI_INTERNALS__ !== undefined;
	}

	static async startBackend(): Promise<string> {
		if (!this.isTauri()) return 'Not in Tauri';
		return await invoke('start_backend');
	}

	static async stopBackend(): Promise<string> {
		if (!this.isTauri()) return 'Not in Tauri';
		return await invoke('stop_backend');
	}

	static async getBackendStatus(): Promise<string> {
		if (!this.isTauri()) return 'unknown';
		return await invoke('get_backend_status');
	}
}
