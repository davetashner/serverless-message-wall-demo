# Configuration Flow Architecture

This diagram shows how configuration flows from developer authoring through ConfigHub to AWS resources.

## Bidirectional GitOps Flow

```mermaid
flowchart TB
    subgraph authoring["Authoring Layer"]
        Dev[Developer]
        Git[(Git Repository)]
        Dev -->|authors Claims| Git
    end

    subgraph ci["CI Pipeline"]
        CI[GitHub Actions]
        Git -->|triggers| CI
        CI -->|renders Claims| CI
    end

    subgraph authority["Authority Layer (ConfigHub)"]
        CH[(ConfigHub)]
        Units[Units & Revisions]
        Policy[Policy Checks]
        CH --- Units
        CH --- Policy
    end

    subgraph actuation["Actuation Layer"]
        Argo[ArgoCD + CMP]
        K8s[Kubernetes]
        XP[Crossplane]
        Argo -->|syncs| K8s
        K8s -->|runs| XP
    end

    subgraph runtime["Runtime Layer (AWS)"]
        S3[(S3 Bucket)]
        DDB[(DynamoDB)]
        Lambda[Lambda Functions]
        EB[EventBridge]
    end

    CI -->|publishes| CH
    CH -->|sync back| Git
    CH -->|approved config| Argo
    XP -->|provisions| S3
    XP -->|provisions| DDB
    XP -->|provisions| Lambda
    XP -->|provisions| EB

    style CH fill:#f9f,stroke:#333,stroke-width:3px
    style authoring fill:#e1f5fe,stroke:#01579b
    style authority fill:#fce4ec,stroke:#880e4f
    style actuation fill:#e8f5e9,stroke:#1b5e20
    style runtime fill:#fff3e0,stroke:#e65100
```

## Sync Directions

```mermaid
flowchart LR
    subgraph git["Git"]
        G[(Repository)]
    end

    subgraph confighub["ConfigHub (Authority)"]
        CH[(Config Store)]
    end

    subgraph live["Live State"]
        K8s[Kubernetes]
        AWS[AWS Resources]
        K8s --> AWS
    end

    G -->|"1. CI publishes"| CH
    CH -->|"2. Apply"| K8s
    K8s -->|"3. Drift capture"| CH
    CH -->|"4. Sync PR"| G

    style CH fill:#f9f,stroke:#333,stroke-width:3px
```

## Component Responsibilities

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| **Authoring** | Git | Developer authoring surface, PR reviews, audit trail |
| **Authoring** | CI | Render Claims, publish to ConfigHub |
| **Authority** | ConfigHub | Authoritative config store, revisions, bulk changes, policy |
| **Actuation** | ArgoCD | Sync ConfigHub → Kubernetes |
| **Actuation** | Crossplane | Expand Claims → AWS managed resources |
| **Actuation** | Kyverno | Admission control, policy enforcement |
| **Runtime** | AWS | S3, DynamoDB, Lambda, EventBridge |

## Policy Enforcement Points (Defense in Depth)

Policies run at multiple layers to catch violations early and provide defense in depth.

```mermaid
flowchart TB
    subgraph intent["Intent Layer"]
        Git[(Git)]
        PreCommit[Pre-commit Hooks]
        Git --> PreCommit
    end

    subgraph ci["CI Pipeline"]
        CI[GitHub Actions]
        CIPolicy[OPA / conftest]
        CI --> CIPolicy
    end

    subgraph authority["Authority Layer"]
        CH[(ConfigHub)]
        CHPolicy[OPA Policy Checks]
        CH --- CHPolicy
    end

    subgraph actuation["Actuation Layer"]
        K8s[Kubernetes API]
        Kyverno[Kyverno Admission]
        XP[Crossplane]
        K8s --> Kyverno
        Kyverno -->|allowed| XP
    end

    subgraph runtime["Runtime Layer"]
        IAM[IAM Boundaries]
        AWS[AWS Resources]
        IAM --> AWS
    end

    PreCommit -->|"1. Validate templates"| CI
    CIPolicy -->|"2. Check rendered Claims"| CH
    CHPolicy -->|"3. Enforce before apply"| K8s
    Kyverno -->|"4. Admission control"| XP
    XP -->|"5. IAM enforced"| IAM

    style PreCommit fill:#fff3e0,stroke:#e65100
    style CIPolicy fill:#fff3e0,stroke:#e65100
    style CHPolicy fill:#fce4ec,stroke:#880e4f
    style Kyverno fill:#e8f5e9,stroke:#1b5e20
    style IAM fill:#e3f2fd,stroke:#1565c0
```

### Policy Enforcement Summary

| Enforcement Point | Layer | What It Validates | When |
|-------------------|-------|-------------------|------|
| Pre-commit hooks | Intent | Templates before commit | Developer push |
| CI (conftest) | CI | Rendered Claims | Pull request |
| ConfigHub (OPA) | Authority | Claims before apply | `cub unit apply` |
| Kyverno | Actuation | Kubernetes resources | Admission |
| IAM Boundaries | Runtime | AWS API calls | Resource creation |

### Why Duplicate Policies?

Some policies exist at multiple layers intentionally:
- **Required tags**: ConfigHub validates Claim metadata; Kyverno validates expanded resources
- **Resource constraints**: ConfigHub checks Claim fields; Kyverno validates resource specs

This provides defense in depth—if one layer misses a violation, another catches it.

## Related Documents

- [ADR-005: ConfigHub Integration Architecture](decisions/005-confighub-integration-architecture.md)
- [ADR-010: ConfigHub Stores Claims](decisions/010-confighub-claim-vs-expanded.md)
- [ADR-011: Bidirectional GitOps](decisions/011-ci-confighub-authority-conflict.md)
- [Four-Plane Model](planes.md)
