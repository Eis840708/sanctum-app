package com.sanctum.vault;

oneway interface ISharedImageWorkerCallback {
    void onResult(long generation, String requestId, boolean success, String value);
}
