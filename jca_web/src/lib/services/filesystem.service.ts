export interface TrashedItem {
  path: string;
  type: string;
  workspace?: string;
  name: string;
}

export interface FsTreeItem {
  path: string;
  full_path: string;
  isDir: boolean;
}

async function apiFetch<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`/api/fs/${path}`, options);
  if (!res.ok) throw new Error(`API error: ${res.status}`);
  const contentType = res.headers.get("content-type");
  if (contentType && contentType.includes("application/json")) {
    return await res.json();
  }
  return {} as T;
}

export class FileSystemService {
  static async getTrash(): Promise<TrashedItem[]> {
    return await apiFetch<TrashedItem[]>("trash");
  }

  static async restoreTrash(
    trashPath: string,
    originalPath: string,
  ): Promise<void> {
    await apiFetch("trash/restore", {
      method: "POST",
      body: JSON.stringify({
        trash_path: trashPath,
        original_path: originalPath,
      }),
    });
  }

  static async emptyTrash(): Promise<void> {
    await apiFetch("trash/empty", { method: "DELETE" });
  }

  static async getTree(): Promise<FsTreeItem[]> {
    return await apiFetch<FsTreeItem[]>("tree");
  }
}
