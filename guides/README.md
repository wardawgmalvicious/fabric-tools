# guides/

Reusable configuration guides for Microsoft Fabric Copilot surfaces. These are templates — replace the illustrative retail/sales examples with your own domain without changing the structure.

| File | Purpose |
|---|---|
| [configure-ai-semantic-model.md](configure-ai-semantic-model.md) | Writing the 10,000-character AI instructions blob on a Power BI semantic model. Applies wherever Copilot consumes the model (reports, Q&A, Copilot pane). |
| [configure-data-agent.md](configure-data-agent.md) | Configuring a Fabric Data Agent: agent instructions, data source instructions, data source descriptions, and example queries. Applies only within the agent chat. |

The two surfaces coexist — a data agent can use a semantic model as one of its sources, in which case both sets of instructions are in play. Read both guides before configuring either one.

Each guide tracks its Microsoft Learn source at the bottom and carries a last-updated date. Re-verify against Learn periodically — Microsoft changes preview/GA status, character limits, and supported features.
