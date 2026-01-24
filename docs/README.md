# Val Ark Documentation

This page serves as the navigation hub for all project documentation.

## Documentation Structure

```mermaid
graph TD
    ROOT[README.md] --> DOCS[docs/README.md]
    ROOT --> SCRIPTS[scripts/README.md]
    ROOT --> WEBUI[web-ui/README.md]
    ROOT --> TESTS[tests/README.md]

    DOCS --> ARCH[ARCHITECTURE.md]
    DOCS --> TOOLS[TOOLS.md]
    DOCS --> PLAT[PLATFORMS.md]
    DOCS --> OFFLINE[OFFLINE.md]
    DOCS --> MODEL[MODEL_INVENTORY.md]
```

## Quick Navigation

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture diagrams and component overview. |
| [TOOLS.md](TOOLS.md) | Complete catalog of available tools and their usage. |
| [PLATFORMS.md](PLATFORMS.md) | Platform-specific notes covering supported environments and configurations. |
| [OFFLINE.md](OFFLINE.md) | Guide for offline operation and peer-to-peer functionality. |
| [MODEL_INVENTORY.md](MODEL_INVENTORY.md) | Model details, tiers, and availability information. |

## Related Sections

- [scripts/README.md](../scripts/README.md) - Script utilities and automation
- [web-ui/README.md](../web-ui/README.md) - Web interface documentation
- [tests/README.md](../tests/README.md) - Test suite and coverage

---

[Back to Project Root](../README.md)
