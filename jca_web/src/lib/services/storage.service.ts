import { browser } from '$app/environment';

export class StorageService {
    static async save(path: string, content: string | Blob): Promise<boolean> {
        if (!browser) return false;
        try {
            const response = await fetch(`./api/storage/${path}`, {
                method: 'POST',
                body: content
            });
            return response.ok;
        } catch (error) {
            console.error(`Failed to save to storage: ${path}`, error);
            return false;
        }
    }

    static async get(path: string): Promise<string | null> {
        if (!browser) return null;
        try {
            const response = await fetch(`./api/storage/${path}`);
            if (response.ok) {
                return await response.text();
            }
            return null;
        } catch (error) {
            console.error(`Failed to get from storage: ${path}`, error);
            return null;
        }
    }

    static async list(): Promise<string[]> {
        if (!browser) return [];
        try {
            const response = await fetch(`./api/storage/`);
            if (response.ok) {
                return await response.json();
            }
            return [];
        } catch (error) {
            console.error(`Failed to list storage`, error);
            return [];
        }
    }
}
