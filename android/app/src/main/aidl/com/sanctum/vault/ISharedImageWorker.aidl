package com.sanctum.vault;

import com.sanctum.vault.ISharedImageWorkerCallback;

interface ISharedImageWorker {
    int getPid();
    void importImage(
        long generation,
        String requestId,
        String cacheId,
        String uri,
        String intentMimeType,
        ISharedImageWorkerCallback callback
    );
}
