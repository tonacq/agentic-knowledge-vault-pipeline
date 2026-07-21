# Flagship post draft

## I stopped treating YouTube as content to consume—and built a system that could study an entire channel

Andrej Karpathy demonstrated a powerful use of Claude Code: synthesising source material into an Obsidian knowledge base.

Nate Herk then taught that use case to his automation community.

I decided to see what would happen if I engineered the manual demonstration into a persistent operating system—and used Nate's own published catalogue as the private test corpus.

The result is a remotely operated pipeline that maintains an evolving Obsidian wiki.

It does not simply dump transcripts into folders. On a weekly schedule, the system:

- identifies new and previously failed items;
- prepares clean source material;
- creates a traceable page for every source;
- invokes Claude only where semantic judgement is required;
- updates concepts, tools, workflows and recurring themes across the catalogue;
- reconciles the manifest against the files and synthesis evidence; and
- reports whether the run is genuinely complete.

The latest documented reconciliation covered **295 videos**, with:

- **0 missing clean transcripts**
- **0 missing source pages**
- **0 pending synthesis items**

It also handles a week with no new material without wasting a synthesis run.

The build taught me that the model call is not the hard part.

The real work is the operating system around it: state, exception recovery, incremental processing, provenance, QA, traceability and a clear boundary between deterministic automation and agentic judgement.

My engineering analogy is a small knowledge-processing plant. Source material is the feed. Scripts prepare and route it. Claude performs the semantic transformation. The manifest tracks work-in-progress. Reconciliation checks that nothing has been lost between the feed and the finished knowledge layer.

The vault also produced an interesting longitudinal view of Nate's teaching.

Across the catalogue analysed, I observed an apparent progression from fixed n8n workflows, through AI-assisted automation, toward Claude Code, context engineering, reusable skills and more agentic systems.

My interpretation is that implementation is becoming easier while problem definition, context, controls and verification are becoming more valuable. That is my analysis of the published catalogue—not a claim about Nate's intentions or where he must go next.

So the lineage is clear:

- Karpathy demonstrated the cognitive pattern.
- Nate taught the use case.
- I operationalised it as a remote, incremental and auditable system—and then used the resulting vault to generate analysis across the body of work.

I am publishing the architecture, verified results and lessons in a public project repository. The Nate-specific transcript corpus and complete vault remain private. The reusable version is being redesigned for material that is user-owned, appropriately licensed or creator-authorised.

This is the overview. I will follow with the system architecture, the boundary between scripts and agents, how the vault works as a cognitive tool, what the catalogue analysis revealed, and the uncomfortable but important governance lessons from turning a prototype into something distributable.

For those who build these systems: **where do you draw the line between deterministic automation and agentic judgement?**

Nate, I would also be interested in your view: does that apparent evolution in the catalogue match how your own thinking has changed, or is the vault seeing a pattern that you would frame differently?

[Agentic Knowledge Vault Pipeline](https://github.com/tonacq/agentic-knowledge-vault-pipeline)
