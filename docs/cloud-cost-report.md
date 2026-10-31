# Kaddo cloud cost report

Prepared 27 October 2026; provider prices checked 26 October 2026. All figures are USD, before tax. This is a planning estimate based on public prices and explicit usage assumptions, not measured production usage or a vendor quote.

## Executive estimate

For a cloud-backed Kaddo launch with **100 monthly active users**, budget **$100/month**. The modeled infrastructure and hosted AI bill is approximately **$55/month**, leaving room for email, monitoring, retries, and operational overhead.

At **1,000 active users**, the same usage pattern produces approximately **$331/month**; budget **$500/month**. At **10,000**, it produces approximately **$2,645/month**; budget **$4,000/month**. AI message volume is the largest variable.

If “everything in the cloud” means saving all user data while keeping Ollama on the Mac, the modeled cloud bill falls to approximately **$30, $86, and $195/month**, respectively. Local AI still requires a suitable user device.

## Scope and current implementation

The current repository stores planner records in a local JSON file, document text and sessions in RAM, and casual chat in RAM. AI runs through local Ollama. This estimate covers moving documents, extracted text, session metadata, planner records, saved conversations, preferences, and backup copies into cloud services. Cloud chat history would be a new persistence feature; it is not currently saved.

The macOS pet, animation, window management, activity detection, and timer display continue running on the Mac. Document extraction can also continue there before uploading originals and extracted text. “Cloud storage” does not require running the desktop app remotely. Persistent timer state could be synced, but delivery of alerts while the app is closed is a separate feature.

Repository evidence: [README](../README.md), [document extraction limits](../Sources/KaddoCanvas/DocumentTextExtractor.swift), [document memory](../Sources/KaddoCanvas/DocumentMemoryStore.swift), [conversation storage](../Sources/KaddoCanvas/ConversationStore.swift), and [planner persistence](../Sources/KaddoCanvas/StudentPlanner.swift).

## Proposed services and verified rates

| Component | Service | Pricing basis |
| --- | --- | --- |
| Accounts and structured data | Supabase Pro / PostgreSQL | $25/month with one Micro instance; $10 compute credit; 8 GB database disk and 100,000 MAU included. Extra disk $0.125/GB-month. [Supabase pricing](https://supabase.com/pricing) |
| Documents and backup objects | Cloudflare R2 Standard | $0.015/GB-month after 10 GB free; internet egress free. [R2 pricing](https://developers.cloudflare.com/r2/pricing/) |
| API and AI gateway | Cloudflare Workers Paid | $5/month includes 10 million requests and 30 million CPU milliseconds; excess usage billed separately. [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/) |
| Hosted text AI | Gemini 3.5 Flash-Lite, paid Standard API | $0.30/million input tokens; $2.50/million output tokens, including thinking. [Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing) |

Use PostgreSQL search over the extracted chunks initially, preserving scoped document retrieval. A separate vector database, embedding pipeline, and dedicated GPU are unnecessary for this cost model.

The AI provider is a costing example, subject to answer-quality testing with Kaddo's citation and emotion contracts. Google recommends newer models for new projects and restricts access to its older 2.5 models to prior users; this report therefore does not use the older, lower Flash-Lite price. [Model availability](https://ai.google.dev/gemini-api/docs/deprecations)

## Usage assumptions

| Input | Assumption |
| --- | --- |
| User population | All stored accounts are active in the month; dormant accounts would add storage even without AI usage |
| Original documents | 200 MB retained per user, e.g. 20 files averaging 10 MB; this is a retained balance, not 200 MB of new uploads every month |
| Object backups | One additional full-copy equivalent, giving 400 MB total object storage per user; bounded retention rather than unlimited versions |
| Database | 5 MB physical disk per user, including extracted text, planner, chat, metadata, and indexes; a modest dataset assumption, not the current maximum import capacity |
| Hosted AI requests | 100 per user/month, about 3 per day; only requests that invoke the model count |
| Tokens per request | 4,000 total input tokens, including prompt, history, question, and retrieved context; 500 total billed output tokens, including any thinking |
| API traffic | Up to 1,000 gateway calls/user/month, averaging no more than 3 ms CPU each; no continuous polling |
| R2 operations | Up to 40 writes/copies and 100 reads per user/month, within included operation quotas at the modeled scales |
| Database transfer | At most 250 GB/month total; files are downloaded directly from R2 |

These assumptions are deliberate limits, not established product telemetry. Long histories, more extracted text, non-English tokenization, or lengthy reasoning can exceed them.

## Monthly cost breakdown

| Cost item | 100 users | 1,000 users | 10,000 users |
| --- | ---: | ---: | ---: |
| Database, auth, compute, extra disk | $25.00 | $75.00 | $130.25 |
| Files plus backup copy | $0.45 | $5.85 | $59.85 |
| API gateway | $5.00 | $5.00 | $5.00 |
| Hosted text AI | $24.50 | $245.00 | $2,450.00 |
| **Modeled monthly total** | **$54.95** | **$330.85** | **$2,645.10** |
| **Suggested monthly budget** | **$100** | **$500** | **$4,000** |
| Modeled annual total, constant usage | $659.40 | $3,970.20 | $31,741.20 |

Database sizing uses Micro at 100 users, Medium at 1,000, and Large at 10,000. These are planning choices, not capacity guarantees; query patterns and concurrency require load testing. Medium is $60/month compute and Large $110; the totals apply the $25 plan fee and $10 compute credit once. At 10,000 users, 50 GB disk adds $5.25 above the included 8 GB. [Compute and disk rates](https://supabase.com/pricing)

Suggested budgets round up the modeled total by roughly 50–80%. The difference is an unallocated allowance for email, extra monitoring, modest staging resources, retries, transfer overages, and usage variation. It is not a priced package or an unlimited-use promise. Annual figures exclude this allowance and assume no price changes.

For just one person's paid deployment, the modeled monthly total is approximately **$30.25**; a **$50/month** budget is reasonable. Free tiers can reduce prototype costs, but this report uses a paid production database baseline.

## Calculation and sensitivity

The hosted AI estimate is:

```text
AI cost/request = (4,000 × $0.30 + 500 × $2.50) / 1,000,000
                = $0.00245
AI cost/user/month = 100 × $0.00245 = $0.245

Object storage = max(0, users × 0.4 GB - 10 GB) × $0.015
Database = $25 + compute - $10 credit
         + max(0, users × 0.005 GB - 8 GB) × $0.125
Monthly total = database + object storage + $5 gateway + AI
```

At 1,000 active users, increasing AI usage changes the estimate materially:

| AI requests/user/month | AI bill/month | Total/month before allowance |
| ---: | ---: | ---: |
| 100 | $245 | $331 |
| 300, about 10/day | $735 | $821 |
| 1,000, about 33/day | $2,450 | $2,536 |

At 10,000 users and 300 requests/user/month, the modeled bill becomes approximately **$7,545/month**. The $4,000 budget above applies to the 100-request assumption only. More usage may also require larger compute or higher API quotas.

For comparison, raising document storage from 200 MB to 2 GB per user, retaining the same backup multiplier, adds about **$540/month at 10,000 users**. AI usage remains the larger expense in these scenarios. Storage continues accumulating unless retention and account deletion are implemented.

## Backups, exclusions, and implementation work

Supabase Pro includes seven days of daily database backups. Those backups do not include stored file contents; object copies must be managed separately. The R2 estimate explicitly includes one extra document-copy equivalent. Copies should have separate access controls and a tested restore path; this is not a geographically independent disaster-recovery design. [Backup coverage](https://supabase.com/docs/guides/platform/backups)

The base estimate excludes OCR for scanned documents, server-side PDF/DOCX extraction, voice, image generation, web-search grounding, paid embeddings, dedicated GPUs, high availability replicas, point-in-time recovery, long-term audit logs, SMS, payment processing, app distribution fees, taxes, and development/support labor. Native extraction remains the ingestion path; moving parsing entirely to servers requires a separate worker and cost estimate. Region-specific residency requirements also need a separate architecture review.

Cloud migration requires account sign-in, per-user/session access controls, schema and upload APIs, sync/conflict handling, local-planner migration, chat/document retention and deletion, backup jobs, a hosted inference adapter, and tests. Keep provider secrets in the gateway and enforce AI/storage quotas there. Do not assume these features are already implemented or covered by the monthly hosting bill.

Workers log billing changes on 1 December 2026; revisit observability costs before then. [Announced logging change](https://developers.cloudflare.com/workers/platform/pricing/)

## Recommendation

Start with Supabase Pro, R2, and a small Workers gateway. Store all durable user data in the cloud while the native companion remains on the Mac. Use hosted AI if removing the Ollama setup requirement matters; keep local AI as an option if reducing recurring AI costs matters more.

For the first 100 active users, reserve **$100/month** under the stated 100-request allowance. Measure tokens, retained bytes, queries, and peak concurrency before raising limits. At 1,000 users, use **$500/month** for that allowance, or approximately **$1,200/month** if planning for 300 AI requests per user instead.
