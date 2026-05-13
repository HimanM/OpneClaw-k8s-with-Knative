# OpenClaw Local Serverless Architecture Specification (Flash Edition)

### 1. Project Overview

This document outlines the technical requirements and architecture for deploying **OpenClaw**, an autonomous AI agent, in a serverless capacity on a local `kubeadm` Kubernetes cluster. The objective is to ensure the agent wakes instantly on incoming webhook traffic, executes tasks using **Gemini 2.5 Flash**, and hibernates (scales to zero) during idle periods.

### 2. Core Architecture

* **Platform:** Local Kubernetes (`kubeadm`).
* **Serverless Engine:** Knative Serving (Core + CRDs).
* **Networking/Ingress:** Kourier.
* **Storage:** `hostPath` Volume (Manual) or `local-path-provisioner` (Dynamic).
* **Target Cold-Start Time:** < 45 seconds (optimized for Flash).
* **Idle Retention:** 5 minutes before scale-to-zero.

### 3. Application Details

* **Container Image:** `ghcr.io/openclaw/openclaw:alpine`
* **Target Port:** `18789`
* **Workspace Path:** `/home/node/workspace`
* **LLM Provider:** Google Gemini (**`gemini-2.5-flash`**)

---

### 4. Kubernetes Manifest Specifications

#### A. Namespace & Secrets

* **Namespace:** `agents`
* **Secret Name:** `openclaw-secrets`
* **Required Keys:** `GEMINI_API_KEY`

#### B. Storage Configuration (Persistent Memory)

OpenClaw requires a stateful directory to store its local SQLite database and runtime configuration.

* **PVC Name:** `openclaw-workspace-pvc`
* **Access Mode:** `ReadWriteOnce`
* **Storage Request:** `10Gi`
* **Storage Class Strategy:** `manual-local` (for specific folder mapping) or default.

#### C. Knative Service (Serverless Engine)

**Metadata & Scaling Annotations:**

* **Min Scale:** `0`
* **Max Scale:** `1`
* **Scale-to-zero-pod-retention-period:** `5m`

**Initialization Pipeline (`initContainers`):**
An initialization container seeds the configuration into the persistent volume before the main process boots to ensure the config remains writeable.

* **Image:** `busybox:latest`
* **Logic:** Writes the Gemini Flash JSON configuration block to `/workspace/openclaw.json` **only** if the file is missing.

**Main Container Execution:**

* **Image:** `ghcr.io/openclaw/openclaw:alpine`
* **Port:** `18789`
* **Env:** Maps `GEMINI_API_KEY` from `openclaw-secrets`.
* **Mount:** `openclaw-workspace-pvc` -> `/home/node/workspace`.

---

### 5. Updated Configuration Payload (Flash)

The `initContainer` must inject this JSON to prioritize low-latency responses and high context throughput.

```json
{
  "models": {
    "mode": "merge",
    "providers": {
      "google": {
        "baseUrl": "https://generativelanguage.googleapis.com/v1beta",
        "api": "openai-completions",
        "models": [
          {
            "id": "gemini-2.5-flash",
            "name": "Gemini 2.5 Flash",
            "cost": {
              "input": 0.1,
              "output": 0.3
            },
            "contextWindow": 1048576,
            "maxTokens": 8192
          }
        ]
      }
    }
  }
}

```